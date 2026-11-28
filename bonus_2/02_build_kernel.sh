#!/usr/bin/env bash
# Фаза 2: специальная сборка ядра для syzkaller + mlx4.
#
# Применяются три фрагмента конфигурации:
#   kernel/syzkaller.fragment — требования syzkaller (KCOV/KASAN/DEBUG_INFO/...);
#   kernel/lvc.fragment       — рекомендации ИСП РАН (LVCFuzzingKernelOptions);
#   kernel/mlx4.fragment      — драйвер mlx4, e1000/ATA для гостя, devlink.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")" && pwd)
. "$ROOT/tools/lib_common.sh"

phase 2 "Сборка ядра Linux $LINUX_VERSION"

require_linux
need make
need gcc
need flex
need bison
need bc
need_file "$LINUX_SRC/Makefile" "bash 01_fetch_sources.sh"

cd "$LINUX_SRC"

if [ "${CLEAN:-0}" = "1" ]; then
    log "CLEAN=1: make mrproper"
    make -j"$JOBS" mrproper >/dev/null 2>&1 || true
fi

log "make defconfig + kvm_guest.config"
make defconfig >"$LOGS/kernel_defconfig.log" 2>&1 || die "make defconfig"
make kvm_guest.config >>"$LOGS/kernel_defconfig.log" 2>&1 || true

log "сливаю фрагменты конфигурации (merge_config.sh)"
bash "$LINUX_SRC/scripts/kconfig/merge_config.sh" -m \
    "$LINUX_SRC/.config" \
    "$ROOT/kernel/syzkaller.fragment" \
    "$ROOT/kernel/lvc.fragment" \
    "$ROOT/kernel/mlx4.fragment" \
    >"$LOGS/kernel_merge.log" 2>&1 || die "merge_config.sh (см. $LOGS/kernel_merge.log)"

log "make olddefconfig"
make olddefconfig >"$LOGS/kernel_olddefconfig.log" 2>&1 || die "make olddefconfig"

# --- проверка критичных опций ---------------------------------------
check_opt() {
    local sym="$1" want="$2"
    local line
    line=$(grep -E "^${sym}=|^# ${sym} is not set" .config | head -n 1 || true)
    case "$want" in
        y)  grep -q "^${sym}=y" .config || die "в .config нет ${sym}=y (есть: ${line:-ничего})" ;;
        n)  grep -q "^# ${sym} is not set" .config || die "в .config ${sym} не выключен (есть: ${line:-ничего})" ;;
    esac
    log "OK: ${line:-$sym}"
}

log "проверяю ключевые опции ядра"
check_opt CONFIG_KCOV y
check_opt CONFIG_KCOV_INSTRUMENT_ALL y
check_opt CONFIG_KASAN y
check_opt CONFIG_DEBUG_INFO y
check_opt CONFIG_KALLSYMS_ALL y
check_opt CONFIG_DEBUG_INFO_BTF n
check_opt CONFIG_RANDOMIZE_BASE n
check_opt CONFIG_MLX4_CORE y
check_opt CONFIG_MLX4_EN y
check_opt CONFIG_MLX4_INFINIBAND n
check_opt CONFIG_E1000 y
check_opt CONFIG_ATA_PIIX y
check_opt CONFIG_DEVTMPFS_MOUNT y

cp .config "$WORK/kernel.config"

log "make -j$JOBS bzImage (это самый долгий шаг: 40–100 минут)"
if ! run_logged "$LOGS/kernel_build.log" make -j"$JOBS" bzImage; then
    die "сборка ядра не удалась (журнал: $LOGS/kernel_build.log)"
fi

need_file "$KERNEL_BZIMAGE" "make bzImage"
need_file "$KERNEL_VMLINUX" "make bzImage (vmlinux)"

log "bzImage: $KERNEL_BZIMAGE ($(du -h "$KERNEL_BZIMAGE" | cut -f1))"
log "vmlinux: $KERNEL_VMLINUX ($(du -h "$KERNEL_VMLINUX" | cut -f1))"
log "конфиг:  $WORK/kernel.config"

success "ядро собрано"
next_step "bash 03_build_qemu_mlx4.sh"
