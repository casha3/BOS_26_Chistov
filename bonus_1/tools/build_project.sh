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

run_with_timeout() {
    local secs="${1:-30}"
    shift
    local rc=0

    "$@" &
    local pid=$!
    ( sleep "$secs"; kill -9 "$pid" 2>/dev/null ) &
    local killer=$!

    wait "$pid" 2>/dev/null; rc=$?
    kill "$killer" 2>/dev/null
    wait "$killer" 2>/dev/null || true   # killer already dead -> ignore
    return $rc
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
        # create/read a tar file there). RUN_TIMEOUT protects against
        # programs that do not terminate on their own. TEST_STDIN, if
        # set, is piped to the program's stdin on every run.
        # Переменные окружения экспортируются явно, чтобы их увидели и
        # программа, и обёртка таймаута (иначе через pipe+функцию они
        # могут не попасть в фоновый процесс).
        export LLVM_PROFILE_FILE="$profraw" \
               BB_COV_OUT="$RAW_JSON" \
               BB_COV_QUIET=1 \
               TEST_STDIN="${TEST_STDIN:-}"
        if [ -n "${RUN_TIMEOUT:-}" ]; then
            ( cd "$OUT_DIR/run_work" && \
              { [ -n "$TEST_STDIN" ] && printf '%s' "$TEST_STDIN"; } \
              | run_with_timeout "$RUN_TIMEOUT" "$BIN" $testname ) || true
        else
            ( cd "$OUT_DIR/run_work" && \
              { [ -n "$TEST_STDIN" ] && printf '%s' "$TEST_STDIN"; } \
              | "$BIN" $testname ) || true
        fi
        unset LLVM_PROFILE_FILE BB_COV_OUT BB_COV_QUIET TEST_STDIN
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