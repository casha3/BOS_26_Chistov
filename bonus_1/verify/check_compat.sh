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
if tree_diff_identical "$OUT_DIR/html_orig" "$OUT_DIR/html_plain"; then
    echo "($PROJECT_NAME) PASS: html_orig =~ html_plain (идентичны по содержимому)"
else
    COMPAT_RESULT="DIFFERS"
    echo "($PROJECT_NAME) FAIL: html_orig != html_plain, see output/$PROJECT_NAME/compat.diff" >&2
    diff -r "$OUT_DIR/html_orig" "$OUT_DIR/html_plain" \
        > "$OUT_DIR/compat.diff" 2>&1 || true
fi

# --- 3. patched genhtml with --bb-report ---------------------------------
log "($PROJECT_NAME) 3/3 patched genhtml with --bb-report  -> html_bb"
rm -rf "$OUT_DIR/html_bb"
"$GENHTML" "$INFO" --bb-report "$BB_JSON" --branch-coverage \
    -o "$OUT_DIR/html_bb" >/dev/null 2>&1

# --- reports -------------------------------------------------------------
HAS_BB_PLAIN=$(grep -r -l '>Basic Block Coverage</td>' "$OUT_DIR"/html_plain \
               2>/dev/null | wc -l | tr -d ' ' || true)
HAS_BB_BB=$(grep -r -l '>Basic Block Coverage</td>' "$OUT_DIR/html_bb" \
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
DIRS_WITH_BB=$(grep -r -l '>Basic Block Coverage</td>' \
              "$OUT_DIR/html_bb" --include="index.html" \
              2>/dev/null | wc -l | tr -d ' ' || true)

echo "($PROJECT_NAME) file pages with BB metric : $FILES_WITH_BB"
echo "($PROJECT_NAME) directory index with BB   : $DIRS_WITH_BB"

echo "($PROJECT_NAME) COMPAT_RESULT=$COMPAT_RESULT"