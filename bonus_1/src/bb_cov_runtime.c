/*
 * bb_cov_runtime.c
 *
 * Runtime component for collecting "Basic Block Coverage" of C/C++
 * programs compiled with Clang/LLVM SanitizerCoverage.
 *
 * Instrumentation flags (see task statement):
 *
 *   -fprofile-instr-generate
 *   -fcoverage-mapping
 *   -fsanitize-coverage=bb,no-prune,inline-bool-flag,pc-table
 *
 * The compiler inserts an inline boolean flag for every basic block and
 * calls
 *
 *   __sanitizer_cov_bool_flag_init(bool *start, bool *end)
 *
 * once per module.  The array [start, end) contains one flag per
 * instrumented block; a flag is set to true iff the corresponding block
 * was executed at least once (inline-bool-flag).
 *
 * Together with pc-table the compiler also provides the table of PCs of
 * all instrumented blocks:
 *
 *   __sanitizer_cov_pcs_init(const uintptr_t *pcs_beg,
 *                            const uintptr_t *pcs_end)
 *
 * The table contains pairs [PC, PCFlags] -- one pair per instrumented
 * block.  The number of pairs equals the number of boolean flags, which
 * lets us count the total number of instrumented basic blocks and, at
 * process exit, the number of executed blocks.
 *
 * Atexit the runtime writes a raw JSON report containing every PC plus
 * the indices of executed blocks (union of ALL runs, so that a basic
 * block executed by several test runs is counted only once -- this is
 * achieved by merging the previously existing report on each run).
 *
 * The raw report is turned into a per-source-file report by
 * tools/bb_cov_finalize.py, which resolves every PC to a file/line
 * with llvm-addr2line.
 */

#include <stdint.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#if defined(__APPLE__)
#include <mach-o/dyld.h>
#endif

#include "bb_cov_runtime.h"

/* Maximum number of modules (DSOs) we track.  A statically linked
 * single executable corresponds to exactly one module. */
#define BBCOV_MAX_MODULES 16

#define BBCOV_DEFAULT_OUT "bb_cov_raw.json"

typedef struct {
    uint8_t    *flags;      /* inline bool flags of a module  */
    size_t      num;        /* number of blocks in the module */
    uintptr_t  *pcs;        /* copy of block PCs              */
    size_t      pcs_count;  /* number of blocks (== num)      */
} bb_module_t;

static bb_module_t g_modules[BBCOV_MAX_MODULES];
static size_t      g_module_count = 0;
static size_t      g_total_blocks = 0;

static const char *g_out_name = NULL;
static int         g_quiet = 0;
static int64_t     g_slide = 0;   /* ASLR slide of the main image */

/* ------------------------------------------------------------------ */
/* SanitizerCoverage interfaces                                        */
/* ------------------------------------------------------------------ */

/*
 * Called once per DSO during its construction with the array of inline
 * boolean flags, one per instrumented basic block.
 */
void __sanitizer_cov_bool_flag_init(bool *start, bool *end)
{
    size_t i;

    if (start == NULL || start == end)
        return;

    /* A given flag array may be reported more than once (LLVM: "may be
     * called more than once with the same values"); register it only
     * once. */
    for (i = 0; i < g_module_count; i++) {
        if (g_modules[i].flags == (uint8_t *)start)
            return;
    }
    if (g_module_count >= BBCOV_MAX_MODULES)
        return;

    bb_module_t *m = &g_modules[g_module_count];
    m->flags = (uint8_t *)start;
    m->num = (size_t)(end - start);   /* bool has size 1 byte */
    m->pcs = NULL;
    m->pcs_count = 0;

    g_total_blocks += m->num;
    g_module_count++;
}

/*
 * Called once per DSO with the PC table: pairs [PC, PCFlags], one pair
 * per instrumented block.  We copy the PCs because the table is owned by
 * the compiler and its lifetime is not guaranteed.
 *
 * Note: SanitizerCoverage reports the bool flags and the PC table as two
 * independent callbacks, so we pair them up here: every module (flag
 * array) without an assigned PC table receives the next table.
 */
void __sanitizer_cov_pcs_init(const uintptr_t *pcs_beg,
                              const uintptr_t *pcs_end)
{
    size_t i;

    if (pcs_beg == NULL || pcs_beg == pcs_end)
        return;

    size_t entries = (size_t)(pcs_end - pcs_beg) / 2;

    for (i = 0; i < g_module_count; i++) {
        if (g_modules[i].pcs == NULL) {
            bb_module_t *m = &g_modules[i];
            uintptr_t *pcs;

            if (entries < m->num)
                entries = m->num;
            pcs = (uintptr_t *)calloc(entries, sizeof(uintptr_t));
            if (pcs == NULL)
                return;

            for (size_t k = 0; k < entries; k++)
                pcs[k] = (k < entries) ? pcs_beg[2 * k] : 0;

            m->pcs = pcs;
            m->pcs_count = entries;
            return;
        }
    }
}

/*
 * Defensive no-op implementations of the guard-based interfaces.  They
 * are not used with the flag/pc-table instrumentation, but defining them
 * keeps the runtime linkable for other configurations of
 * SanitizerCoverage as well.
 */
void __sanitizer_cov_trace_pc(void)
{
}

void __sanitizer_cov_trace_pc_guard_init(uint32_t *start, uint32_t *stop)
{
    (void)start;
    (void)stop;
}

void __sanitizer_cov_trace_pc_guard(uint32_t *guard)
{
    (void)guard;
}

/* ------------------------------------------------------------------ */
/* JSON merging / dumping                                              */
/* ------------------------------------------------------------------ */

/*
 * Merge the executed indices stored in a previously produced raw report
 * into the bitmask EXEC (union).  This guarantees that a basic block
 * executed by several different test runs is counted only once.
 */
static void bb_merge_previous(const char *path, uint8_t *exec, size_t n)
{
    FILE *f = fopen(path, "r");
    char  buf[4096];
    char *p;
    char *q;

    if (f == NULL)
        return;

    while (fgets(buf, sizeof(buf), f) != NULL) {
        /* Find the "executed_indices" field within the current buffer
         * (the field fits in one line in our own format). */
        p = strstr(buf, "\"executed_indices\"");
        if (p == NULL)
            continue;
        p = strchr(p, '[');
        if (p == NULL)
            continue;
        p++;
        while (*p && *p != ']') {
            while (*p && (*p == ' ' || *p == ',' || *p == '\t'))
                p++;
            if (!*p || *p == ']')
                break;
            unsigned long idx = strtoul(p, &q, 10);
            if (idx < n)
                exec[idx] = 1;
            p = q;
        }
        break;
    }
    fclose(f);
}

static void bb_write_u64(FILE *f, unsigned long long v)
{
    char buf[32];
    snprintf(buf, sizeof(buf), "%llu", v);
    fputs(buf, f);
}

static void bb_write_json(const char *path, const uint8_t *exec, size_t n)
{
    FILE *f = fopen(path, "w");
    size_t i;
    int first = 1;

    if (f == NULL) {
        if (!g_quiet)
            fprintf(stderr,
                    "bb_cov_runtime: cannot write %s\n", path);
        return;
    }

    fprintf(f, "{\n");
    fprintf(f, "  \"tool\": \"bb_cov_runtime\",\n");
    fprintf(f, "  \"slide\": %lld,\n", (long long)g_slide);
    fputs("  \"total_blocks\": ", f);
    bb_write_u64(f, (unsigned long long)n);
    fputs(",\n", f);

    fputs("  \"executed_indices\": [", f);
    for (i = 0; i < n; i++) {
        if (!exec[i])
            continue;
        if (!first)
            fputs(", ", f);
        first = 0;
        bb_write_u64(f, (unsigned long long)i);
    }
    fputs("],\n", f);

    fputs("  \"modules\": [\n", f);
    for (i = 0; i < g_module_count; i++) {
        bb_module_t *m = &g_modules[i];
        size_t j;

        if (i)
            fputs(",\n", f);
        fputs("    {\n", f);
        fputs("      \"pc_count\": ", f);
        bb_write_u64(f, (unsigned long long)m->pcs_count);
        fputs(",\n", f);
        fputs("      \"pcs\": [", f);
        for (j = 0; j < m->pcs_count; j++) {
            if (j)
                fputs(", ", f);
            fprintf(f, "\"0x%llx\"",
                    (unsigned long long)m->pcs[j]);
        }
        fputs("]\n", f);
        fputs("    }", f);
    }
    fputs("\n  ]\n", f);
    fputs("}\n", f);

    fclose(f);
}

/*
 * Atexit handler: compute this-run execution from the bool flags, merge
 * with previously recorded runs and dump the raw JSON report.
 */
static void bb_cov_dump(void)
{
    size_t i;
    size_t base = 0;
    uint8_t *exec;
    size_t executed = 0;

    if (g_total_blocks == 0)
        return;

    exec = (uint8_t *)calloc(g_total_blocks, 1);
    if (exec == NULL)
        return;

    /* This-run executed blocks. */
    for (i = 0; i < g_module_count; i++) {
        bb_module_t *m = &g_modules[i];
        size_t k;

        for (k = 0; k < m->num; k++) {
            if (m->flags[k])
                exec[base + k] = 1;
        }
        base += m->num;
    }

    /* Union with the previous run(s) to avoid double counting. */
    bb_merge_previous(g_out_name, exec, g_total_blocks);

    for (i = 0; i < g_total_blocks; i++)
        executed += exec[i];

    bb_write_json(g_out_name, exec, g_total_blocks);

    if (!g_quiet)
        fprintf(stderr,
                "bb_cov_runtime: %zu instrumented basic blocks, "
                "%zu executed\n",
                g_total_blocks, executed);

    free(exec);
}

/*
 * Module constructor: read environment and install the exit hook.
 */
__attribute__((constructor))
static void bb_cov_init(void)
{
    const char *env;

    env = getenv("BB_COV_OUT");
    g_out_name = (env && *env) ? env : BBCOV_DEFAULT_OUT;
    env = getenv("BB_COV_QUIET");
    g_quiet = (env && *env == '1');

    /* Record the ASLR slide of the main executable.  On macOS the
     * binary is always PIE and the recorded PCs are runtime (slid)
     * addresses; subtracting the slide yields the link-time addresses
     * that llvm-addr2line can resolve.  On Linux the slide is 0. */
#if defined(__APPLE__)
    g_slide = (int64_t)_dyld_get_image_vmaddr_slide(0);
#endif

    atexit(bb_cov_dump);
}