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