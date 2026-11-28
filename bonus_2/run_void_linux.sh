#!/usr/bin/env bash
# Автоматическая сборка, запуск и сопровождение проекта на Void Linux.
#
#   ./run_void_linux.sh all        # deps → fetch → kernel → qemu → image →
#                                  # syzkaller → corpus → run (в фоне)
#   ./run_void_linux.sh deps|fetch|kernel|qemu|image|syzkaller|corpus
#   ./run_void_linux.sh run        # запустить syz-manager (detached)
#   ./run_void_linux.sh status     # состояние, счётчики, покрытие, падения
#   ./run_void_linux.sh stop       # корректно остановить менеджер
#   ./run_void_linux.sh report     # 08: данные прогона -> results/runs/<id>/
#   ./run_void_linux.sh analyze    # 09: повторный анализ
#   ./run_void_linux.sh params     # показать вычисленные параметры
#
# Параметры подбираются по CPU/RAM, переопределяются переменными:
#   JOBS VMCPU VMMEM VMCOUNT PROCS GOMEMLIMIT IMAGE_SIZE
#   FORCE_FETCH=1 FORCE_KERNEL=1 FORCE_QEMU=1 FORCE_IMAGE=1
#   FORCE_SYZ=1 FORCE_CORPUS=1 FOREGROUND=1 ALLOW_TCG=1 EVIL=1 MSIX=1
#
# Root: запускать от обычного пользователя. sudo используется только для
# установки пакетов (deps) и сборки rootfs (image).
set -euo pipefail

ROOT=$(cd "$(dirname "$0")" && pwd)
. "$ROOT/tools/lib_common.sh"

CMD="${1:-all}"
[ $# -gt 0 ] && shift || true

usage() {
    cat <<'EOF'
run_void_linux.sh — сборка/запуск/сопровождение bonus_2 на Void Linux

  all        полный цикл: deps → fetch → kernel → qemu → image → syzkaller →
             corpus → run (в фоне)
  deps       установить зависимости (xbps, через sudo)
  fetch      скачать linux/qemu/syzkaller
  kernel     собрать ядро (KASAN+KCOV+mlx4)
  qemu       собрать QEMU с устройством mlx4
  image      собрать rootfs Void + SSH-ключ (через sudo)
  syzkaller  собрать syzkaller и syzlang
  corpus     seeds → corpus.db (проверка описаний)
  run        запустить syz-manager (по умолчанию detached)
  status     pid, последние счётчики, покрытие, падения
  stop       остановить менеджер (SIGINT, затем SIGTERM)
  report     собрать данные прогона в results/runs/<id>/
  analyze    пересобрать CSV/JSON/Markdown
  params     показать вычисленные параметры и не запускать ничего

Параметры: JOBS VMCPU VMMEM VMCOUNT PROCS GOMEMLIMIT IMAGE_SIZE
  FORCE_FETCH=1 FORCE_KERNEL=1 FORCE_QEMU=1 FORCE_IMAGE=1 FORCE_SYZ=1
  FORCE_CORPUS=1 FORCE_DISK=1
  FOREGROUND=1  ALLOW_TCG=1  EVIL=1  MSIX=1  ALLOW_ROOT=1

Примеры:
  ./run_void_linux.sh all
  VMCOUNT=4 VMMEM=3072 ./run_void_linux.sh run
  FORCE_IMAGE=1 ./run_void_linux.sh image
  ./run_void_linux.sh status; ./run_void_linux.sh report
EOF
}

case "$CMD" in
    -h|--help|help) usage; exit 0 ;;
    all|deps|fetch|kernel|qemu|image|syzkaller|corpus|run|status|stop|report|analyze|params) ;;
    *) usage >&2; die "неизвестная команда: $CMD" ;;
esac

# --- root guard -------------------------------------------------------
if [ "$(id -u)" = "0" ] && [ "${ALLOW_ROOT:-0}" != "1" ]; then
    case "$CMD" in
        image) : ;;   # image можно от root; ниже вернём владельца
        *) die "не запускайте '$CMD' от root.
Запустите от обычного пользователя: sudo используется точечно (deps, image).
Если действительно нужно: ALLOW_ROOT=1 $0 $CMD" ;;
    esac
fi

# --- Void preflight ---------------------------------------------------
VOID_OS_RELEASE="${VOID_OS_RELEASE:-/etc/os-release}"
[ -r "$VOID_OS_RELEASE" ] || die "нет $VOID_OS_RELEASE: скрипт для Void Linux"
OS_ID_LOCAL=$(sed -n 's/^ID=//p' "$VOID_OS_RELEASE" | tr -d '"' | head -n 1)
[ "$OS_ID_LOCAL" = "void" ] || die "скрипт для Void Linux (обнаружено ID='${OS_ID_LOCAL:-unknown}')"
ARCH=$(uname -m)
LIBC="glibc"
if ldd --version 2>&1 | head -n 1 | grep -qi musl; then LIBC="musl"; fi

case "$CMD" in
    deps|image|all|run)
        command -v xbps-install >/dev/null 2>&1 || \
            die "нет xbps-install: для '$CMD' нужен Void Linux"
        ;;
esac

# --- параметры --------------------------------------------------------
mem_gb_local() {
    if [ "$HOST_OS" = "Darwin" ]; then
        echo $(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1024 / 1024 / 1024 ))
    else
        awk '/MemTotal/{printf "%d", $2/1024/1024}' /proc/meminfo 2>/dev/null || echo 0
    fi
}

MEM=${MEM_GB:-$(mem_gb_local)}
[ "$MEM" -gt 0 ] || MEM=8
NCPU_LOCAL=${NCPU:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)}

JOBS=${JOBS:-$NCPU_LOCAL}
# ~1 GiB на сборочный процесс (KASAN+debug), не больше половины RAM.
half=$(( MEM / 2 )); [ "$half" -lt 2 ] && half=2
[ "$JOBS" -gt "$half" ] && JOBS=$half
[ "$JOBS" -gt 32 ] && JOBS=32
[ "$JOBS" -lt 2 ] && JOBS=2

VMCPU=${VMCPU:-4}
VMMEM=${VMMEM:-4096}
PROCS=${PROCS:-$VMCPU}

by_cpu=$(( NCPU_LOCAL / VMCPU )); [ "$by_cpu" -lt 1 ] && by_cpu=1
by_mem=$(( (MEM - 8) / (VMMEM / 1024) )); [ "$by_mem" -lt 1 ] && by_mem=1
VMCOUNT=${VMCOUNT:-$by_cpu}
[ "$VMCOUNT" -gt "$by_mem" ] && VMCOUNT=$by_mem
[ "$VMCOUNT" -gt 8 ] && VMCOUNT=8
[ "$VMCOUNT" -lt 1 ] && VMCOUNT=1

gomem=$(( MEM / 4 )); [ "$gomem" -gt 16 ] && gomem=16; [ "$gomem" -lt 2 ] && gomem=2
GOMEMLIMIT="${GOMEMLIMIT:-${gomem}GiB}"
export JOBS GOMEMLIMIT

KVM_OK=0
if [ "$HOST_OS" = "Linux" ] && [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
    KVM_OK=1
fi
KVM_STATE="нет доступа"
[ "$KVM_OK" = "1" ] && KVM_STATE="ok"
if [ -e /dev/kvm ] && [ "$KVM_OK" = "0" ]; then
    KVM_STATE="есть, но нет прав (usermod -aG kvm $USER)"
fi

DISK_FREE_GB=$(df -Pk "$ROOT" 2>/dev/null | awk 'NR==2{printf "%d", $4/1024/1024}')
[ -n "$DISK_FREE_GB" ] || DISK_FREE_GB=0

write_void_env() {
    mkdirs
    {
        echo "OS=void"
        echo "ARCH=$ARCH"
        echo "LIBC=$LIBC"
        echo "MEM_GB=$MEM"
        echo "NCPU=$NCPU_LOCAL"
        echo "JOBS=$JOBS"
        echo "KVM=$KVM_STATE"
        echo "VMCPU=$VMCPU"
        echo "VMMEM=$VMMEM"
        echo "VMCOUNT=$VMCOUNT"
        echo "PROCS=$PROCS"
        echo "GOMEMLIMIT=$GOMEMLIMIT"
        echo "IMAGE_SIZE=${IMAGE_SIZE:-$IMAGE_SIZE}"
        echo "DISK_FREE_GB=$DISK_FREE_GB"
        echo "GENERATED_AT=$(python3 -c 'from datetime import datetime,timezone;print(datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))' 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)"
    } > "$WORK/void.env"
}

show_params() {
    printf '\n  Void Linux: %s/%s (%s)\n' "$ARCH" "$LIBC" "$(uname -r)"
    printf '  RAM: %s GiB, CPU: %s, свободно на диске: %s GiB\n' "$MEM" "$NCPU_LOCAL" "$DISK_FREE_GB"
    printf '  KVM: %s\n' "$KVM_STATE"
    printf '  сборка:  JOBS=%s\n' "$JOBS"
    printf '  фаззинг: VMCOUNT=%s VMCPU=%s VMMEM=%sMiB PROCS=%s GOMEMLIMIT=%s\n' \
        "$VMCOUNT" "$VMCPU" "$VMMEM" "$PROCS" "$GOMEMLIMIT"
    printf '  оценка RAM фаззинга: ~%s GiB (гости %s × %s MiB + QEMU + менеджер)\n' \
        "$(( VMCOUNT * (VMMEM / 1024) + 4 ))" "$VMCOUNT" "$VMMEM"
}

# --- проверки ---------------------------------------------------------
check_disk() {
    if [ "$DISK_FREE_GB" -lt 50 ] && [ "${FORCE_DISK:-0}" != "1" ]; then
        die "мало места: ${DISK_FREE_GB} GiB свободно, нужно ~50 GiB
(ядро ~20-25, QEMU ~5, образ 3-4, корпус). FORCE_DISK=1 — продолжить."
    fi
}

require_sudo_if_needed() {
    if [ "$(id -u)" != "0" ] && ! have sudo; then
        die "нужен sudo для установки пакетов/сборки образа (или запустите image от root)"
    fi
}

raise_fds() {
    local hard want
    hard=$(ulimit -Hn 2>/dev/null || echo 1024)
    want=1048576
    if [ "$hard" != "unlimited" ] && [ "$want" -gt "$hard" ]; then
        want=$hard
    fi
    ulimit -n "$want" 2>/dev/null || warn "не удалось поднять ulimit -n (сейчас $(ulimit -n))"
    log "ulimit -n: $(ulimit -n)"
}

# --- фазы -------------------------------------------------------------
phase_deps() {
    phase "deps" "Установка зависимостей (xbps)"
    require_sudo_if_needed
    bash "$ROOT/00_install_deps.sh"
}

phase_fetch() {
    if [ -f "$LINUX_SRC/Makefile" ] && [ -f "$QEMU_SRC/configure" ] && \
       [ -f "$SYZ_SRC/Makefile" ] && [ "${FORCE_FETCH:-0}" != "1" ]; then
        log "исходники уже скачаны (FORCE_FETCH=1 — обновить)"
        return 0
    fi
    phase "fetch" "Скачивание исходников"
    bash "$ROOT/01_fetch_sources.sh"
}

phase_kernel() {
    if [ -f "$KERNEL_BZIMAGE" ] && [ -f "$KERNEL_VMLINUX" ] && \
       [ "${FORCE_KERNEL:-0}" != "1" ]; then
        log "ядро уже собрано: $KERNEL_BZIMAGE (FORCE_KERNEL=1 — пересобрать)"
        return 0
    fi
    check_disk
    phase "kernel" "Сборка ядра (JOBS=$JOBS)"
    JOBS="$JOBS" bash "$ROOT/02_build_kernel.sh"
}

phase_qemu() {
    if [ -x "$QEMU_BIN" ] && [ -f "$WORK/qemu.path" ] && [ "${FORCE_QEMU:-0}" != "1" ]; then
        log "QEMU уже собран: $QEMU_BIN (FORCE_QEMU=1 — пересобрать)"
        return 0
    fi
    phase "qemu" "Сборка QEMU с устройством mlx4 (JOBS=$JOBS)"
    JOBS="$JOBS" bash "$ROOT/03_build_qemu_mlx4.sh"
}

phase_image() {
    if [ -f "$IMAGE" ] && [ -f "$SSHKEY" ] && [ "${FORCE_IMAGE:-0}" != "1" ]; then
        log "образ уже есть: $IMAGE (FORCE_IMAGE=1 — пересобрать)"
        return 0
    fi
    check_disk
    require_sudo_if_needed
    phase "image" "Сборка образа Void rootfs"
    IMAGE_DISTRO=void IMAGE_SIZE="${IMAGE_SIZE:-$IMAGE_SIZE}" bash "$ROOT/04_build_image.sh"
    if [ "$(id -u)" = "0" ] && [ -n "${SUDO_USER:-}" ]; then
        # Если image запускали через sudo, возвращаем work/ пользователю,
        # иначе следующие фазы не смогут писать в него без root.
        chown -R "$SUDO_USER" "$WORK" 2>/dev/null || true
        log "владелец $WORK возвращён $SUDO_USER"
    fi
}

phase_syzkaller() {
    if [ -x "$SYZ_SRC/bin/syz-manager" ] && \
       [ -x "$SYZ_SRC/bin/linux_amd64/syz-executor" ] && \
       [ -x "$SYZ_SRC/bin/linux_amd64/syz-execprog" ] && \
       [ "${FORCE_SYZ:-0}" != "1" ]; then
        log "syzkaller уже собран (FORCE_SYZ=1 — пересобрать)"
        return 0
    fi
    phase "syzkaller" "Сборка syzkaller (JOBS=$JOBS)"
    JOBS="$JOBS" bash "$ROOT/05_build_syzkaller.sh"
}

phase_corpus() {
    if [ -f "$MANAGER_WORKDIR/corpus.db" ] && [ "${FORCE_CORPUS:-0}" != "1" ]; then
        log "корпус уже есть: $MANAGER_WORKDIR/corpus.db (FORCE_CORPUS=1 — пересобрать)"
        return 0
    fi
    phase "corpus" "Подготовка корпуса"
    bash "$ROOT/06_prepare_corpus.sh"
}

wait_dashboard() {
    have curl || return 0
    local i
    for i in $(seq 1 90); do
        if curl -sf --max-time 2 "http://127.0.0.1:56741/stats" >/dev/null 2>&1; then
            return 0
        fi
        sleep 2
    done
    warn "дашборд не ответил за 180 с — смотрите $MANAGER_LOG"
}

phase_run() {
    phase "run" "Запуск syz-manager"

    # Всё, что нужно для запуска, дособерём автоматически.
    phase_fetch
    phase_kernel
    phase_qemu
    phase_image
    phase_syzkaller
    phase_corpus

    if [ "$KVM_OK" != "1" ]; then
        if [ "${ALLOW_TCG:-0}" = "1" ]; then
            warn "KVM недоступен: TCG, 1 VM (медленно; только для проверки)"
            VMCOUNT=1; VMMEM=2048; PROCS=2
            write_void_env
        else
            die "нет доступа к /dev/kvm.
  sudo usermod -aG kvm \"$USER\"   # затем перелогиниться
или для проверки без KVM: ALLOW_TCG=1 $0 run"
        fi
    fi

    raise_fds
    export VMMEM VMCPU VMCOUNT PROCS
    export EVIL="${EVIL:-0}" MSIX="${MSIX:-0}"

    log "профиль: VMCOUNT=$VMCOUNT VMCPU=$VMCPU VMMEM=$VMMEM PROCS=$PROCS"
    log "GOMEMLIMIT=$GOMEMLIMIT"

    if [ "${FOREGROUND:-0}" = "1" ]; then
        VMMEM="$VMMEM" VMCPU="$VMCPU" VMCOUNT="$VMCOUNT" PROCS="$PROCS" \
            bash "$ROOT/07_run_manager.sh"
        return 0
    fi

    DETACH=1 VMMEM="$VMMEM" VMCPU="$VMCPU" VMCOUNT="$VMCOUNT" PROCS="$PROCS" \
        bash "$ROOT/07_run_manager.sh"
    wait_dashboard
    phase_status
}

phase_stop() {
    local pid
    if [ ! -f "$WORK/manager.pid" ]; then
        log "pid-файл отсутствует: менеджер не запущен этим скриптом"
        return 0
    fi
    pid=$(cat "$WORK/manager.pid")
    if kill -0 "$pid" 2>/dev/null; then
        log "останавливаю syz-manager (pid $pid, SIGINT)"
        kill -INT "$pid" 2>/dev/null || true
        local i
        for i in $(seq 1 60); do
            kill -0 "$pid" 2>/dev/null || break
            sleep 1
        done
        if kill -0 "$pid" 2>/dev/null; then
            warn "не завершился за 60 с, отправляю SIGTERM"
            kill -TERM "$pid" 2>/dev/null || true
            sleep 3
            kill -KILL "$pid" 2>/dev/null || true
        fi
    else
        log "процесс $pid уже не работает"
    fi
    rm -f "$WORK/manager.pid"

    # Фиксируем время окончания прогона для отчёта.
    if [ -f "$WORK/run.env" ]; then
        python3 - "$WORK/run.env" <<'PY' || true
import sys
from datetime import datetime, timezone
path = sys.argv[1]
finished = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
lines, start, seen_f, seen_d = [], None, False, False
for line in open(path, encoding="utf-8"):
    line = line.rstrip("\n")
    if line.startswith("START_EPOCH="):
        try:
            start = int(line.split("=", 1)[1])
        except ValueError:
            start = None
    if line.startswith("FINISHED_AT="):
        line = "FINISHED_AT=" + finished
        seen_f = True
    elif line.startswith("DURATION_SEC="):
        if start:
            line = "DURATION_SEC=%d" % (int(datetime.now(timezone.utc).timestamp()) - start)
        seen_d = True
    lines.append(line)
if not seen_f:
    lines.append("FINISHED_AT=" + finished)
if not seen_d and start:
    lines.append("DURATION_SEC=%d" % (int(datetime.now(timezone.utc).timestamp()) - start))
open(path, "w", encoding="utf-8").write("\n".join(lines) + "\n")
PY
    fi
    success "менеджер остановлен"
}

phase_status() {
    local pid="" state="остановлен" uptime=""
    if [ -f "$WORK/manager.pid" ]; then
        pid=$(cat "$WORK/manager.pid" 2>/dev/null || true)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            state="работает (pid $pid)"
            uptime=$(ps -o etime= -p "$pid" 2>/dev/null | tr -d ' ' || true)
        else
            rm -f "$WORK/manager.pid"
        fi
    fi

    printf '\n  Менеджер: %s' "$state"
    [ -n "$uptime" ] && printf '  uptime: %s' "$uptime"
    printf '\n'

    if [ -f "$WORK/run.env" ]; then
        local run_id started
        run_id=$(sed -n 's/^RUN_ID=//p' "$WORK/run.env" | head -n 1)
        started=$(sed -n 's/^STARTED_AT=//p' "$WORK/run.env" | head -n 1)
        [ -n "$run_id" ] && printf '  run id: %s (старт %s)\n' "$run_id" "$started"
    fi

    if [ -f "$MANAGER_LOG" ]; then
        local last
        last=$(grep -E "executed [0-9]+, cover [0-9]+" "$MANAGER_LOG" | tail -n 1 || true)
        [ -n "$last" ] && printf '  счётчики: %s\n' "$last"
    fi

    if [ -f "$MANAGER_WORKDIR/corpus.db" ]; then
        printf '  корпус: %s (%s)\n' "$MANAGER_WORKDIR/corpus.db" \
            "$(du -h "$MANAGER_WORKDIR/corpus.db" | cut -f1)"
    fi
    local crashes=0
    if [ -d "$MANAGER_WORKDIR/crashes" ]; then
        crashes=$(find "$MANAGER_WORKDIR/crashes" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
    fi
    printf '  падений: %s\n' "$crashes"

    if have curl && curl -sf --max-time 2 "http://127.0.0.1:56741/stats" >/dev/null 2>&1; then
        printf '  дашборд: http://127.0.0.1:56741 (отвечает)\n'
    else
        printf '  дашборд: http://127.0.0.1:56741 (не отвечает)\n'
    fi
    printf '  туннель: ssh -L 56741:127.0.0.1:56741 %s@%s\n' "${USER:-user}" "$(hostname)"
    printf '  журнал:  %s\n' "$MANAGER_LOG"
    if [ -f "$RESULTS/index.md" ]; then
        printf '  прогоны: %s/index.md\n' "$RESULTS"
    fi
}

phase_report() {
    phase "report" "Сбор данных прогона"
    bash "$ROOT/08_collect_report.sh"
}

phase_analyze() {
    phase "analyze" "Пост-анализ"
    bash "$ROOT/09_analyze.sh" "$@"
}

# --- диспетчер --------------------------------------------------------
case "$CMD" in
    status|stop|report|analyze) : ;;   # только чтение/анализ, work не создаём
    *) write_void_env ;;
esac

case "$CMD" in
    params)
        show_params
        log "параметры сохранены в $WORK/void.env"
        ;;
    all)
        show_params
        check_disk
        phase_deps
        phase_fetch
        phase_kernel
        phase_qemu
        phase_image
        phase_syzkaller
        phase_corpus
        phase_run
        ;;
    deps)      phase_deps ;;
    fetch)     phase_fetch ;;
    kernel)    check_disk; phase_kernel ;;
    qemu)      phase_qemu ;;
    image)     phase_image ;;
    syzkaller) phase_syzkaller ;;
    corpus)    phase_corpus ;;
    run)       phase_run ;;
    stop)      phase_stop ;;
    status)    phase_status ;;
    report)    phase_report ;;
    analyze)   phase_analyze "$@" ;;
esac
