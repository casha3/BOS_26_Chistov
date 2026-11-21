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
# On macOS the Xcode clang lives in /usr/bin WITHOUT the LLVM companion
# tools (llvm-profdata/llvm-cov/llvm-addr2line), so a directory is only
# accepted if it contains the WHOLE toolchain.

# have_llvm_dir <dir> : success iff <dir> has the full LLVM toolset
have_llvm_dir() {
    local d="$1"
    [ -x "$d/clang" ] \
        && [ -x "$d/llvm-profdata" ] \
        && [ -x "$d/llvm-cov" ] \
        && [ -x "$d/llvm-addr2line" ]
}

find_llvm_tools() {
    local dirs cdir found=""
    LLVM_BIN=""

    if [ -n "${LLVM_DIR:-}" ] && have_llvm_dir "$LLVM_DIR"; then
        LLVM_BIN="$LLVM_DIR"
    else
        # candidate directories: the dir of `clang` from PATH first,
        # then the well-known locations
        dirs=""
        if command -v clang >/dev/null 2>&1; then
            cdir="$(dirname "$(command -v clang)")"
            dirs="$cdir"
        fi
        for found in /usr/local/bin /opt/homebrew/opt/llvm/bin \
                     /usr/lib/llvm/bin /usr/lib/llvm-19/bin \
                     /usr/lib/llvm-18/bin /usr/lib/llvm-17/bin \
                     /usr/lib/llvm-16/bin /usr/bin; do
            dirs="$dirs $found"
        done
        for cdir in $dirs; do
            if have_llvm_dir "$cdir"; then
                LLVM_BIN="$cdir"
                break
            fi
            LLVM_BIN=""
        done
    fi

    if [ -z "$LLVM_BIN" ]; then
        echo "ERROR: не найден полный набор LLVM (clang, llvm-profdata," >&2
        echo "       llvm-cov, llvm-addr2line)." >&2
        echo "       - macOS: установите Homebrew LLVM и укажите" >&2
        echo "             export LLVM_DIR=/opt/homebrew/opt/llvm/bin" >&2
        echo "         (или установите: brew install llvm)" >&2
        echo "       - Linux/Rocky: dnf install clang llvm или укажите LLVM_DIR" >&2
        exit 1
    fi

    export PATH="$LLVM_BIN:$PATH"
    CLANG="${CLANG:-$LLVM_BIN/clang}"
    LLVM_PROFDATA="${LLVM_PROFDATA:-$LLVM_BIN/llvm-profdata}"
    LLVM_COV="${LLVM_COV:-$LLVM_BIN/llvm-cov}"
    LLVM_ADDR2LINE="${LLVM_ADDR2LINE:-$LLVM_BIN/llvm-addr2line}"
    LLVM_CONFIG="${LLVM_CONFIG:-$LLVM_BIN/llvm-config}"

    for found in "$CLANG" "$LLVM_PROFDATA" "$LLVM_COV" "$LLVM_ADDR2LINE"; do
        if [ ! -x "$found" ]; then
            echo "ERROR: required LLVM tool not found: $found" >&2
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
#             On Linux/ELF this works directly. On macOS the linker
#             ignores -no-pie (PIE always, especially on Apple Silicon),
#             so the runtime records the ASLR slide and bb_cov_finalize.py
#             subtracts it before symbolizing - hence NO -no-pie here.
if [ "$(uname -s)" = "Darwin" ]; then
    INSTR_FLAGS=(-g -O0 \
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

# --- tree_diff_identical <dirA> <dirB> ------------------------------------
# Compare two HTML report trees "by content", being tolerant of:
#   * the "Date" header cell (genhtml stamps the current time per run),
#   * the ROW ORDER in sorted views (Perl hash randomization can reorder
#     rows with equal coverage rates between two runs of genhtml, so even
#     two pristine runs are not byte-identical for multi-file projects),
#   * binary files (PNG).
# Coverage VALUES are still compared: the files' lines are sorted and the
# resulting line multisets are diffed, so any real difference in a value
# or in the set of files changes at least one line.
# Returns 0 if the trees are identical modulo these, 1 otherwise.
tree_diff_identical() {
    local a="$1" b="$2"
    local da db f res=0

    [ -d "$a" ] || return 1
    [ -d "$b" ] || return 1

    da=$( (cd "$a" && find . -type f | sort) )
    db=$( (cd "$b" && find . -type f | sort) )
    [ "$da" = "$db" ] || return 1

    while IFS= read -r f; do
        [ -n "$f" ] || continue
        # Сравниваем только текстовые HTML/CSS (PNG генерируются детерминированно)
        case "$f" in
            *.html|*.css) ;;
            *) continue ;;
        esac
        if ! diff <(grep -v 'headerValue">2' "$a/$f" 2>/dev/null | sort) \
                  <(grep -v 'headerValue">2' "$b/$f" 2>/dev/null | sort) \
                  >/dev/null 2>&1; then
            res=1
        fi
    done <<< "$da"

    return $res
}