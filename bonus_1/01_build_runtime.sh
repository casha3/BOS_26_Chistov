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

if [ ! -f "$RUNTIME_LIB" ] \
   || [ "$SRC_DIR/bb_cov_runtime.c" -nt "$RUNTIME_LIB" ] \
   || [ "$SRC_DIR/bb_cov_runtime.h" -nt "$RUNTIME_LIB" ]; then
    log "Compiling the basic block coverage runtime ($SRC_DIR/bb_cov_runtime.c)"
    "$CLANG" -O2 -c "$SRC_DIR/bb_cov_runtime.c" -o "$BUILD_DIR/bb_cov_runtime.o"
    ar rcs "$RUNTIME_LIB" "$BUILD_DIR/bb_cov_runtime.o"
fi

echo "==> Build artifacts:"
ls -l "$RUNTIME_LIB"
echo "==> Runtime component ready."