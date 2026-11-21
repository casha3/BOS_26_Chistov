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