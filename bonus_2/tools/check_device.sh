#!/usr/bin/env bash
# Быстрая проверка того, что уже собрано (работает и на macOS, и на Linux).
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tools/lib_common.sh"

phase check "Проверка устройства mlx4 в QEMU"

need_file "$QEMU_BIN" "bash 03_build_qemu_mlx4.sh"
need_file "$ROOT/qemu/hw/net/mlx4.c" "повреждён репозиторий"
mkdir -p "$LOGS"

"$QEMU_BIN" -device help 2>/dev/null | grep '"mlx4"' \
    || die "устройство mlx4 не зарегистрировано"
log "устройство: $("$QEMU_BIN" -device help 2>/dev/null | grep '"mlx4"')"

"$QEMU_BIN" -device mlx4,help 2>&1 | sed -n '1,20p' | while IFS= read -r line; do
    log "$line"
done

# Проверим, что модель можно создать (без гостя, 2 секунды).
log "проверяю создание устройства (-S, без гостя)"
( "$QEMU_BIN" -M q35 -device mlx4,ports=2,verbose=on -display none -S \
    -monitor none -serial none -no-reboot & echo $! > "$WORK/.qemu_pid" ) \
    >"$LOGS/device_check.log" 2>&1 || true
sleep 2
if [ -f "$WORK/.qemu_pid" ]; then
    PID=$(cat "$WORK/.qemu_pid")
    kill "$PID" 2>/dev/null || true
    rm -f "$WORK/.qemu_pid"
fi
grep -q "realized: ports=2" "$LOGS/device_check.log" \
    || { tail -n 20 "$LOGS/device_check.log" >&2; die "модель не создалась"; }
log "модель создаётся: $(grep 'realized:' "$LOGS/device_check.log" | tail -n 1)"

success "QEMU с mlx4 работоспособен"
