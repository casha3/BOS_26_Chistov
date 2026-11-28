#!/usr/bin/env bash
# Фаза 3: сборка QEMU с собственной моделью Mellanox ConnectX-3 (mlx4).
#
# Модель — qemu/hw/net/mlx4.c. Скрипт копирует её в дерево QEMU и добавляет
# строки в hw/net/{meson.build,Kconfig}. Работает и на macOS/arm64, и на
# Rocky Linux/x86_64: QEMU собирает модель для гостя (x86_64-softmmu), поэтому
# код устройства от host-платформы не зависит.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")" && pwd)
. "$ROOT/tools/lib_common.sh"

phase 3 "Сборка QEMU $QEMU_VERSION с устройством mlx4"

need ninja
need meson
need pkg-config
need_file "$QEMU_SRC/configure" "bash 01_fetch_sources.sh"
need_file "$ROOT/qemu/hw/net/mlx4.c" "повреждён репозиторий"

cp "$ROOT/qemu/hw/net/mlx4.c" "$QEMU_SRC/hw/net/mlx4.c"
log "модель скопирована: hw/net/mlx4.c"

if ! grep -q "CONFIG_MLX4_PCI" "$QEMU_SRC/hw/net/meson.build"; then
    printf "\nsystem_ss.add(when: 'CONFIG_MLX4_PCI', if_true: files('mlx4.c'))\n" \
        >> "$QEMU_SRC/hw/net/meson.build"
    log "добавлена строка в hw/net/meson.build"
fi

if ! grep -q "config MLX4_PCI" "$QEMU_SRC/hw/net/Kconfig"; then
    cat >> "$QEMU_SRC/hw/net/Kconfig" <<'EOF'

config MLX4_PCI
    bool
    default y
    depends on PCI
EOF
    log "добавлен пункт MLX4_PCI в hw/net/Kconfig"
fi

# --- конфигурация -----------------------------------------------------
CONFIGURE_ARGS="--prefix=$WORK/qemu-install \
--target-list=x86_64-softmmu \
--disable-docs --disable-tools --disable-guest-agent \
--disable-gtk --disable-sdl --disable-vnc --disable-plugins \
--disable-capstone --disable-werror"

if [ ! -f "$QEMU_BUILD/config-host.mak" ] || [ "${FORCE_CONFIGURE:-0}" = "1" ]; then
    log "configure: $CONFIGURE_ARGS"
    ( cd "$QEMU_SRC" && ./configure $CONFIGURE_ARGS ) >"$LOGS/qemu_configure.log" 2>&1 \
        || { tail -n 30 "$LOGS/qemu_configure.log" >&2; die "configure QEMU (журнал: $LOGS/qemu_configure.log)"; }
else
    log "QEMU уже сконфигурирован (FORCE_CONFIGURE=1 для повторного configure)"
fi

if ! grep -q "define CONFIG_SLIRP" "$QEMU_BUILD/config-host.h" 2>/dev/null; then
    warn "slirp не найден при configure. syzkaller требует -netdev user."
    warn "Rocky: sudo dnf install libslirp-devel; macOS: brew install libslirp"
    warn "затем: FORCE_CONFIGURE=1 bash 03_build_qemu_mlx4.sh"
fi

log "ninja -j$JOBS qemu-system-x86_64"
if ! run_logged "$LOGS/qemu_build.log" ninja -C "$QEMU_BUILD" qemu-system-x86_64 -j"$JOBS"; then
    die "сборка QEMU не удалась (журнал: $LOGS/qemu_build.log)"
fi

need_file "$QEMU_BIN" "ninja qemu-system-x86_64"

if ! "$QEMU_BIN" -device help 2>/dev/null | grep -q '"mlx4"'; then
    die "устройство mlx4 не зарегистрировано в $QEMU_BIN"
fi
log "устройство зарегистрировано: $("$QEMU_BIN" -device help 2>/dev/null | grep '"mlx4"')"

if "$QEMU_BIN" -netdev help 2>/dev/null | grep -q '^user'; then
    log "сетевой backend user (slirp) доступен"
else
    warn "нет -netdev user: syz-manager не сможет поднять VM (нужен libslirp)"
fi

echo "$QEMU_BIN" > "$WORK/qemu.path"
success "QEMU с mlx4 собран: $QEMU_BIN"
next_step "bash 04_build_image.sh   (только Linux)"
