#!/usr/bin/env bash
# Фаза 0: установка зависимостей.
#
# macOS (arm64): Homebrew-пакеты для сборки QEMU 11, syzkaller и syzlang.
# Rocky Linux / x86_64: пакеты для сборки ядра, QEMU, syzkaller, образа rootfs.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")" && pwd)
. "$ROOT/tools/lib_common.sh"

phase 0 "Установка зависимостей"

mkdirs

if [ "$HOST_OS" = "Darwin" ]; then
    have brew || die "нужен Homebrew: https://brew.sh"
    pkgs="pkg-config ninja meson go wget xz libslirp glib pixman python3"
    missing=""
    for p in $pkgs; do
        if ! brew list --versions "$p" >/dev/null 2>&1; then
            missing="$missing $p"
        fi
    done
    if [ -n "$missing" ]; then
        log "Homebrew: устанавливаю:$missing"
        # shellcheck disable=SC2086
        brew install $missing || die "brew install завершился с ошибкой"
    else
        log "все Homebrew-пакеты уже установлены"
    fi
    log "ядро и образ rootfs на macOS не собираются — эти фазы выполняются на Linux"
else
    require_linux
    if have dnf; then
        PKGS="gcc gcc-c++ make git wget xz tar bzip2 flex bison bc \
elfutils-libelf-devel openssl-devel ncurses-devel dwarves glib2-devel \
pixman-devel libslirp-devel ninja-build meson golang python3 perl cpio \
rsync e2fsprogs openssh-clients dhcp-client iproute sudo which findutils diffutils"
        log "dnf: устанавливаю пакеты"
        # shellcheck disable=SC2086
        $SUDO dnf -y install $PKGS || die "dnf install завершился с ошибкой"
    elif have apt-get; then
        PKGS="build-essential pkg-config git wget xz-utils flex bison bc \
libelf-dev libssl-dev libncurses-dev dwarves libglib2.0-dev libpixman-1-dev \
libslirp-dev ninja-build meson golang-go python3 perl cpio rsync e2fsprogs \
openssh-client debootstrap dhcpcd-base iproute2 sudo"
        log "apt-get: устанавливаю пакеты"
        # shellcheck disable=SC2086
        $SUDO apt-get update
        # shellcheck disable=SC2086
        $SUDO apt-get install -y $PKGS || die "apt-get install завершился с ошибкой"
    elif have xbps-install; then
        # Void Linux. python3-distlib обязателен: Void собирает python3 с
        # --without-ensurepip, а configure QEMU ставит meson из vendored wheel
        # через distlib.
        PKGS="base-devel gcc make binutils flex bison bc elfutils-devel \
openssl-devel zlib-devel ncurses-devel pkgconf glib-devel pixman-devel \
libslirp-devel ninja meson python3 python3-distlib python3-packaging go perl \
cpio rsync e2fsprogs openssh sudo curl wget xz tar gzip git kmod"
        log "xbps: устанавливаю пакеты"
        # shellcheck disable=SC2086
        $SUDO xbps-install -Sy $PKGS || die "xbps-install завершился с ошибкой"
        # В Void pkgconf обычно предоставляет pkg-config; на всякий случай
        # создаём ссылку, если её нет.
        if ! have pkg-config && have pkgconf; then
            $SUDO ln -sf "$(command -v pkgconf)" /usr/local/bin/pkg-config
            log "создана ссылка /usr/local/bin/pkg-config -> pkgconf"
        fi
    else
        die "поддерживаются dnf (Rocky/RHEL), apt-get (Debian/Ubuntu) и xbps (Void)"
    fi
fi

log "версии инструментов:"
for c in git make gcc cc clang python3 go ninja meson pkg-config; do
    if have "$c"; then
        printf '    %-12s %s\n' "$c" "$("$c" --version 2>/dev/null | head -n 1)"
    fi
done

if [ "$HOST_OS" = "Linux" ]; then
    if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
        log "KVM доступен: /dev/kvm (фаззинг будет быстрым)"
    elif [ -e /dev/kvm ]; then
        warn "есть /dev/kvm, но нет прав: sudo usermod -aG kvm "$USER" и перелогиниться"
    else
        warn "нет /dev/kvm: syz-manager будет работать через TCG (медленно)"
    fi
fi

success "зависимости установлены"
next_step "bash 01_fetch_sources.sh"
