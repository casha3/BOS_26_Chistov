# Бонусное задание №1 — «Модификация утилиты genhtml»

**Задача.** Расширить утилиту `genhtml` (пакет LCOV) так, чтобы помимо
стандартных метрик **Line / Function / Branch Coverage** она отображала
метрику **Basic Block Coverage**.

Используется инструментация **Clang/LLVM SanitizerCoverage**
(`-fsanitize-coverage=bb,no-prune,inline-bool-flag,pc-table`) в одной
инструментированной сборке со стандартным покрытием.

Метрика отображается на страницах: общее покрытие проекта, каталоги,
файлы. Без опции `--bb-report` утилита работает как оригинальная
(обратная совместимость проверяется сравнением отчётов).

---

## 1. Последовательность запуска на Rocky Linux

### 1.1 Копирование на виртуальную машину

```bash
scp -r bonus_1 user@rocky:~/        # скопировать каталог
ssh user@rocky
cd ~/bonus_1
```

### 1.2 Быстрый запуск всего сразу

```bash
sudo bash run_all.sh --install      # установка зависимостей + сборка + отчёты
```

`run_all.sh` по очереди выполняет:

1. `00_install_deps.sh` — установка пакетов (при `--install`);
2. `01_build_runtime.sh` — сборка runtime-компонента `build/libbbcov.a`;
3. `02_build_genhtml.sh` — сборка патченного `genhtml` (LCOV 1.16 + патч);
4. для каждого проекта `cjson`, `microtar`:
   - `projects/<p>/build_and_run.sh` — сборка/замер проекта;
   - `verify/check_compat.sh <p>` — проверка совместимости + генерация отчётов.

### 1.3 Запуск по шагам (вручную)

```bash
sudo bash 00_install_deps.sh        # 1. зависимости: clang llvm gcc git perl-JSON-PP python3 ...

bash 01_build_runtime.sh            # 2. runtime для базовых блоков

bash 02_build_genhtml.sh            # 3. vendor/genhtml (патченный) и vendor/genhtml_orig

# 4. проекты (каждый клонируется при первом запуске с GitHub)
bash projects/cjson/build_and_run.sh
bash projects/microtar/build_and_run.sh

# 5. отчёты и проверка обратной совместимости
bash verify/check_compat.sh cjson
bash verify/check_compat.sh microtar
```

### 1.4 Что должно получиться

После выполнения в `output/<проект>/` появится:

| Файл/каталог | Содержимое |
|---|---|
| `coverage.info` | стандартное покрытие (строки/функции/ветви), `llvm-cov export --format=lcov` |
| `bb_cov_raw.json` | сырой отчёт runtime (PC всех блоков + выполненные) |
| `bb_cov.json` | итоговый отчёт: `{ "sources": { файл: {found, hit} } }` |
| `html_orig/` | отчёт оригинального (непатченного) `genhtml` |
| `html_plain/` | патченный `genhtml` **без** `--bb-report` |
| `html_bb/` | патченный `genhtml` **с** `--bb-report` (метрика Basic Block Coverage) |

Открыть отчёт с новой метрикой:

```bash
xdg-open output/cjson/html_bb/index.html
```

Ожидаемые строки в консоли патченного `genhtml`:

```
Overall coverage rate:
  lines......: ...
  functions..: ...
  branches...: ...
  basic blcks: N% (M of K basic blocks)
```

И строку проверки совместимости от `check_compat.sh`:

```
(cjson) PASS: html_orig == html_plain (bit-identical)
(cjson) file pages with BB metric : 3
(cjson) directory index with BB   : 2
(cjson) COMPAT_RESULT=OK
```

### 1.5 Настройка окружения (при необходимости)

Если clang/llvm установлены не в стандартное место, укажите каталог:

```bash
LLVM_DIR=/usr/lib/llvm-17/bin bash run_all.sh
```

Отдельные инструменты можно переопределить переменными
`CLANG`, `LLVM_PROFDATA`, `LLVM_COV`, `LLVM_ADDR2LINE`.

---

## 2. Состав каталога

```
bonus_1/
├── README.md                  # описание и инструкция
├── run_all.sh                 # главный скрипт
├── 00_install_deps.sh         # установка зависимостей (dnf)
├── 01_build_runtime.sh        # сборка runtime (build/libbbcov.a)
├── 02_build_genhtml.sh        # сборка патченного genhtml
├── src/
│   ├── bb_cov_runtime.h
│   └── bb_cov_runtime.c
├── tools/
│   ├── lib_common.sh
│   ├── bb_cov_finalize.py
│   └── build_project.sh
├── patch/
│   └── genhtml.patch
├── projects/
│   ├── cjson/
│   │   ├── build.conf
│   │   ├── harness_main.c
│   │   └── build_and_run.sh
│   └── microtar/
│       ├── build.conf
│       ├── harness_main.c
│       └── build_and_run.sh
├── verify/
│   └── check_compat.sh
└── output/                    # создаётся при запуске
```

---

## 3. Листинги кода

Содержимое всех файлов приведено ниже в порядке зависимостей
(от низкоуровневых компонентов к верхнему уровню).

---

### Листинг 1. `tools/lib_common.sh`

```bash
#!/usr/bin/env bash
#
# lib_common.sh - shared configuration and helpers for the scripts of
# the "genhtml + basic block coverage" bonus lab.
#
# This file is meant to be sourced by other scripts, not executed.

set -uo pipefail

# --- Repository root -----------------------------------------------------
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# --- Directories ---------------------------------------------------------
SRC_DIR="$ROOT/src"
TOOLS_DIR="$ROOT/tools"
PATCH_DIR="$ROOT/patch"
BUILD_DIR="$ROOT/build"
OUTPUT_DIR="$ROOT/output"
RUNTIME_LIB="$BUILD_DIR/libbbcov.a"

LCOV_DIR="$ROOT/vendor/lcov-1.16"
GENHTML="$ROOT/vendor/genhtml"
GENHTML_ORIG="$ROOT/vendor/genhtml_orig"

# --- LLVM toolchain discovery --------------------------------------------
# The user may override the tools via environment variables, e.g.
#   LLVM_DIR=/usr/lib/llvm-17/bin ./run_all.sh
# Otherwise we look in PATH first and then in a few well-known locations.

find_llvm_tools() {
    local dir

    if [ -n "${LLVM_DIR:-}" ] && [ -x "$LLVM_DIR/clang" ]; then
        LLVM_BIN="$LLVM_DIR"
        export PATH="$LLVM_BIN:$PATH"
    elif [ -x /usr/bin/clang ]; then
        LLVM_BIN=/usr/bin
    else
        for dir in /usr/local/bin /opt/homebrew/opt/llvm/bin \
                   /usr/lib/llvm/bin /usr/lib/llvm-19/bin /usr/lib/llvm-18/bin \
                   /usr/lib/llvm-17/bin /usr/lib/llvm-16/bin; do
            if [ -x "$dir/clang" ]; then
                LLVM_BIN="$dir"
                break
            fi
        done
    fi

    CLANG="${CLANG:-$LLVM_BIN/clang}"
    LLVM_PROFDATA="${LLVM_PROFDATA:-$LLVM_BIN/llvm-profdata}"
    LLVM_COV="${LLVM_COV:-$LLVM_BIN/llvm-cov}"
    LLVM_ADDR2LINE="${LLVM_ADDR2LINE:-$LLVM_BIN/llvm-addr2line}"
    LLVM_CONFIG="${LLVM_CONFIG:-$LLVM_BIN/llvm-config}"

    for tool in "$CLANG" "$LLVM_PROFDATA" "$LLVM_COV" "$LLVM_ADDR2LINE"; do
        if [ ! -x "$tool" ]; then
            echo "ERROR: required LLVM tool not found: $tool" >&2
            echo "       install clang/llvm or set LLVM_DIR" >&2
            exit 1
        fi
    done
}

# --- llvm-cov export (handles different CLI versions) ---------------------
# `llvm-cov export` changed its option style over the years:
#   LLVM < 18:  llvm-cov export -instr-profile=P -format=lcov BIN > out
#   LLVM >= 18: llvm-cov export --instr-profile=P --format=lcov BIN > out
# We simply try both forms.

llvm_cov_export_lcov() {
    local bin="$1"
    local profdata="$2"
    local out="$3"

    rm -f "$out"

    if "$LLVM_COV" export --format=lcov --instr-profile="$profdata" "$bin" \
           > "$out" 2>/dev/null; then
        :
    elif "$LLVM_COV" export -format=lcov -instr-profile="$profdata" "$bin" \
           > "$out" 2>/dev/null; then
        :
    else
        echo "ERROR: llvm-cov export failed for $bin" >&2
        return 1
    fi

    if [ ! -s "$out" ]; then
        echo "ERROR: llvm-cov export produced empty output: $out" >&2
        return 1
    fi
    return 0
}

# --- Instrumentation flags ------------------------------------------------
# Standard (line/function/branch) coverage + basic block instrumentation
# in a SINGLE build (formal requirement #2).
#   -no-pie : keep load addresses equal to link addresses so that the PCs
#             recorded by the runtime can be resolved by llvm-addr2line.
#             (Darwin uses a different flag spelling.)
if [ "$(uname -s)" = "Darwin" ]; then
    INSTR_FLAGS=(-g -O0 -Wl,-no_pie \
        -fprofile-instr-generate \
        -fcoverage-mapping \
        -fsanitize-coverage=bb,no-prune,inline-bool-flag,pc-table)
else
    INSTR_FLAGS=(-g -O0 -no-pie \
        -fprofile-instr-generate \
        -fcoverage-mapping \
        -fsanitize-coverage=bb,no-prune,inline-bool-flag,pc-table)
fi

log() { echo "[$(date '+%H:%M:%S')] $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }
```

---

### Листинг 2. `src/bb_cov_runtime.h`

```c
/*
 * bb_cov_runtime.h
 *
 * Runtime component ("runtime") for collecting basic block coverage
 * of C/C++ programs instrumented with Clang/LLVM SanitizerCoverage.
 *
 * The instrumentation is enabled by compiling with:
 *
 *   -fprofile-instr-generate -fcoverage-mapping \
 *   -fsanitize-coverage=bb,no-prune,inline-bool-flag,pc-table
 *
 * The runtime implements the SanitizerCoverage interfaces
 *
 *   __sanitizer_cov_bool_flag_init(...)
 *   __sanitizer_cov_pcs_init(...)
 *
 * and dumps the collected information in JSON format when the process
 * exits.  See bb_cov_runtime.c for details.
 *
 * Environment variables:
 *   BB_COV_OUT  - path to the raw JSON output file (default: bb_cov_raw.json)
 *   BB_COV_QUIET- set to '1' to suppress diagnostics on stderr
 */

#ifndef BB_COV_RUNTIME_H
#define BB_COV_RUNTIME_H

#ifdef __cplusplus
extern "C" {
#endif

/* SanitizerCoverage callbacks (optional in absence of pc-table support). */
void __sanitizer_cov_trace_pc(void);
void __sanitizer_cov_trace_pc_guard_init(uint32_t *start, uint32_t *stop);
void __sanitizer_cov_trace_pc_guard(uint32_t *guard);

#ifdef __cplusplus
}
#endif

#endif /* BB_COV_RUNTIME_H */
```

---

### Листинг 3. `src/bb_cov_runtime.c`

```c
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

    atexit(bb_cov_dump);
}
```

---

### Листинг 4. `tools/bb_cov_finalize.py`

```python
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
bb_cov_finalize.py

Build a per-source-file basic block coverage report from the raw report
written by the bb_cov_runtime and the instrumented binary.

The raw report (default name bb_cov_raw.json) contains the addresses
(PCs) of every instrumented basic block plus the indices of the blocks
that were executed in at least one run.  Each PC is resolved to the
"file:line" of the block location with llvm-addr2line; blocks are then
grouped by source file, giving per file

    found   -- total number of instrumented basic blocks in the file
    hit     -- number of executed basic blocks in the file

The resulting JSON ("basic block report", default bb_cov.json) is
consumed by the patched genhtml via the --bb-report option.

Usage:
  bb_cov_finalize.py --raw DIR/bb_cov_raw.json --binary ./test_prog \
      --output bb_cov.json [--addr2line /path/to/llvm-addr2line]
"""

import argparse
import json
import os
import subprocess
import sys


def parse_args():
    p = argparse.ArgumentParser(
        description="Finalize the raw basic block coverage report")
    p.add_argument("--raw", required=True,
                   help="raw report produced by bb_cov_runtime")
    p.add_argument("--binary", required=True,
                   help="instrumented executable to symbolize against")
    p.add_argument("--output", default="bb_cov.json",
                   help="output per-file report (default: bb_cov.json)")
    p.add_argument("--addr2line", default=None,
                   help="path to llvm-addr2line (default: search PATH)")
    return p.parse_args()


def find_addr2line():
    for name in ("llvm-addr2line", "addr2line", "llvm-symbolizer"):
        for path in os.environ.get("PATH", "").split(os.pathsep):
            cand = os.path.join(path, name)
            if os.path.isfile(cand) and os.access(cand, os.X_OK):
                return cand
    return None


def normaddr(a):
    """Normalize a hex address to '0x' + no leading zeros (0x15, 0x102ab)."""
    try:
        return "0x%x" % int(a, 16)
    except ValueError:
        return a


def resolve_pcs(addr2line, binary, pcs):
    """Resolve a list of hex PC addresses to (function, file:line).

    Runs a single bulk invocation of llvm-addr2line.  With -f -a -C the
    output is a strict 3-line group per address:

        0xADDR
        function
        file:line

    (we do NOT use -i so that there are no inlined-frame extra lines).
    """
    result = {}
    if not pcs:
        return result

    args = [addr2line, "-e", binary, "-f", "-a", "-C"] + pcs
    proc = subprocess.Popen(args, stdout=subprocess.PIPE,
                            stderr=subprocess.DEVNULL, text=True)
    out, _ = proc.communicate()
    if proc.returncode != 0:
        sys.stderr.write("bb_cov_finalize: addr2line failed\n")
        return result

    lines = out.splitlines()
    i = 0
    while i < len(lines):
        addr_line = lines[i].strip()
        if not (addr_line.startswith("0x") or addr_line.startswith("0X")):
            i += 1
            continue
        # 3-line group: address, function, location
        if i + 2 < len(lines):
            loc = lines[i + 2].strip()
        else:
            loc = "??:0"
        result[normaddr(addr_line)] = loc
        i += 3
    return result


def main():
    args = parse_args()

    if not os.path.isfile(args.raw):
        sys.exit("bb_cov_finalize: raw report not found: %s" % args.raw)
    if not os.path.isfile(args.binary):
        sys.exit("bb_cov_finalize: binary not found: %s" % args.binary)

    addr2line = args.addr2line or find_addr2line()
    if not addr2line:
        sys.exit("bb_cov_finalize: llvm-addr2line not found in PATH")

    with open(args.raw, "r", encoding="utf-8") as f:
        raw = json.load(f)

    # Flatten the PCs and executed indices over all modules.
    flat_pcs = []
    module_size = []
    for mod in raw.get("modules", []):
        pcs = [p.lower() for p in mod.get("pcs", [])]
        flat_pcs.extend(pcs)
        module_size.append(len(pcs))

    executed_set = set(raw.get("executed_indices", []))
    total_blocks = raw.get("total_blocks", len(flat_pcs))

    # Resolve every instrumented block PC to file:line.
    pcs_to_loc = resolve_pcs(addr2line, args.binary, flat_pcs)

    # Group by source file. Files that could not be resolved are skipped.
    per_file = {}
    for idx, pc in enumerate(flat_pcs):
        loc = pcs_to_loc.get(normaddr(pc))
        if not loc or loc.startswith("?") or ":" not in loc:
            # Skip blocks whose source location could not be resolved.
            continue
        filename = loc.rsplit(":", 1)[0]
        line_no = loc.rsplit(":", 1)[1]
        if not line_no.isdigit():
            continue
        rec = per_file.setdefault(filename, {"found": 0, "hit": 0})
        rec["found"] += 1
        if idx in executed_set:
            rec["hit"] += 1

    # Sanity check: total instrumented blocks must equal the sum of
    # per-file found counts (requirement: define the total number of
    # instrumented basic blocks).
    total_found = sum(v["found"] for v in per_file.values())
    total_hit = sum(v["hit"] for v in per_file.values())

    report = {
        "sources": per_file,
        "total": {
            "found": total_blocks,
            "hit": len(executed_set)
        },
        "resolved_found": total_found,
        "resolved_hit": total_hit,
    }

    with open(args.output, "w", encoding="utf-8") as f:
        json.dump(report, f, indent=2, sort_keys=True)
        f.write("\n")

    sys.stderr.write(
        "bb_cov_finalize: %d blocks total, %d executed; "
        "attributed %d blocks to %d source files\n"
        % (total_blocks, len(executed_set), total_found,
           len(per_file)))

    if total_blocks > 0 and resolved_found < max(1, total_blocks // 10):
        sys.stderr.write(
            "WARNING: most basic blocks could not be attributed to a "
            "source file.\n"
            "  Make sure the binary was built with -no-pie "
            "(fixed load addresses) and debug info (-g),\n"
            "  and that llvm-addr2line can symbolize %s\n"
            % args.binary)


if __name__ == "__main__":
    main()
```

---

### Листинг 5. `patch/genhtml.patch`

Применяется к исходникам **LCOV 1.16** командой `patch -p1` (см.
`02_build_genhtml.sh`). Добавляет опцию `--bb-report` и метрику
Basic Block Coverage в HTML-отчёты, не меняя поведение без этой опции.

```diff
--- a/bin/genhtml
+++ b/bin/genhtml
@@ -196,7 +196,7 @@
 sub apply_config($);
 sub get_html_prolog($);
 sub get_html_epilog($);
-sub write_dir_page($$$$$$$$$$$$$$$$$);
+sub write_dir_page($$$$$$$$$$$$$$$$$$$);
 sub classify_rate($$$$);
 sub combine_brcount($$$;$);
 sub get_br_found_and_hit($);
@@ -214,14 +214,14 @@
 sub write_png_files();
 sub write_htaccess_file();
 sub write_css_file();
-sub write_description_file($$$$$$$);
+sub write_description_file($$$$$$$$$);
 sub write_function_table(*$$$$$$$$$$);
 
 sub write_html(*$);
 sub write_html_prolog(*$$);
 sub write_html_epilog(*$;$);
 
-sub write_header(*$$$$$$$$$$);
+sub write_header(*$$$$$$$$$$$$);
 sub write_header_prolog(*$);
 sub write_header_line(*@);
 sub write_header_epilog(*$);
@@ -296,6 +296,10 @@
 our $opt_config_file;	# User-specified configuration file location
 our %opt_rc;
 our $opt_missed;	# List/sort lines by missed counts
+our $bb_report;		# Path to JSON with basic block coverage data
+			# (--bb-report option)
+our %bb_info;		# filename -> [bb_found, bb_hit]
+our $bb_coverage;	# Enable display of basic block coverage
 our $dark_mode;         # Use dark mode palette or normal
 our $charset = "UTF-8";	# Default charset for HTML pages
 our @fileview_sortlist;
@@ -431,6 +435,7 @@
 		"no-function-coverage"	=> \$no_func_coverage,
 		"branch-coverage"	=> \$br_coverage,
 		"no-branch-coverage"	=> \$no_br_coverage,
+		"bb-report=s"		=> \$bb_report,
 		"sort"			=> \$sort,
 		"no-sort"		=> \$no_sort,
 		"demangle-cpp"		=> \$demangle_cpp,
@@ -452,6 +457,10 @@
 	if ($no_br_coverage) {
 		$br_coverage = 0;
 	}
+
+	# Enable basic block coverage display if a BB report was provided
+	$bb_coverage = 0;
+	$bb_coverage = 1 if (defined($bb_report));
 
 	# Merge sort options
 	if ($no_sort) {
@@ -629,6 +638,8 @@
       --no-prefix                   Do not remove prefix from directory names
       --(no-)function-coverage      Enable (disable) function coverage display
       --(no-)branch-coverage        Enable (disable) branch coverage display
+      --bb-report FILENAME          Add basic block coverage data from
+                                    FILENAME to the report
 
 HTML output:
   -f, --frames                      Use HTML frames for source code view
@@ -700,10 +711,10 @@
 # Print overall coverage rates for the specified coverage types.
 #
 
-sub print_overall_rate($$$$$$$$$)
+sub print_overall_rate($$$$$$$$$$$$)
 {
 	my ($ln_do, $ln_found, $ln_hit, $fn_do, $fn_found, $fn_hit,
-	    $br_do, $br_found, $br_hit) = @_;
+	    $br_do, $br_found, $br_hit, $bb_do, $bb_found, $bb_hit) = @_;
 
 	info("Overall coverage rate:\n");
 	info("  lines......: %s\n",
@@ -715,6 +726,10 @@
 	info("  branches...: %s\n",
 	     get_overall_line($br_found, $br_hit, "branch", "branches"))
 		if ($br_do);
+	info("  basic blcks: %s\n",
+	     get_overall_line($bb_found, $bb_hit, "basic block",
+			      "basic blocks"))
+		if ($bb_do);
 }
 
 sub get_fn_list($)
@@ -856,6 +871,10 @@
 	my $total_fn_hit = 0;
 	my $total_br_found = 0;
 	my $total_br_hit = 0;
+	my $bb_found;
+	my $bb_hit;
+	my $total_bb_found = 0;
+	my $total_bb_hit = 0;
 	my $dir_name;
 	my $link_name;
 	my @dir_list;
@@ -883,6 +902,14 @@
 		# Apply baseline
 		info("Subtracting baseline data.\n");
 		%info_data = %{apply_baseline(\%info_data, \%base_data)};
+	}
+
+	# Read in the basic block coverage report if specified
+	if ($bb_report)
+	{
+		info("Reading basic block report file $bb_report\n");
+		%bb_info = %{read_bb_report($bb_report)};
+		attach_bb_report();
 	}
 
 	@dir_list = get_dir_list(keys(%info_data));
@@ -960,7 +987,7 @@
 	foreach $dir_name (@dir_list)
 	{
 		($lines_found, $lines_hit, $fn_found, $fn_hit,
-		 $br_found, $br_hit)
+		 $br_found, $br_hit, $bb_found, $bb_hit)
 			= process_dir($dir_name);
 
 		# Handle files in root directory gracefully
@@ -984,16 +1011,20 @@
 		}
 
 		$overview{$dir_name} = [$lines_found, $lines_hit, $fn_found,
-					$fn_hit, $br_found, $br_hit, $link_name,
+					$fn_hit, $br_found, $br_hit,
+					$link_name,
 					get_rate($lines_found, $lines_hit),
 					get_rate($fn_found, $fn_hit),
-					get_rate($br_found, $br_hit)];
+					get_rate($br_found, $br_hit),
+					$bb_found, $bb_hit];
 		$overall_found	+= $lines_found;
 		$overall_hit	+= $lines_hit;
 		$total_fn_found	+= $fn_found;
 		$total_fn_hit	+= $fn_hit;
 		$total_br_found	+= $br_found;
 		$total_br_hit	+= $br_hit;
+		$total_bb_found	+= $bb_found;
+		$total_bb_hit	+= $bb_hit;
 	}
 
 	# Generate overview page
@@ -1004,7 +1035,8 @@
 		write_dir_page($fileview_sortname[$_], ".", "", $test_title,
 			       undef, $overall_found, $overall_hit,
 			       $total_fn_found, $total_fn_hit, $total_br_found,
-			       $total_br_hit, \%overview, {}, {}, {}, 0, $_);
+			       $total_br_hit, $total_bb_found, $total_bb_hit,
+			       \%overview, {}, {}, {}, 0, $_);
 	}
 
 	# Check if there are any test case descriptions to write out
@@ -1014,12 +1046,14 @@
 		write_description_file( \%test_description,
 					$overall_found, $overall_hit,
 					$total_fn_found, $total_fn_hit,
-					$total_br_found, $total_br_hit);
+					$total_br_found, $total_br_hit,
+					$total_bb_found, $total_bb_hit);
 	}
 
 	print_overall_rate(1, $overall_found, $overall_hit,
 			   $func_coverage, $total_fn_found, $total_fn_hit,
-			   $br_coverage, $total_br_found, $total_br_hit);
+			   $br_coverage, $total_br_found, $total_br_hit,
+			   $bb_coverage, $total_bb_found, $total_bb_hit);
 
 	chdir($cwd);
 }
@@ -1046,12 +1080,13 @@
 	}
 }
 
-sub write_dir_page($$$$$$$$$$$$$$$$$)
+sub write_dir_page($$$$$$$$$$$$$$$$$$$)
 {
 	my ($name, $rel_dir, $base_dir, $title, $trunc_dir, $overall_found,
 	    $overall_hit, $total_fn_found, $total_fn_hit, $total_br_found,
-	    $total_br_hit, $overview, $testhash, $testfnchash, $testbrhash,
-	    $view_type, $sort_type) = @_;
+	    $total_br_hit, $total_bb_found, $total_bb_hit, $overview,
+	    $testhash, $testfnchash, $testbrhash, $view_type, $sort_type)
+		= @_;
 
 	# Generate directory overview page including details
 	html_create(*HTML_HANDLE, "$rel_dir/index$name.$html_ext");
@@ -1062,7 +1097,8 @@
 	write_html_prolog(*HTML_HANDLE, $base_dir, "LCOV - $title$trunc_dir");
 	write_header(*HTML_HANDLE, $view_type, $trunc_dir, $rel_dir,
 		     $overall_found, $overall_hit, $total_fn_found,
-		     $total_fn_hit, $total_br_found, $total_br_hit, $sort_type);
+		     $total_fn_hit, $total_br_found, $total_br_hit,
+		     $sort_type, $total_bb_found, $total_bb_hit);
 	write_file_table(*HTML_HANDLE, $base_dir, $overview, $testhash,
 			 $testfnchash, $testbrhash, $view_type, $sort_type);
 	write_html_epilog(*HTML_HANDLE, $base_dir);
@@ -1094,6 +1130,10 @@
 	my $total_fn_hit=0;
 	my $total_br_found = 0;
 	my $total_br_hit = 0;
+	my $bb_found;
+	my $bb_hit;
+	my $total_bb_found = 0;
+	my $total_bb_hit = 0;
 	my $base_name;
 	my $extension;
 	my $testdata;
@@ -1136,7 +1176,8 @@
 		my $func_link;
 
 		($lines_found, $lines_hit, $fn_found, $fn_hit, $br_found,
-		 $br_hit, $testdata, $testfncdata, $testbrdata) =
+		 $br_hit, $bb_found, $bb_hit, $testdata, $testfncdata,
+		 $testbrdata) =
 			process_file($trunc_dir, $rel_dir, $filename);
 
 		$base_name = basename($filename);
@@ -1155,7 +1196,8 @@
 					 $page_link,
 					 get_rate($lines_found, $lines_hit),
 					 get_rate($fn_found, $fn_hit),
-					 get_rate($br_found, $br_hit)];
+					 get_rate($br_found, $br_hit),
+					 $bb_found, $bb_hit];
 
 		$testhash{$base_name} = $testdata;
 		$testfnchash{$base_name} = $testfncdata;
@@ -1169,6 +1211,9 @@
 
 		$total_br_found += $br_found;
 		$total_br_hit   += $br_hit;
+
+		$total_bb_found += $bb_found;
+		$total_bb_hit   += $bb_hit;
 	}
 
 	# Create sorted pages
@@ -1177,7 +1222,8 @@
 		write_dir_page($fileview_sortname[$_], $rel_dir, $base_dir,
 			       $test_title, $trunc_dir, $overall_found,
 			       $overall_hit, $total_fn_found, $total_fn_hit,
-			       $total_br_found, $total_br_hit, \%overview, {},
+			       $total_br_found, $total_br_hit,
+			       $total_bb_found, $total_bb_hit, \%overview, {},
 			       {}, {}, 1, $_);
 		if (!$show_details) {
 			next;
@@ -1187,13 +1233,15 @@
 			       $base_dir, $test_title, $trunc_dir,
 			       $overall_found, $overall_hit, $total_fn_found,
 			       $total_fn_hit, $total_br_found, $total_br_hit,
+			       $total_bb_found, $total_bb_hit,
 			       \%overview, \%testhash, \%testfnchash,
 			       \%testbrhash, 1, $_);
 	}
 
 	# Calculate resulting line counts
 	return ($overall_found, $overall_hit, $total_fn_found, $total_fn_hit,
-		$total_br_found, $total_br_hit);
+		$total_br_found, $total_br_hit, $total_bb_found,
+		$total_bb_hit);
 }
 
 
@@ -1254,12 +1302,12 @@
 }
 
 
-sub write_function_page($$$$$$$$$$$$$$$$$$)
+sub write_function_page($$$$$$$$$$$$$$$$$$$$)
 {
 	my ($base_dir, $rel_dir, $trunc_dir, $base_name, $title,
 	    $lines_found, $lines_hit, $fn_found, $fn_hit, $br_found, $br_hit,
-	    $sumcount, $funcdata, $sumfnccount, $testfncdata, $sumbrcount,
-	    $testbrdata, $sort_type) = @_;
+	    $bb_found, $bb_hit, $sumcount, $funcdata, $sumfnccount,
+	    $testfncdata, $sumbrcount, $testbrdata, $sort_type) = @_;
 	my $pagetitle;
 	my $filename;
 
@@ -1274,7 +1322,8 @@
 	write_html_prolog(*HTML_HANDLE, $base_dir, $pagetitle);
 	write_header(*HTML_HANDLE, 4, "$trunc_dir/$base_name",
 		     "$rel_dir/$base_name", $lines_found, $lines_hit,
-		     $fn_found, $fn_hit, $br_found, $br_hit, $sort_type);
+		     $fn_found, $fn_hit, $br_found, $br_hit, $sort_type,
+		     $bb_found, $bb_hit);
 	write_function_table(*HTML_HANDLE, "$base_name.gcov.$html_ext",
 			     $sumcount, $funcdata,
 			     $sumfnccount, $testfncdata, $sumbrcount,
@@ -1313,6 +1362,8 @@
 	my $fn_hit;
 	my $br_found;
 	my $br_hit;
+	my $bb_found;
+	my $bb_hit;
 	my $converted;
 	my @source;
 	my $pagetitle;
@@ -1320,7 +1371,7 @@
 
 	($testdata, $sumcount, $funcdata, $checkdata, $testfncdata,
 	 $sumfnccount, $testbrdata, $sumbrcount, $lines_found, $lines_hit,
-	 $fn_found, $fn_hit, $br_found, $br_hit)
+	 $fn_found, $fn_hit, $br_found, $br_hit, $bb_found, $bb_hit)
 		= get_info_entry($info_data{$filename});
 
 	# Return after this point in case user asked us not to generate
@@ -1328,8 +1379,8 @@
 	if ($no_sourceview)
 	{
 		return ($lines_found, $lines_hit, $fn_found, $fn_hit,
-			$br_found, $br_hit, $testdata, $testfncdata,
-			$testbrdata);
+			$br_found, $br_hit, $bb_found, $bb_hit,
+			$testdata, $testfncdata, $testbrdata);
 	}
 
 	$converted = get_converted_lines($testdata);
@@ -1339,7 +1390,8 @@
 	write_html_prolog(*HTML_HANDLE, $base_dir, $pagetitle);
 	write_header(*HTML_HANDLE, 2, "$trunc_dir/$base_name",
 		     "$rel_dir/$base_name", $lines_found, $lines_hit,
-		     $fn_found, $fn_hit, $br_found, $br_hit, 0);
+		     $fn_found, $fn_hit, $br_found, $br_hit, 0,
+		     $bb_found, $bb_hit);
 	@source = write_source(*HTML_HANDLE, $filename, $sumcount, $checkdata,
 			       $converted, $funcdata, $sumbrcount);
 
@@ -1353,7 +1405,8 @@
 					    $base_name, $test_title,
 					    $lines_found, $lines_hit,
 					    $fn_found, $fn_hit, $br_found,
-					    $br_hit, $sumcount,
+					    $br_hit, $bb_found, $bb_hit,
+					    $sumcount,
 					    $funcdata, $sumfnccount,
 					    $testfncdata, $sumbrcount,
 					    $testbrdata, $_);
@@ -1364,8 +1417,8 @@
 	if (!$frames)
 	{
 		return ($lines_found, $lines_hit, $fn_found, $fn_hit,
-			$br_found, $br_hit, $testdata, $testfncdata,
-			$testbrdata);
+			$br_found, $br_hit, $bb_found, $bb_hit,
+			$testdata, $testfncdata, $testbrdata);
 	}
 
 	# Create overview png file
@@ -1386,10 +1439,12 @@
 	close(*HTML_HANDLE);
 
 	return ($lines_found, $lines_hit, $fn_found, $fn_hit, $br_found,
-		$br_hit, $testdata, $testfncdata, $testbrdata);
+		$br_hit, $bb_found, $bb_hit, $testdata, $testfncdata,
+		$testbrdata);
 }
 
 
+
 sub compress_brcount($)
 {
 	my ($brcount) = @_;
@@ -1793,11 +1848,13 @@
 	my $fn_hit = $_[0]->{"f_hit"};
 	my $br_found = $_[0]->{"b_found"};
 	my $br_hit = $_[0]->{"b_hit"};
+	my $bb_found = defined($_[0]->{"bb_found"}) ? $_[0]->{"bb_found"} : 0;
+	my $bb_hit = defined($_[0]->{"bb_hit"}) ? $_[0]->{"bb_hit"} : 0;
 
 	return ($testdata_ref, $sumcount_ref, $funcdata_ref, $checkdata_ref,
 		$testfncdata, $sumfnccount, $testbrdata, $sumbrcount,
 		$lines_found, $lines_hit, $fn_found, $fn_hit,
-		$br_found, $br_hit);
+		$br_found, $br_hit, $bb_found, $bb_hit);
 }
 
 
@@ -2481,6 +2538,119 @@
 
 	pop(@list);
 	return join("/", @list);
+}
+
+
+#
+# read_bb_report(filename)
+#
+# Read the JSON "basic block report" produced by the bb_cov_finalize tool
+# and return a hash mapping source file name -> [bb_found, bb_hit].
+#
+# The JSON has the following layout:
+#
+#   {
+#     "sources": {
+#       "/abs/path/file.c": { "found": N, "hit": M },
+#       ...
+#     },
+#     "total": { "found": N, "hit": M }
+#   }
+#
+
+sub read_bb_report($)
+{
+	my $filename = $_[0];
+	my %result;
+	my $json;
+	my $fh;
+
+	local $/;
+
+	open($fh, "<", $filename)
+		or die("ERROR: cannot read basic block report file $filename!\n");
+	$json = <$fh>;
+	close($fh);
+
+	# Prefer JSON::PP (core module since Perl 5.14); fall back to a tiny
+	# regular-expression based parser otherwise.
+	if (eval { require JSON::PP; 1 })
+	{
+		my $data = JSON::PP->new->utf8->decode($json);
+		my $sources = $data->{"sources"};
+
+		foreach my $file (keys(%{$sources})) {
+			$result{$file} = [ $sources->{$file}{"found"},
+					   $sources->{$file}{"hit"} ];
+		}
+	}
+	else
+	{
+		my $key;
+		my $found;
+		my $hit;
+
+		while ($json =~
+		       /"([^"]+)"\s*:\s*\{\s*"found"\s*:\s*(\d+),\s*"hit"\s*:\s*(\d+)/g)
+		{
+			$key = $1;
+			$found = $2;
+			$hit = $3;
+			$result{$key} = [ $found, $hit ];
+		}
+	}
+
+	info("Found %d basic block report entries.\n",
+	     scalar(keys(%result)));
+	return \%result;
+}
+
+
+#
+# attach_bb_report()
+#
+# Attach the data of %bb_info to the corresponding entries of %info_data.
+# Files are matched by normalized path first and by basename as a
+# fallback, so that the source file names of the LCOV data and of the
+# JSON report do not have to match exactly.
+#
+
+sub attach_bb_report()
+{
+	my %by_base;
+	my $file;
+
+	foreach $file (keys(%bb_info)) {
+		if (!defined($by_base{basename($file)}) &&
+		    defined($bb_info{$file}[0])) {
+			$by_base{basename($file)} = $file;
+		}
+	}
+
+	foreach $file (keys(%info_data)) {
+		my $found = 0;
+		my $hit = 0;
+		my $bb_file;
+
+		# Exact match on the (already normalized) path
+		if (defined($bb_info{$file})) {
+			$found = $bb_info{$file}[0];
+			$hit = $bb_info{$file}[1];
+		}
+		# Fallback: same basename
+		elsif (defined($by_base{basename($file)})) {
+			$bb_file = $by_base{basename($file)};
+			if ($bb_file ne $file) {
+				$found = $bb_info{$bb_file}[0];
+				$hit = $bb_info{$bb_file}[1];
+			}
+		}
+
+		if ($found > 0 || $hit > 0) {
+			$info_data{$file}->{"bb_found"} = $found;
+			$info_data{$file}->{"bb_hit"} = $hit;
+		}
+	}
 }
 
 
@@ -2699,7 +2869,7 @@
 # Die on error.
 #
 
-sub write_description_file($$$$$$$)
+sub write_description_file($$$$$$$$$)
 {
 	my %description = %{$_[0]};
 	my $found = $_[1];
@@ -2708,13 +2878,15 @@
 	my $fn_hit = $_[4];
 	my $br_found = $_[5];
 	my $br_hit = $_[6];
+	my $bb_found = $_[7];
+	my $bb_hit = $_[8];
 	my $test_name;
 	local *HTML_HANDLE;
 
 	html_create(*HTML_HANDLE,"descriptions.$html_ext");
 	write_html_prolog(*HTML_HANDLE, "", "LCOV - test case descriptions");
 	write_header(*HTML_HANDLE, 3, "", "", $found, $hit, $fn_found,
-		     $fn_hit, $br_found, $br_hit, 0);
+		     $fn_hit, $br_found, $br_hit, 0, $bb_found, $bb_hit);
 
 	write_test_table_prolog(*HTML_HANDLE,
 			 "Test case descriptions - alphabetical list");
@@ -4584,7 +4756,7 @@
 # header, test case description header, function view header)
 #
 
-sub write_header(*$$$$$$$$$$)
+sub write_header(*$$$$$$$$$$$$)
 {
 	local *HTML_HANDLE = $_[0];
 	my $type = $_[1];
@@ -4597,6 +4769,8 @@
 	my $br_found = $_[8];
 	my $br_hit = $_[9];
 	my $sort_type = $_[10];
+	my $bb_found = $_[11];
+	my $bb_hit = $_[12];
 	my $base_dir;
 	my $view;
 	my $test;
@@ -4770,6 +4944,17 @@
 		push(@row_right, [[undef, "headerItem", "Branches:"],
 				  [undef, "headerCovTableEntry", $br_hit],
 				  [undef, "headerCovTableEntry", $br_found],
+				  [undef, "headerCovTableEntry$style", $rate]])
+			if ($type != $HDR_TESTDESC);
+	}
+	# Basic block coverage
+	if ($bb_coverage) {
+		$style = $rate_name[classify_rate($bb_found, $bb_hit,
+						  $med_limit, $hi_limit)];
+		$rate = rate($bb_hit, $bb_found, " %");
+		push(@row_right, [[undef, "headerItem", "Basic Blocks:"],
+				  [undef, "headerCovTableEntry", $bb_hit],
+				  [undef, "headerCovTableEntry", $bb_found],
 				  [undef, "headerCovTableEntry$style", $rate]])
 			if ($type != $HDR_TESTDESC);
 	}
@@ -5007,6 +5192,8 @@
 	my $fn_hit;
 	my $br_found;
 	my $br_hit;
+	my $bb_found;
+	my $bb_hit;
 	my $page_link;
 	my $testname;
 	my $testdata;
@@ -5016,6 +5203,7 @@
 	my $line_code = "";
 	my $func_code;
 	my $br_code;
+	my $bb_code;
 	my $file_code;
 	my @head_columns;
 
@@ -5045,6 +5233,7 @@
 					"Branches",
 					$sort && $sort_type != $SORT_BRANCH,
 					$base_dir);
+		$bb_code = "Basic Block Coverage";
 	} else {
 		$file_code = get_file_code($HEAD_NO_DETAIL,
 					$fileview ? "Filename" : "Directory",
@@ -5059,10 +5248,12 @@
 		$br_code = get_br_code($HEAD_NO_DETAIL, "Branches",
 					$sort && $sort_type != $SORT_BRANCH,
 					$base_dir);
+		$bb_code = "Basic Block Coverage";
 	}
 	push(@head_columns, [ $line_code, 3 ]);
 	push(@head_columns, [ $func_code, 2]) if ($func_coverage);
 	push(@head_columns, [ $br_code, 2]) if ($br_coverage);
+	push(@head_columns, [ $bb_code, 3]) if ($bb_coverage);
 
 	write_file_table_prolog(*HTML_HANDLE, $file_code, @head_columns);
 
@@ -5084,6 +5275,15 @@
 			push(@columns, [$br_found, $br_hit, $br_med_limit,
 					$br_hi_limit, 0]);
 		}
+		# Basic block coverage
+		if ($bb_coverage) {
+			$bb_found = $overview->{$filename}[10];
+			$bb_hit = $overview->{$filename}[11];
+			$bb_found = 0 if (!defined($bb_found));
+			$bb_hit = 0 if (!defined($bb_hit));
+			push(@columns, [$bb_found, $bb_hit, $med_limit,
+					$hi_limit, 1]);
+		}
 		write_file_table_entry(*HTML_HANDLE, $base_dir, $filename,
 				       $page_link, @columns);
```

---

### Листинг 6. `00_install_deps.sh`

```bash
#!/usr/bin/env bash
#
# 00_install_deps.sh - install runtime dependencies on Rocky Linux.
#
# Installs the toolchain needed to build and run the assignment:
#   - clang / LLVM (llvm-profdata, llvm-cov, llvm-addr2line)
#   - gcc, make, git, patch, tar, gzip, diffutils, wget/curl
#   - perl + JSON::PP (used by the patched genhtml)
#   - python3 (used by tools/bb_cov_finalize.py)
#
# Run as root or with sudo, e.g.:
#   sudo bash 00_install_deps.sh
#

set -euo pipefail

echo "==> Installing build dependencies (Rocky Linux / dnf)"

dnf -y install epel-release || true

dnf -y install \
    gcc \
    make \
    git \
    patch \
    tar \
    gzip \
    wget \
    curl \
    diffutils \
    clang \
    llvm \
    perl \
    perl-JSON-PP \
    python3

echo "==> Checking toolchain"

command -v clang           >/dev/null && echo "clang:            $(clang --version | head -1)"
command -v llvm-profdata   >/dev/null && echo "llvm-profdata:    $(llvm-profdata --version | head -1)"
command -v llvm-cov        >/dev/null && echo "llvm-cov:         $(llvm-cov --version | head -1)"
command -v llvm-addr2line  >/dev/null && echo "llvm-addr2line:   available"
command -v perl            >/dev/null && echo "perl:             $(perl -e 'print $^V')"
command -v python3         >/dev/null && echo "python3:          $(python3 --version)"

echo "==> Done. Toolchain is ready."
```

---

### Листинг 7. `01_build_runtime.sh`

```bash
#!/usr/bin/env bash
#
# 01_build_runtime.sh - build the basic-block coverage runtime component.
#
# Produces build/libbbcov.a from src/bb_cov_runtime.c.  The runtime is
# compiled WITHOUT any coverage instrumentation on purpose, otherwise the
# instrumentation callbacks would recurse into themselves.
#

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/tools/lib_common.sh"

find_llvm_tools

mkdir -p "$BUILD_DIR"

if [ ! -f "$RUNTIME_LIB" ]; then
    log "Compiling the basic block coverage runtime ($SRC_DIR/bb_cov_runtime.c)"
    "$CLANG" -O2 -c "$SRC_DIR/bb_cov_runtime.c" -o "$BUILD_DIR/bb_cov_runtime.o"
    ar rcs "$RUNTIME_LIB" "$BUILD_DIR/bb_cov_runtime.o"
fi

echo "==> Build artifacts:"
ls -l "$RUNTIME_LIB"
echo "==> Runtime component ready."
```

---

### Листинг 8. `02_build_genhtml.sh`

```bash
#!/usr/bin/env bash
#
# 02_build_genhtml.sh - build the PATCHED genhtml utility.
#
# It downloads the LCOV 1.16 source tree (the last classic release whose
# genhtml is a single self-contained Perl script), keeps the pristine
# genhtml as genhtml_orig and applies our patch (patch/genhtml.patch)
# which adds
#
#   --bb-report FILENAME
#
# to the tool.  Two callable wrappers are created:
#
#   vendor/genhtml       - patched genhtml (Basic Block Coverage support)
#   vendor/genhtml_orig  - original unpatched genhtml (backward compat)
#

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/tools/lib_common.sh"

LCOV_VERSION="1.16"
LCOV_URL="https://github.com/linux-test-project/lcov/releases/download/v${LCOV_VERSION}/lcov-${LCOV_VERSION}.tar.gz"
VENDOR_DIR="$ROOT/vendor"

mkdir -p "$VENDOR_DIR"

if [ ! -x "$VENDOR_DIR/lcov-${LCOV_VERSION}/bin/genhtml" ]; then
    if [ ! -f "$VENDOR_DIR/lcov-${LCOV_VERSION}.tar.gz" ]; then
        log "Downloading LCOV ${LCOV_VERSION} from $LCOV_URL"
        ( cd "$VENDOR_DIR" && curl -fL -o "lcov-${LCOV_VERSION}.tar.gz" "$LCOV_URL" )
    fi
    log "Extracting LCOV ${LCOV_VERSION}"
    tar -xzf "$VENDOR_DIR/lcov-${LCOV_VERSION}.tar.gz" -C "$VENDOR_DIR"
fi

log "Backing up the pristine genhtml"
cp -f "$VENDOR_DIR/lcov-${LCOV_VERSION}/bin/genhtml" \
      "$VENDOR_DIR/lcov-${LCOV_VERSION}/bin/genhtml.orig"

if ! grep -q "bb-report" "$VENDOR_DIR/lcov-${LCOV_VERSION}/bin/genhtml"; then
    log "Applying patch/genhtml.patch"
    ( cd "$VENDOR_DIR/lcov-${LCOV_VERSION}" \
      && patch -p1 < "$PATCH_DIR/genhtml.patch" )
fi

chmod +x "$VENDOR_DIR/lcov-${LCOV_VERSION}/bin/genhtml" \
         "$VENDOR_DIR/lcov-${LCOV_VERSION}/bin/genhtml.orig"

cat > "$GENHTML" <<EOF
#!/usr/bin/env bash
exec "$VENDOR_DIR/lcov-${LCOV_VERSION}/bin/genhtml" "\$@"
EOF
chmod +x "$GENHTML"

cat > "$GENHTML_ORIG" <<EOF
#!/usr/bin/env bash
exec "$VENDOR_DIR/lcov-${LCOV_VERSION}/bin/genhtml.orig" "\$@"
EOF
chmod +x "$GENHTML_ORIG"

echo "==> Patched genhtml: $GENHTML"
echo "==> Original genhtml (compat): $GENHTML_ORIG"
echo "==> Checking option support:"
"$GENHTML" --version
"$GENHTML" --help | grep -A2 "bb-report" || true
```

---

### Листинг 9. `tools/build_project.sh`

```bash
#!/usr/bin/env bash
#
# build_project.sh - compile an open-source project with the combined
# (standard + basic block) instrumentation, run its test inputs, merge
# the resulting profiles and produce:
#
#   output/<PROJECT_NAME>/coverage.info     (line/func/branch coverage)
#   output/<PROJECT_NAME>/bb_cov.json       (basic block coverage)
#
# The project is described by "<project_dir>/build.conf":
#
#   PROJECT_C_FILES="..."     project .c files to instrument
#   HARNESS_C_FILE="..."      test driver, also instrumented
#   EXTRA_INCLUDES="-I..."    include flags for project headers
#   EXTRA_LDFLAGS="..."
#   TESTS=("..." ...)         one test input per array element; each
#                             produces a .profraw and contributes to the
#                             merged bb_cov_raw.json
#

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="${PROJECT_DIR:-$1}"
PROJECT_NAME="${PROJECT_NAME:-$2}"
source "$HERE/lib_common.sh"

[ $# -ge 2 ] || die "usage: build_project.sh <project_dir> <project_name>"
[ -f "$PROJECT_DIR/build.conf" ] || die "no build.conf in $PROJECT_DIR"
[ -f "$RUNTIME_LIB" ] || die "runtime lib not built (run 01_build_runtime.sh first)"

# Load project configuration
source "$PROJECT_DIR/build.conf"

find_llvm_tools

OUT_DIR="$OUTPUT_DIR/$PROJECT_NAME"
RUNS_DIR="$OUT_DIR/runs"
BIN="$OUT_DIR/bin/$PROJECT_NAME"
RAW_JSON="$OUT_DIR/bb_cov_raw.json"

rm -rf "$OUT_DIR"
mkdir -p "$RUNS_DIR" "$OUT_DIR/bin"

compile_project() {
    log "Compiling $PROJECT_NAME"
    ( cd "$PROJECT_DIR" && \
      "$CLANG" "${INSTR_FLAGS[@]}" $EXTRA_INCLUDES \
               $PROJECT_C_FILES $HARNESS_C_FILE \
               "$RUNTIME_LIB" $EXTRA_LDFLAGS \
               -o "$BIN" )
}

run_tests() {
    local i=0
    local testname
    local profraw

    mkdir -p "$OUT_DIR/run_work"

    for testname in "${TESTS[@]:-}"; do
        i=$((i + 1))
        profraw="$RUNS_DIR/run_$i.profraw"
        if [ -n "$testname" ]; then
            log "Running test case #$i: '${testname}'"
        else
            log "Running test case #$i (default)"
        fi
        # Each run writes its own profile file; the BB coverage JSON is
        # merged automatically by the runtime (union -> no double count).
        # Tests run in a dedicated scratch directory (the microtar tests
        # create/read a tar file there).
        ( cd "$OUT_DIR/run_work" && \
          LLVM_PROFILE_FILE="$profraw" \
          BB_COV_OUT="$RAW_JSON" \
          BB_COV_QUIET=1 \
          "$BIN" $testname ) || true
    done
}

merge_profiles() {
    local nprof
    nprof=$(ls "$RUNS_DIR"/*.profraw 2>/dev/null | wc -l | tr -d ' ')
    [ "$nprof" -gt 0 ] || die "no .profraw files produced"
    log "Merging $nprof profile(s) with llvm-profdata"
    "$LLVM_PROFDATA" merge -sparse "$RUNS_DIR"/*.profraw \
        -o "$OUT_DIR/default.profdata"

    log "Exporting line/function/branch coverage to lcov format"
    llvm_cov_export_lcov "$BIN" "$OUT_DIR/default.profdata" \
        "$OUT_DIR/coverage.info"
}

finalize_bb() {
    log "Attributing basic blocks to source files"
    python3 "$TOOLS_DIR/bb_cov_finalize.py" \
        --raw "$RAW_JSON" \
        --binary "$BIN" \
        --output "$OUT_DIR/bb_cov.json" \
        --addr2line "$LLVM_ADDR2LINE"
}

compile_project
run_tests
merge_profiles
finalize_bb

echo "==> Project '$PROJECT_NAME' artifacts:"
ls -l "$OUT_DIR/coverage.info" "$OUT_DIR/bb_cov.json"
echo "==> Done."
```

---

### Листинг 10. `projects/cjson/build.conf`

```bash
#!/usr/bin/env bash
#
# build.conf for the cJSON project.
#
# PROJECT_C_FILES - cJSON sources instrumented together with the harness
# HARNESS_C_FILE  - test driver
# EXTRA_INCLUDES  - where to find cJSON.h
# TESTS           - one entry per test run; each run merges into the
#                   same bb_cov_raw.json (union)
#
PROJECT_C_FILES="cJSON.c"
HARNESS_C_FILE="harness_main.c"
EXTRA_INCLUDES="-I."
EXTRA_LDFLAGS="-lm"
TESTS=("basic" "nested" "build" "invalid")
```

---

### Листинг 11. `projects/cjson/harness_main.c`

```c
// harness_main.c - test driver for the cJSON open-source project.
//
// The executable is compiled with the combined instrumentation
//  -fprofile-instr-generate -fcoverage-mapping
//  -fsanitize-coverage=bb,no-prune,inline-bool-flag,pc-table
// so executing different test cases exercises different basic blocks.
//
// Usage:  cjson_test_case  <testname>
//   basic    parse a "product" JSON and validate a subset of its fields
//   nested   parse a nested structure and walk the object tree
//   build    construct a JSON document via the cJSON API
//   invalid  try to parse malformed JSON (cJSON_Parse must return NULL)
//
// Every test returns 0 on success, non-zero otherwise.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "cJSON.h"

static int test_basic(void)
{
    const char *text =
        "{\"name\": \"widget\", \"price\": 19.99, \"tags\": "
        "[\"tool\", \"demo\"], \"in_stock\": true, \"qty\": 42, "
        "\"meta\": {\"weight\": 1.2, \"color\": \"blue\"}}";

    cJSON *root = cJSON_Parse(text);
    cJSON *item;

    if (root == NULL) {
        fprintf(stderr, "cJSON_Parse failed\n");
        return 1;
    }

    item = cJSON_GetObjectItemCaseSensitive(root, "name");
    if (!cJSON_IsString(item) || strcmp(item->valuestring, "widget") != 0) {
        fprintf(stderr, "bad name\n");
        cJSON_Delete(root);
        return 1;
    }

    item = cJSON_GetObjectItemCaseSensitive(root, "qty");
    if (!cJSON_IsNumber(item) || item->valueint != 42) {
        fprintf(stderr, "bad qty\n");
        cJSON_Delete(root);
        return 1;
    }

    item = cJSON_GetObjectItemCaseSensitive(root, "in_stock");
    if (!cJSON_IsTrue(item)) {
        fprintf(stderr, "bad in_stock\n");
        cJSON_Delete(root);
        return 1;
    }

    item = cJSON_GetObjectItemCaseSensitive(root, "tags");
    if (cJSON_IsArray(item) && cJSON_GetArraySize(item) == 2) {
        cJSON *first = cJSON_GetArrayItem(item, 0);
        if (first && cJSON_IsString(first) &&
            strcmp(first->valuestring, "tool") != 0) {
            fprintf(stderr, "bad first tag\n");
            cJSON_Delete(root);
            return 1;
        }
    } else {
        fprintf(stderr, "bad tags\n");
        cJSON_Delete(root);
        return 1;
    }

    cJSON_Delete(root);
    return 0;
}

static int test_nested(void)
{
    const char *text =
        "{\"a\": {\"aa\": [1, 2, 3], \"ab\": {\"aba\": \"x\"}}, "
        "\"b\": [{\"b1\": 1}, {\"b1\": 2}]}";

    cJSON *root = cJSON_Parse(text);
    cJSON *a;
    cJSON *b;
    int len = 0;

    if (root == NULL) {
        fprintf(stderr, "cJSON_Parse failed\n");
        return 1;
    }

    a = cJSON_GetObjectItemCaseSensitive(root, "a");
    if (!a) {
        fprintf(stderr, "no 'a'\n");
        cJSON_Delete(root);
        return 1;
    }
    cJSON *aa = cJSON_GetObjectItemCaseSensitive(a, "aa");
    if (aa && cJSON_IsArray(aa)) {
        cJSON *elem;
        cJSON_ArrayForEach(elem, aa) { len++; (void)elem; }
    }
    if (len != 3) {
        fprintf(stderr, "bad nested array\n");
        cJSON_Delete(root);
        return 1;
    }

    b = cJSON_GetObjectItemCaseSensitive(root, "b");
    if (b && cJSON_IsArray(b)) {
        int i;
        int cnt = cJSON_GetArraySize(b);
        for (i = 0; i < cnt; i++) {
            cJSON *entry = cJSON_GetArrayItem(b, i);
            cJSON *b1 = entry ? cJSON_GetObjectItem(entry, "b1") : NULL;
            if (b1 && b1->valueint != i + 1) {
                fprintf(stderr, "bad b1 value\n");
                cJSON_Delete(root);
                return 1;
            }
        }
    } else {
        fprintf(stderr, "bad 'b'\n");
        cJSON_Delete(root);
        return 1;
    }

    cJSON_Delete(root);
    return 0;
}

static int test_build(void)
{
    cJSON *root = cJSON_CreateObject();
    cJSON *list;
    int i;

    if (root == NULL)
        return 1;

    cJSON_AddStringToObject(root, "type", "measurement");
    cJSON_AddNumberToObject(root, "value", 3.14);
    cJSON_AddFalseToObject(root, "ok");

    list = cJSON_AddArrayToObject(root, "samples");
    for (i = 0; i < 5; i++)
        cJSON_AddItemToArray(list, cJSON_CreateNumber(i * 10));

    char *dump = cJSON_PrintUnformatted(root);
    if (dump == NULL) {
        cJSON_Delete(root);
        return 1;
    }

    /* Round trip: parse what we just printed. */
    cJSON *parsed = cJSON_Parse(dump);
    free(dump);
    if (parsed == NULL) {
        cJSON_Delete(root);
        return 1;
    }
    cJSON_Delete(parsed);
    cJSON_Delete(root);
    return 0;
}

static int test_invalid(void)
{
    const char *bad_texts[] = {
        "{ this is not json",
        "[1,2,",
        "{\"key\": }",
        NULL
    };
    int i;

    for (i = 0; bad_texts[i] != NULL; i++) {
        cJSON *root = cJSON_Parse(bad_texts[i]);
        if (root != NULL) {
            fprintf(stderr, "malformed input was accepted\n");
            cJSON_Delete(root);
            return 1;
        }
    }
    return 0;
}

int main(int argc, char **argv)
{
    const char *test = (argc > 1) ? argv[1] : "basic";

    if (strcmp(test, "basic") == 0)
        return test_basic();
    if (strcmp(test, "nested") == 0)
        return test_nested();
    if (strcmp(test, "build") == 0)
        return test_build();
    if (strcmp(test, "invalid") == 0)
        return test_invalid();

    fprintf(stderr, "unknown test: %s\n", test);
    return 2;
}
```

---

### Листинг 12. `projects/cjson/build_and_run.sh`

```bash
#!/usr/bin/env bash
#
# build_and_run.sh - download (if needed), build and measure the cJSON
# open-source project (https://github.com/DaveGamble/cJSON).
#

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"

if [ ! -f "$HERE/cJSON.c" ]; then
    echo "==> Cloning cJSON"
    git clone --depth 1 https://github.com/DaveGamble/cJSON "$HERE/repo"
    cp "$HERE/repo/cJSON.c" "$HERE/repo/cJSON.h" "$HERE/"
fi

PROJECT_DIR="$HERE" PROJECT_NAME="cjson" \
    "$ROOT/tools/build_project.sh" "$HERE" cjson
```

---

### Листинг 13. `projects/microtar/build.conf`

```bash
#!/usr/bin/env bash
#
# build.conf for the microtar project.
#
PROJECT_C_FILES="microtar.c"
HARNESS_C_FILE="harness_main.c"
EXTRA_INCLUDES="-I."
EXTRA_LDFLAGS=""
TESTS=("write" "read" "round" "missing")
```

---

### Листинг 14. `projects/microtar/harness_main.c`

```c
// harness_main.c - test driver for the microtar open-source project
// (https://github.com/rxi/microtar).
//
// The executable is compiled with the combined instrumentation
//  -fprofile-instr-generate -fcoverage-mapping
//  -fsanitize-coverage=bb,no-prune,inline-bool-flag,pc-table
//
// Usage:  mtar_test_case  <testname>
//   write    create a tar archive with two regular files
//   read     read back and verify the archive created by "write"
//   round    write several files in small chunks, read them back
//   missing  look for a file that does not exist (mtar_find fails)
//
// Every test returns 0 on success, non-zero otherwise.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "microtar.h"

static const char *ARCHIVE = "mtar_test.tar";

static int test_write(void)
{
    mtar_t tar;
    const char *payload1 = "hello, microtar!";
    const char *payload2 = "second file with a bit more data in it";

    if (mtar_open(&tar, ARCHIVE, "w") != MTAR_ESUCCESS) {
        fprintf(stderr, "mtar_open(w) failed\n");
        return 1;
    }

    /* file 1 */
    if (mtar_write_file_header(&tar, "greeting.txt",
                               (unsigned)strlen(payload1)) != MTAR_ESUCCESS) {
        fprintf(stderr, "write_file_header 1 failed\n");
        mtar_close(&tar);
        return 1;
    }
    if (mtar_write_data(&tar, payload1, (unsigned)strlen(payload1))
        != MTAR_ESUCCESS) {
        fprintf(stderr, "write_data 1 failed\n");
        mtar_close(&tar);
        return 1;
    }

    /* file 2 */
    if (mtar_write_file_header(&tar, "misc/second.txt",
                               (unsigned)strlen(payload2)) != MTAR_ESUCCESS) {
        fprintf(stderr, "write_file_header 2 failed\n");
        mtar_close(&tar);
        return 1;
    }
    if (mtar_write_data(&tar, payload2, (unsigned)strlen(payload2))
        != MTAR_ESUCCESS) {
        fprintf(stderr, "write_data 2 failed\n");
        mtar_close(&tar);
        return 1;
    }

    if (mtar_finalize(&tar) != MTAR_ESUCCESS) {
        fprintf(stderr, "mtar_finalize failed\n");
        mtar_close(&tar);
        return 1;
    }
    mtar_close(&tar);
    return 0;
}

static int test_read(void)
{
    mtar_t tar;
    mtar_header_t h;
    char *buf = NULL;
    int nentries = 0;

    if (mtar_open(&tar, ARCHIVE, "r") != MTAR_ESUCCESS) {
        fprintf(stderr, "mtar_open(r) failed\n");
        return 1;
    }

    while (mtar_read_header(&tar, &h) == MTAR_ESUCCESS) {
        nentries++;
        if (nentries == 1 && strcmp(h.name, "greeting.txt") != 0) {
            fprintf(stderr, "unexpected first entry: %s\n", h.name);
            mtar_close(&tar);
            free(buf);
            return 1;
        }
        /* Consume the data of the entry. */
        buf = realloc(buf, h.size ? h.size : 1);
        if (h.size && mtar_read_data(&tar, buf, h.size) != MTAR_ESUCCESS) {
            fprintf(stderr, "mtar_read_data failed\n");
            mtar_close(&tar);
            free(buf);
            return 1;
        }
        if (nentries == 1 && strncmp(buf, "hello, microtar!",
                                      sizeof("hello, microtar!") - 1) != 0) {
            fprintf(stderr, "wrong content of greeting.txt\n");
            mtar_close(&tar);
            free(buf);
            return 1;
        }
        if (mtar_next(&tar) != MTAR_ESUCCESS)
            break;
    }

    free(buf);
    mtar_close(&tar);

    if (nentries != 2) {
        fprintf(stderr, "expected 2 entries, got %d\n", nentries);
        return 1;
    }
    return 0;
}

static int test_round(void)
{
    mtar_t tar;
    mtar_header_t h;
    int i, k;
    int total = 0;

    if (mtar_open(&tar, ARCHIVE, "w") != MTAR_ESUCCESS) {
        fprintf(stderr, "mtar_open(w) failed\n");
        return 1;
    }

    /* 3 files of 100 bytes each, written in 10-byte chunks */
    for (i = 0; i < 3; i++) {
        char name[64];
        char chunk[10];
        snprintf(name, sizeof(name), "data/file_%d.bin", i);
        if (mtar_write_file_header(&tar, name, 100) != MTAR_ESUCCESS) {
            fprintf(stderr, "write_file_header failed\n");
            mtar_close(&tar);
            return 1;
        }
        for (k = 0; k < 10; k++) {
            memset(chunk, 'a' + i, sizeof(chunk));
            if (mtar_write_data(&tar, chunk, sizeof(chunk)) != MTAR_ESUCCESS) {
                fprintf(stderr, "write_data chunk failed\n");
                mtar_close(&tar);
                return 1;
            }
        }
    }
    if (mtar_finalize(&tar) != MTAR_ESUCCESS) {
        fprintf(stderr, "finalize failed\n");
        mtar_close(&tar);
        return 1;
    }
    mtar_close(&tar);

    /* read back and count bytes */
    if (mtar_open(&tar, ARCHIVE, "r") != MTAR_ESUCCESS) {
        fprintf(stderr, "reopen failed\n");
        return 1;
    }
    while (mtar_read_header(&tar, &h) == MTAR_ESUCCESS) {
        total += h.size;
        while (h.size > 0) {
            char tmp[32];
            unsigned want = h.size < sizeof(tmp) ? h.size
                                                 : (unsigned)sizeof(tmp);
            if (mtar_read_data(&tar, tmp, want) != MTAR_ESUCCESS) {
                fprintf(stderr, "read chunk failed\n");
                mtar_close(&tar);
                return 1;
            }
            h.size -= want;
        }
        if (mtar_next(&tar) != MTAR_ESUCCESS)
            break;
    }
    mtar_close(&tar);

    if (total != 300) {
        fprintf(stderr, "expected 300 total bytes, got %d\n", total);
        return 1;
    }
    return 0;
}

static int test_missing(void)
{
    mtar_t tar;
    mtar_header_t h;

    if (mtar_open(&tar, ARCHIVE, "r") != MTAR_ESUCCESS) {
        fprintf(stderr, "mtar_open(r) failed\n");
        return 1;
    }
    /* MTAR_ENOTFOUND is the expected outcome here. */
    int rc = mtar_find(&tar, "no_such_file.txt", &h);
    mtar_close(&tar);

    if (rc != MTAR_ENOTFOUND) {
        fprintf(stderr, "mtar_find returned %d, expected MTAR_ENOTFOUND\n",
                rc);
        return 1;
    }
    return 0;
}

int main(int argc, char **argv)
{
    const char *test = (argc > 1) ? argv[1] : "read";

    /* The "read" and "missing" tests need an archive created by "write". */
    if (strcmp(test, "round") == 0)
        return test_round();
    if (strcmp(test, "write") == 0)
        return test_write();
    if (strcmp(test, "missing") == 0)
        return test_missing();

    return test_read();
}
```

---

### Листинг 15. `projects/microtar/build_and_run.sh`

```bash
#!/usr/bin/env bash
#
# build_and_run.sh - download (if needed), build and measure the microtar
# open-source project (https://github.com/rxi/microtar).
#

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"

if [ ! -f "$HERE/microtar.c" ]; then
    echo "==> Cloning microtar"
    git clone --depth 1 https://github.com/rxi/microtar "$HERE/repo"
    cp "$HERE/repo/src/microtar.c" "$HERE/repo/src/microtar.h" "$HERE/"
fi

"$ROOT/tools/build_project.sh" "$HERE" microtar
```

---

### Листинг 16. `verify/check_compat.sh`

```bash
#!/usr/bin/env bash
#
# check_compat.sh - verify backward compatibility and generate the
# report with the Basic Block Coverage metric.
#
# For a given project (positional argument) it performs three genhtml
# runs on the same coverage.info:
#
#   1. original (pristine) genhtml:            output/<p>/html_orig
#   2. patched genhtml WITHOUT --bb-report:    output/<p>/html_plain
#   3. patched genhtml WITH    --bb-report:    output/<p>/html_bb
#
# Steps 1 and 2 must produce bit-identical trees (requirement: without
# --bb-report the utility must work like the original genhtml).  Step 3
# additionally shows the Basic Block Coverage column.
#
# Usage: check_compat.sh <project_name>
#

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
source "$ROOT/tools/lib_common.sh"

[ $# -ge 1 ] || die "usage: check_compat.sh <project_name>"

PROJECT_NAME="$1"
OUT_DIR="$OUTPUT_DIR/$PROJECT_NAME"
INFO="$OUT_DIR/coverage.info"
BB_JSON="$OUT_DIR/bb_cov.json"

[ -f "$INFO" ]   || die "coverage.info not found: $INFO"
[ -f "$BB_JSON" ] || die "bb_cov.json not found: $BB_JSON"
[ -x "$GENHTML_ORIG" ] || die "$GENHTML_ORIG not built (run 02_build_genhtml.sh)"

# --- 1. original genhtml -------------------------------------------------
log "($PROJECT_NAME) 1/3 original genhtml  -> html_orig"
rm -rf "$OUT_DIR/html_orig"
"$GENHTML_ORIG" "$INFO" --branch-coverage \
    -o "$OUT_DIR/html_orig" >/dev/null 2>&1

# --- 2. patched genhtml without --bb-report ------------------------------
log "($PROJECT_NAME) 2/3 patched genhtml without --bb-report -> html_plain"
rm -rf "$OUT_DIR/html_plain"
"$GENHTML" "$INFO" --branch-coverage \
    -o "$OUT_DIR/html_plain" >/dev/null 2>&1

# --- compare -------------------------------------------------------------
log "($PROJECT_NAME) backward compatibility check (diff -r)"
COMPAT_RESULT="OK"
if diff -r "$OUT_DIR/html_orig" "$OUT_DIR/html_plain" > "$OUT_DIR/compat.diff" \
   2>&1; then
    echo "($PROJECT_NAME) PASS: html_orig == html_plain (bit-identical)"
else
    COMPAT_RESULT="DIFFERS"
    echo "($PROJECT_NAME) FAIL: html_orig != html_plain, see output/$PROJECT_NAME/compat.diff" >&2
fi

# --- 3. patched genhtml with --bb-report ---------------------------------
log "($PROJECT_NAME) 3/3 patched genhtml with --bb-report  -> html_bb"
rm -rf "$OUT_DIR/html_bb"
"$GENHTML" "$INFO" --bb-report "$BB_JSON" --branch-coverage \
    -o "$OUT_DIR/html_bb" >/dev/null 2>&1

# --- reports -------------------------------------------------------------
HAS_BB_PLAIN=$(grep -r -l "Basic Block Coverage" "$OUT_DIR"/html_plain \
               2>/dev/null | wc -l | tr -d ' ' || true)
HAS_BB_BB=$(grep -r -l "Basic Block Coverage" "$OUT_DIR/html_bb" \
            2>/dev/null | wc -l | tr -d ' ' || true)
BB_HEADER=$(grep -A4 'headerItem">Basic Blocks:' \
            "$OUT_DIR/html_bb/index.html" 2>/dev/null \
            | tr '\n' ' ' | sed -E 's/<[^>]+>/ /g' | tr -s ' ' \
            || true)

echo "($PROJECT_NAME) 'Basic Block Coverage' occurrences:"
echo "  html_plain: $HAS_BB_PLAIN (must be 0)"
echo "  html_bb   : $HAS_BB_BB   (must be > 0)"
if [ -n "$BB_HEADER" ]; then
    echo "  project page header: $BB_HEADER"
fi

# Per-file / per-directory metric presence
FILES_WITH_BB=$(grep -r -l "Basic Blocks:" \
               "$OUT_DIR/html_bb" --include="*.gcov.html" \
               2>/dev/null | wc -l | tr -d ' ' || true)
DIRS_WITH_BB=$(grep -r -l "Basic Block Coverage" \
              "$OUT_DIR/html_bb" --include="index.html" \
              2>/dev/null | wc -l | tr -d ' ' || true)

echo "($PROJECT_NAME) file pages with BB metric : $FILES_WITH_BB"
echo "($PROJECT_NAME) directory index with BB   : $DIRS_WITH_BB"

echo "($PROJECT_NAME) COMPAT_RESULT=$COMPAT_RESULT"
```

---

### Листинг 17. `run_all.sh`

```bash
#!/usr/bin/env bash
#
# run_all.sh - master script.
#
# Executes the whole bonus assignment on a Rocky Linux VM:
#
#   1. install dependencies      (00_install_deps.sh if --install passed)
#   2. build the bb runtime      (01_build_runtime.sh)
#   3. build the patched genhtml (02_build_genhtml.sh)
#   4. build & measure 2 OSS projects (cJSON, microtar)
#   5. generate reports + backward compatibility check
#
# Usage:
#   bash run_all.sh            # assumes deps are installed
#   bash run_all.sh --install  # also run sudo dnf install
#   bash run_all.sh --project cjson          # single project
#

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/tools/lib_common.sh"

INSTALL=0
PROJECTS=()

for arg in "$@"; do
    case "$arg" in
        --install) INSTALL=1 ;;
        --project)
            echo "use: --project <name>" >&2
            exit 2
            ;;
        --project=*) PROJECTS+=("${arg#--project=}") ;;
        *)
            if [[ "$arg" != -* ]]; then
                PROJECTS+=("$arg")
            else
                echo "unknown option: $arg" >&2
                exit 2
            fi
            ;;
    esac
done

if [ ${#PROJECTS[@]} -eq 0 ]; then
    PROJECTS=(cjson microtar)
fi

echo "======================================================"
echo " Basic Block Coverage for genhtml (LCOV) - bonus #1"
echo "======================================================"

if [ "$INSTALL" -eq 1 ]; then
    echo ">>> Step 0: install dependencies"
    bash "$HERE/00_install_deps.sh"
fi

echo ">>> Step 1: build the basic-block runtime component"
bash "$HERE/01_build_runtime.sh"

echo ">>> Step 2: build the patched genhtml (LCOV 1.16 + --bb-report)"
bash "$HERE/02_build_genhtml.sh"

for p in "${PROJECTS[@]}"; do
    echo ">>> Step 3: build & measure project: $p"
    bash "$HERE/projects/$p/build_and_run.sh"
    echo ">>> Step 4: reports & backward compatibility check: $p"
    bash "$HERE/verify/check_compat.sh" "$p" || true
done

echo "======================================================"
echo " Results"
echo "======================================================"
for p in "${PROJECTS[@]}"; do
    OUT="$OUTPUT_DIR/$p"
    echo "--- $p ---"
    echo "  coverage.info : $OUT/coverage.info"
    echo "  bb_cov.json   : $OUT/bb_cov.json"
    echo "  html_orig     : $OUT/html_orig/   (pristine genhtml)"
    echo "  html_plain    : $OUT/html_plain/  (patched without --bb-report)"
    echo "  html_bb       : $OUT/html_bb/     (patched with --bb-report)"
    grep -A4 "headerItem\">Basic Blocks:" "$OUT/html_bb/index.html" \
        2>/dev/null | tr '\n' ' ' | sed -E 's/<[^>]+>/ /g' | tr -s ' ' \
        | sed 's/^/  project page:/'
done

echo "======================================================"
echo " Done. Open output/<project>/html_bb/index.html in a browser"
echo " to inspect the Basic Block Coverage metric."
echo "======================================================"
```

---

### Листинг 18. `.gitignore`

```gitignore
build/
output/
vendor/
*.profraw
*.profdata
projects/cjson/repo/
projects/microtar/repo/
projects/cjson/cJSON.c
projects/cjson/cJSON.h
projects/microtar/microtar.c
projects/microtar/microtar.h
.DS_Store
```

---

## 4. Итоговая проверка результата

1. **Обратная совместимость** — `diff -r html_orig html_plain` не должен
   давать различий (автоматически проверяет `verify/check_compat.sh`).
2. **Новая метрика** — в `html_bb/index.html` колонка
   «Basic Block Coverage» (визуальный индикатор + проценты +
   «выполнено / всего»), а на страницах каталогов и файлов — строки
   «Basic Blocks».
3. **Консольная сводка** патченного `genhtml` содержит строку
   `basic blcks: N% (M of K basic blocks)`.