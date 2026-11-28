#!/usr/bin/env bash
# Показывает, что уже собрано и чего не хватает.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tools/lib_common.sh"

phase status "Состояние пайплайна"

show() {
    local name="$1" path="$2" hint="$3"
    if [ -e "$path" ]; then
        printf '  [x] %-22s %s\n' "$name" "$path"
    else
        printf '  [ ] %-22s нет (нужно: %s)\n' "$name" "$hint"
    fi
}

show "Linux source" "$LINUX_SRC/Makefile" "bash 01_fetch_sources.sh"
show "QEMU source" "$QEMU_SRC/configure" "bash 01_fetch_sources.sh"
show "syzkaller" "$SYZ_SRC/Makefile" "bash 01_fetch_sources.sh"
show "QEMU binary" "$QEMU_BIN" "bash 03_build_qemu_mlx4.sh"
show "bzImage" "$KERNEL_BZIMAGE" "bash 02_build_kernel.sh (Linux)"
show "vmlinux" "$KERNEL_VMLINUX" "bash 02_build_kernel.sh (Linux)"
show "rootfs image" "$IMAGE" "bash 04_build_image.sh (Linux)"
show "ssh key" "$SSHKEY" "bash 04_build_image.sh (Linux)"
show "corpus.db" "$MANAGER_WORKDIR/corpus.db" "bash 06_prepare_corpus.sh"
show "manager.cfg" "$MANAGER_CFG" "bash 07_run_manager.sh"
show "results index" "$RESULTS/index.md" "bash 08_collect_report.sh"
show "last run" "$RESULTS/latest/summary.md" "bash 08_collect_report.sh"

if [ -d "$WORK" ]; then
    log "занято на диске: $(du -sh "$WORK" 2>/dev/null | cut -f1)"
fi
