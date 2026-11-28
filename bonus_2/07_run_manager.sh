#!/usr/bin/env bash
# Фаза 7: запуск syz-manager с фокусировкой на mlx4.
#
# Дашборд: http://127.0.0.1:56741
#
# Дополнительно к журналу менеджер пишет минутные срезы всех счётчиков
# (флаг -bench). Они нужны фазе 8 для timeseries.csv (executed, cover,
# filtered coverage, corpus [mlx4], crashes и т.д.).
#
# Переменные окружения:
#   VMMEM=2048 VMCPU=2 VMCOUNT=1 PROCS=2     профиль нагрузки
#   REPRODUCE=false                           отключить авторспро (экономно)
#   EVIL=1                                    включить "злое" устройство
#   MSIX=1                                    включить MSI-X (по умолчанию INTx)
#   RUN_ID=<id>                               метка прогона (по умолчанию UTC-время)
#   QEMU_EXTRA_ARGS="..."                     дополнительные аргументы QEMU
set -euo pipefail

ROOT=$(cd "$(dirname "$0")" && pwd)
. "$ROOT/tools/lib_common.sh"

phase 7 "Запуск syz-manager (focus: mlx4)"

need python3

[ "$HOST_OS" = "Linux" ] || warn "на macOS доступен только TCG: прогон будет очень медленным"

VMMEM="${VMMEM:-2048}"
VMCPU="${VMCPU:-2}"
VMCOUNT="${VMCOUNT:-1}"
PROCS="${PROCS:-2}"
REPRODUCE="${REPRODUCE:-true}"

DEVPROPS="ports=2"
[ "${EVIL:-0}" = "1" ] && DEVPROPS="$DEVPROPS,evil=on"
[ "${MSIX:-0}" = "1" ] && DEVPROPS="$DEVPROPS,msix=on"

if [ "$HOST_OS" = "Linux" ] && [ -e /dev/kvm ]; then
    QEMU_ARGS="-machine q35 -cpu host,migratable=off -enable-kvm -device mlx4,$DEVPROPS"
else
    warn "KVM недоступен: QEMU пойдёт через TCG (медленно, только для проверки)"
    QEMU_ARGS="-machine q35 -cpu max -accel tcg,thread=multi -device mlx4,$DEVPROPS"
fi
if [ -n "${QEMU_EXTRA_ARGS:-}" ]; then
    QEMU_ARGS="$QEMU_ARGS $QEMU_EXTRA_ARGS"
fi

mkdirs

RUN_ID="${RUN_ID:-$(python3 -c 'from datetime import datetime,timezone;print(datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S"))')}"
STARTED_AT=$(python3 -c 'from datetime import datetime,timezone;print(datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))')
START_EPOCH=$(date +%s)
BENCH_FILE="$WORK/manager-bench-$RUN_ID.json"
rm -f "$BENCH_FILE"

python3 - "$ROOT/config/manager.cfg.in" "$MANAGER_CFG" <<PY
import sys
src, dst = sys.argv[1], sys.argv[2]
subs = {
    "@WORKDIR@": "$MANAGER_WORKDIR",
    "@KERNEL_OBJ@": "$LINUX_SRC",
    "@KERNEL_SRC@": "$LINUX_SRC",
    "@BZIMAGE@": "$KERNEL_BZIMAGE",
    "@IMAGE@": "$IMAGE",
    "@SSHKEY@": "$SSHKEY",
    "@SYZKALLER@": "$SYZ_SRC",
    "@PROCS@": "$PROCS",
    "@REPRODUCE@": "$REPRODUCE",
    "@VMCOUNT@": "$VMCOUNT",
    "@VMCPU@": "$VMCPU",
    "@VMMEM@": "$VMMEM",
    "@CMDLINE@": "$(kernel_cmdline)",
    "@QEMU_ARGS@": "$QEMU_ARGS",
}
text = open(src).read()
for k, v in subs.items():
    text = text.replace(k, v)
open(dst, "w").write(text)
print(dst)
PY

if [ "${DRY_RUN:-0}" = "1" ]; then
    log "DRY_RUN=1: конфигурация сгенерирована, запуск пропущен"
    sed -n '1,80p' "$MANAGER_CFG"
    exit 0
fi

need_file "$SYZ_SRC/bin/syz-manager" "bash 05_build_syzkaller.sh"
need_file "$IMAGE" "bash 04_build_image.sh"
need_file "$KERNEL_BZIMAGE" "bash 02_build_kernel.sh"
need_file "$SSHKEY" "bash 04_build_image.sh"
chmod 600 "$SSHKEY" 2>/dev/null || true

# Метаданные прогона: их читает фаза 8 и tools/analyze.py.
{
    echo "RUN_ID=$RUN_ID"
    echo "STARTED_AT=$STARTED_AT"
    echo "START_EPOCH=$START_EPOCH"
    echo "BENCH_FILE=$BENCH_FILE"
    echo "MANAGER_CFG=$MANAGER_CFG"
    echo "MANAGER_LOG=$MANAGER_LOG"
    echo "QEMU_ARGS=$QEMU_ARGS"
    echo "VMMEM=$VMMEM"
    echo "VMCPU=$VMCPU"
    echo "VMCOUNT=$VMCOUNT"
    echo "PROCS=$PROCS"
    echo "REPRODUCE=$REPRODUCE"
    echo "EVIL=${EVIL:-0}"
    echo "MSIX=${MSIX:-0}"
    echo "DURATION_SEC="
    echo "FINISHED_AT="
} > "$WORK/run.env"

log "run id:      $RUN_ID"
log "конфигурация: $MANAGER_CFG"
log "workdir:      $MANAGER_WORKDIR"
log "bench:        $BENCH_FILE (минутные срезы счётчиков)"
log "дашборд:      http://127.0.0.1:56741"
log "VM: count=$VMCOUNT cpu=$VMCPU mem=$VMMEM procs=$PROCS reproduce=$REPRODUCE"
log "qemu_args:    $QEMU_ARGS"
log "Ctrl+C — остановить (корпус и падения сохраняются в workdir)"

if [ "${DETACH:-0}" = "1" ]; then
    : > "$MANAGER_LOG"
    # nohup выполняет команду через exec, поэтому $! — это pid самого
    # syz-manager (удобно для stop по pid-файлу).
    nohup "$SYZ_SRC/bin/syz-manager" -config "$MANAGER_CFG" \
        -bench "$BENCH_FILE" >>"$MANAGER_LOG" 2>&1 &
    pid=$!
    echo "$pid" > "$WORK/manager.pid"
    log "syz-manager запущен в фоне: pid $pid"
    log "журнал: $MANAGER_LOG"
    success "менеджер работает (run id: $RUN_ID)"
    next_step "./run_void_linux.sh status   (или bash 08_collect_report.sh после остановки)"
    exit 0
fi

set +e
"$SYZ_SRC/bin/syz-manager" -config "$MANAGER_CFG" -bench "$BENCH_FILE" 2>&1 | tee "$MANAGER_LOG"
rc=${PIPESTATUS[0]}
set -e

FINISHED_AT=$(python3 -c 'from datetime import datetime,timezone;print(datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))')
DURATION=$(( $(date +%s) - START_EPOCH ))

python3 - "$WORK/run.env" "$FINISHED_AT" "$DURATION" <<'PY'
import sys
path, finished, duration = sys.argv[1], sys.argv[2], sys.argv[3]
out = []
for line in open(path, encoding="utf-8"):
    line = line.rstrip("\n")
    if line.startswith("FINISHED_AT="):
        line = "FINISHED_AT=" + finished
    elif line.startswith("DURATION_SEC="):
        line = "DURATION_SEC=" + duration
    out.append(line)
open(path, "w", encoding="utf-8").write("\n".join(out) + "\n")
PY

if [ "$rc" -ne 0 ]; then
    warn "syz-manager завершился с кодом $rc (журнал: $MANAGER_LOG)"
fi

success "прогон завершён (run id: $RUN_ID, длительность: ${DURATION}s)"
next_step "bash 08_collect_report.sh   (данные прогона -> results/runs/$RUN_ID)"
