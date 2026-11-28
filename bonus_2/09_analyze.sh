#!/usr/bin/env bash
# Фаза 9: пост-анализ уже собранного прогона.
#
# Пересобирает CSV/JSON/Markdown из каталога results/runs/<id>/.
# Полезно, если прогон собран на другой машине (например, на Rocky), а анализ
# хочется сделать локально: достаточно скопировать каталог прогона.
#
# Использование:
#   bash 09_analyze.sh                    # последний прогон (results/latest)
#   bash 09_analyze.sh 20261128-153000    # конкретный run id
#   bash 09_analyze.sh /path/to/run-dir   # произвольный каталог
set -euo pipefail

ROOT=$(cd "$(dirname "$0")" && pwd)
. "$ROOT/tools/lib_common.sh"

phase 9 "Пост-анализ прогона"

need python3

TARGET="${1:-}"
if [ -z "$TARGET" ]; then
    if [ -d "$RESULTS/latest" ]; then
        TARGET=$(cd "$RESULTS/latest" && pwd -P)
    else
        TARGET=$(ls -1d "$RESULTS"/runs/*/ 2>/dev/null | sort | tail -n 1 || true)
        TARGET=${TARGET%/}
    fi
fi

[ -n "$TARGET" ] || die "нет прогонов в results/runs/. Сначала выполните 07 и 08"
if [ ! -d "$TARGET" ] && [ -d "$RESULTS/runs/$TARGET" ]; then
    TARGET="$RESULTS/runs/$TARGET"
fi
[ -d "$TARGET" ] || die "каталог прогона не найден: $TARGET"

KERNEL_SRC_ARG=""
VMLINUX_ARG=""
[ -d "$LINUX_SRC" ] && KERNEL_SRC_ARG="--kernel-src $LINUX_SRC"
[ -f "$KERNEL_VMLINUX" ] && VMLINUX_ARG="--vmlinux $KERNEL_VMLINUX"

log "прогон: $TARGET"
# shellcheck disable=SC2086
python3 "$ROOT/tools/analyze.py" --run-dir "$TARGET" --results-dir "$RESULTS" \
    $KERNEL_SRC_ARG $VMLINUX_ARG

if [ -f "$TARGET/summary.md" ]; then
    cp "$TARGET/summary.md" "$RESULTS/summary.md"
fi

success "готово: $TARGET/summary.md, *.csv, manifest.json"
[ -d "$LINUX_SRC" ] || warn "дерева ядра нет: строки в файлах и символизация стеков пропущены"
