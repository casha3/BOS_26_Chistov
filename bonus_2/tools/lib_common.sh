# shellcheck shell=bash
#
# Общие функции и пути для всех фаз пайплайна bonus_2.
# Подключается через:  . "$(dirname "$0")/tools/lib_common.sh"
#
# Скрипты переносимы: macOS/arm64 (сборка QEMU, syzkaller, syzlang) и
# Rocky Linux/x86_64 (полный цикл, включая ядро и фаззинг).

BONUS2_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=versions.env
. "$BONUS2_ROOT/tools/versions.env"

WORK="${BONUS2_WORK:-$BONUS2_ROOT/work}"

LINUX_SRC="$WORK/linux-$LINUX_VERSION"
QEMU_SRC="$WORK/qemu-$QEMU_VERSION"
SYZ_SRC="$WORK/syzkaller"

QEMU_BUILD="$QEMU_SRC/build"
QEMU_BIN="$QEMU_BUILD/qemu-system-x86_64"
KERNEL_BZIMAGE="$LINUX_SRC/arch/x86/boot/bzImage"
KERNEL_VMLINUX="$LINUX_SRC/vmlinux"

IMAGE_DIR="$WORK/image"
IMAGE="$IMAGE_DIR/rootfs.img"
SSHKEY="$IMAGE_DIR/syzkaller.id_rsa"
ROOTFS_DIR="$IMAGE_DIR/rootfs"

MANAGER_WORKDIR="$WORK/manager"
MANAGER_CFG="$WORK/manager.cfg"
MANAGER_LOG="$WORK/manager.log"

LOGS="$WORK/logs"
RESULTS="$BONUS2_ROOT/results"

HOST_OS=$(uname -s)
HOST_ARCH=$(uname -m)

case "$HOST_OS" in
    Darwin) PLATFORM="macos" ;;
    Linux)  PLATFORM="linux" ;;
    *)      PLATFORM="unknown" ;;
esac

if [ "$HOST_OS" = "Darwin" ]; then
    NCPU=$(sysctl -n hw.ncpu 2>/dev/null || echo 4)
    MEM_GB=$(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1024 / 1024 / 1024 ))
else
    NCPU=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)
    if [ -r /proc/meminfo ]; then
        MEM_GB=$(awk '/MemTotal/{printf "%d", $2/1024/1024}' /proc/meminfo 2>/dev/null || echo 0)
    else
        MEM_GB=0
    fi
fi
[ -n "$MEM_GB" ] || MEM_GB=0

# Идентификатор дистрибутива (void/rocky/debian/...), если доступен.
OS_ID=""
if [ -r /etc/os-release ]; then
    OS_ID=$(. /etc/os-release 2>/dev/null; echo "${ID:-}")
fi

# Параллелизм: ~1 GiB RAM на сборочный процесс (KASAN+debug), но не больше CPU.
#   8 GiB / 8 CPU  -> 4      (macOS, как раньше)
#   62 GiB / 24 CPU -> 24
#   4 GiB / 4 CPU   -> 2
if [ -z "${JOBS:-}" ]; then
    JOBS=$NCPU
    if [ "$MEM_GB" -gt 0 ]; then
        half=$(( MEM_GB / 2 ))
        [ "$half" -lt 2 ] && half=2
        [ "$JOBS" -gt "$half" ] && JOBS=$half
    fi
    [ "$JOBS" -gt 32 ] && JOBS=32
    [ "$JOBS" -lt 2 ] && JOBS=2
fi
export JOBS MEM_GB NCPU OS_ID

# ---------------------------------------------------------------- вывод ---
_phase_now=""

phase() {
    _phase_now="$1"
    printf '\n\033[1;36m==== [%s] %s\033[0m\n' "$1" "$2"
    printf '     платформа: %s/%s, jobs: %s, work: %s\n' \
        "$HOST_OS" "$HOST_ARCH" "$JOBS" "$WORK"
}

log()  { printf '  %s\n' "$*"; }
warn() { printf '\033[1;33m  ВНИМАНИЕ:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m  ОШИБКА:\033[0m %s\n' "$*" >&2; exit 1; }

success() {
    printf '\033[1;32m  ГОТОВО:\033[0m %s\n' "$*"
}

next_step() {
    printf '\n  Следующий шаг: \033[1m%s\033[0m\n' "$*"
}

# --------------------------------------------------------------- проверки ---
have() { command -v "$1" >/dev/null 2>&1; }

need() {
    have "$1" || die "не найдена команда '$1'. Сначала выполните 00_install_deps.sh"
}

need_file() {
    [ -e "$1" ] || die "нет файла '$1'. Сначала выполните: $2"
}

require_linux() {
    [ "$HOST_OS" = "Linux" ] || die "эта фаза выполняется только на Linux ($HOST_OS не подходит).
Запустите её на Rocky Linux (или в Linux-контейнере), остальные фазы работают и на macOS."
}

mkdirs() {
    mkdir -p "$WORK" "$LOGS" "$RESULTS" "$IMAGE_DIR" "$MANAGER_WORKDIR"
}

# Запуск команды с журналом: run_logged <logfile> cmd args...
run_logged() {
    local logfile="$1"
    shift
    mkdir -p "$(dirname "$logfile")"
    log "журнал: $logfile"
    if "$@" >"$logfile" 2>&1; then
        return 0
    else
        local rc=$?
        warn "команда завершилась с кодом $rc, последние строки журнала:"
        tail -n 40 "$logfile" >&2 || true
        return "$rc"
    fi
}

# Неинтерактивный sudo: под root не нужен.
if [ "$(id -u)" = "0" ]; then
    SUDO=""
else
    SUDO="sudo"
fi

kernel_cmdline() {
    # Единая строка для syz-manager: LVC-ядро всё равно добавляет свою.
    printf 'root=/dev/sda console=ttyS0 net.ifnames=0'
}
