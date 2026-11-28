#!/usr/bin/env bash
# Фаза 1: скачивание исходников (ядро Linux, QEMU, syzkaller).
# Работает и на macOS, и на Linux.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")" && pwd)
. "$ROOT/tools/lib_common.sh"

phase 1 "Скачивание исходников"

need curl
need tar
need git
mkdirs

download_tar() {
    local url="$1" dst="$2" dir="$3" name="$4"
    if [ -d "$dir" ]; then
        log "$name уже распакован: $dir"
        return 0
    fi
    if [ ! -f "$dst" ]; then
        log "скачиваю $name: $url"
        curl -fL --retry 3 -o "$dst" "$url" || die "не удалось скачать $url"
    fi
    log "распаковываю $dst"
    tar -xf "$dst" -C "$WORK" || die "не удалось распаковать $dst"
    [ -d "$dir" ] || die "после распаковки нет каталога $dir"
}

LINUX_TAR="$WORK/linux-$LINUX_VERSION.tar.xz"
QEMU_TAR="$WORK/qemu-$QEMU_VERSION.tar.xz"

LINUX_URL="https://cdn.kernel.org/pub/linux/kernel/v${LINUX_VERSION%%.*}.x/linux-$LINUX_VERSION.tar.xz"
QEMU_URL="https://download.qemu.org/qemu-$QEMU_VERSION.tar.xz"

download_tar "$LINUX_URL" "$LINUX_TAR" "$LINUX_SRC" "Linux $LINUX_VERSION"
download_tar "$QEMU_URL"  "$QEMU_TAR"  "$QEMU_SRC"  "QEMU $QEMU_VERSION"

if [ ! -d "$SYZ_SRC/syz-manager" ]; then
    log "клонирую syzkaller ($SYZKALLER_REF)"
    git clone --depth 1 --branch "$SYZKALLER_REF" \
        https://github.com/google/syzkaller.git "$SYZ_SRC" \
        || die "не удалось склонировать syzkaller"
else
    log "syzkaller уже склонирован: $SYZ_SRC"
fi

SYZ_COMMIT=$(git -C "$SYZ_SRC" rev-parse --short HEAD 2>/dev/null || echo unknown)
log "Linux : $LINUX_VERSION ($LINUX_SRC)"
log "QEMU  : $QEMU_VERSION ($QEMU_SRC)"
log "syz   : $SYZ_COMMIT ($SYZ_SRC)"

{
    echo "LINUX_VERSION=$LINUX_VERSION"
    echo "QEMU_VERSION=$QEMU_VERSION"
    echo "SYZKALLER_COMMIT=$SYZ_COMMIT"
    echo "FETCHED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "HOST=$HOST_OS/$HOST_ARCH"
} > "$WORK/sources.env"

success "исходники готовы (закреплено в work/sources.env)"
next_step "bash 02_build_kernel.sh   (только Linux; на macOS — соберите QEMU: bash 03_build_qemu_mlx4.sh)"
