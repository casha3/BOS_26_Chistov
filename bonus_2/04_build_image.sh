#!/usr/bin/env bash
# Фаза 4: образ rootfs для гостя (Rocky / Debian / Void) + SSH-ключ.
#
# Образ нужен syz-manager: он грузит его в QEMU и заходит по SSH под root.
# Сборка выполняется на Linux; на macOS эта фаза недоступна.
#
# Переменные:
#   IMAGE_SIZE=3G          размер образа
#   IMAGE_DISTRO=auto      auto | rocky | debian | void
#   IMAGE_ROOTFS_TARBALL=  готовый rootfs tar (опционально, вместо установки)
#   VOID_REPO=...          репозиторий Void (по умолчанию current или current/musl)
set -euo pipefail

ROOT=$(cd "$(dirname "$0")" && pwd)
. "$ROOT/tools/lib_common.sh"

phase 4 "Сборка образа rootfs и SSH-ключа"

require_linux
need ssh-keygen
need mkfs.ext4

mkdirs

# --- SSH-ключ ---------------------------------------------------------
if [ ! -f "$SSHKEY" ]; then
    log "генерирую SSH-ключ: $SSHKEY"
    ssh-keygen -t rsa -b 2048 -N "" -C "syzkaller@bonus2" -f "$SSHKEY" >/dev/null
else
    log "SSH-ключ уже есть: $SSHKEY"
fi
chmod 600 "$SSHKEY"
PUBKEY=$(cat "$SSHKEY.pub")

if [ -f "$IMAGE" ] && [ "${FORCE_IMAGE:-0}" != "1" ]; then
    log "образ уже есть: $IMAGE (FORCE_IMAGE=1 — пересобрать)"
    success "образ готов"
    next_step "bash 05_build_syzkaller.sh"
    exit 0
fi

# --- rootfs -----------------------------------------------------------
DISTRO="${IMAGE_DISTRO:-auto}"
if [ "$DISTRO" = "auto" ]; then
    if have dnf; then
        DISTRO="rocky"
    elif have debootstrap; then
        DISTRO="debian"
    elif have xbps-install; then
        DISTRO="void"
    else
        die "нужен dnf (Rocky/RHEL), debootstrap (Debian/Ubuntu) или xbps-install (Void)"
    fi
fi

if [ -n "${IMAGE_ROOTFS_TARBALL:-}" ]; then
    log "распаковываю готовый rootfs: $IMAGE_ROOTFS_TARBALL"
    $SUDO rm -rf "$ROOTFS_DIR"
    $SUDO mkdir -p "$ROOTFS_DIR"
    $SUDO tar -xf "$IMAGE_ROOTFS_TARBALL" -C "$ROOTFS_DIR"
    DISTRO="custom"
else
    $SUDO rm -rf "$ROOTFS_DIR"
    $SUDO mkdir -p "$ROOTFS_DIR/etc"
    $SUDO cp /etc/resolv.conf "$ROOTFS_DIR/etc/resolv.conf" 2>/dev/null || true
fi

case "$DISTRO" in
rocky)
    RELVER=$(. /etc/os-release; echo "${VERSION_ID%%.*}")
    log "dnf --installroot: Rocky/RHEL $RELVER (минимальный набор)"
    $SUDO dnf -y --installroot="$ROOTFS_DIR" --releasever="$RELVER" \
        --nogpgcheck --setopt=install_weak_deps=False --setopt=tsflags=nodocs \
        install basesystem systemd openssh-server openssh-clients iproute \
        dhcp-client procps-ng e2fsprogs util-linux \
        >"$LOGS/image_dnf.log" 2>&1 \
        || { tail -n 40 "$LOGS/image_dnf.log" >&2; die "dnf --installroot (журнал: $LOGS/image_dnf.log)"; }
    ;;
debian)
    REL="${DEBIAN_RELEASE:-bookworm}"
    log "debootstrap: $REL"
    $SUDO debootstrap --variant=minbase \
        --include=openssh-server,openssh-client,iproute2,isc-dhcp-client,procps,init,systemd,systemd-sysv,ca-certificates \
        "$REL" "$ROOTFS_DIR" http://deb.debian.org/debian \
        >"$LOGS/image_debootstrap.log" 2>&1 \
        || { tail -n 40 "$LOGS/image_debootstrap.log" >&2; die "debootstrap (журнал: $LOGS/image_debootstrap.log)"; }
    ;;
void)
    have xbps-install || die "IMAGE_DISTRO=void требует xbps-install (Void Linux)"
    VOID_ARCH=$(xbps-uhelper arch 2>/dev/null || uname -m)
    if [ -n "${VOID_REPO:-}" ]; then
        REPO="$VOID_REPO"
    else
        REPO="https://repo-default.voidlinux.org/current"
        case "$VOID_ARCH" in
            *-musl) REPO="$REPO/musl" ;;
        esac
    fi
    log "xbps --installroot: Void $VOID_ARCH ($REPO)"
    # Сначала база (runit/xbps), затем пакеты, чьи post-install скрипты
    # вызывают vsv и ожидают уже существующий runsvdir.
    XBPS_ARCH="$VOID_ARCH" $SUDO xbps-install -S -y -r "$ROOTFS_DIR" -R "$REPO" \
        base-minimal \
        >"$LOGS/image_xbps.log" 2>&1 \
        || { tail -n 40 "$LOGS/image_xbps.log" >&2; die "xbps-install base-minimal (журнал: $LOGS/image_xbps.log)"; }
    XBPS_ARCH="$VOID_ARCH" $SUDO xbps-install -S -y -r "$ROOTFS_DIR" -R "$REPO" \
        openssh dhcpcd iproute2 bash kmod \
        >>"$LOGS/image_xbps.log" 2>&1 \
        || { tail -n 40 "$LOGS/image_xbps.log" >&2; die "xbps-install гостевых пакетов (журнал: $LOGS/image_xbps.log)"; }
    ;;
custom)
    log "использую готовый rootfs"
    ;;
*)
    die "неизвестный IMAGE_DISTRO=$DISTRO (auto|rocky|debian|void)"
    ;;
esac

# --- общая настройка гостя: SSH, hostname, hosts ----------------------
log "настраиваю sshd и базовые файлы"

$SUDO mkdir -p "$ROOTFS_DIR/root/.ssh"
printf '%s\n' "$PUBKEY" | $SUDO tee "$ROOTFS_DIR/root/.ssh/authorized_keys" >/dev/null
$SUDO chmod 700 "$ROOTFS_DIR/root/.ssh"
$SUDO chmod 600 "$ROOTFS_DIR/root/.ssh/authorized_keys"
$SUDO chown -R 0:0 "$ROOTFS_DIR/root"

$SUDO mkdir -p "$ROOTFS_DIR/etc/ssh/sshd_config.d"
$SUDO tee "$ROOTFS_DIR/etc/ssh/sshd_config.d/99-syzkaller.conf" >/dev/null <<'EOF'
PermitRootLogin yes
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
UsePAM no
X11Forwarding no
PrintMotd no
EOF

# На случай старого sshd без Include — дублируем в основной конфиг.
if ! grep -q "Include /etc/ssh/sshd_config.d" "$ROOTFS_DIR/etc/ssh/sshd_config" 2>/dev/null; then
    $SUDO tee -a "$ROOTFS_DIR/etc/ssh/sshd_config" >/dev/null <<'EOF'

# --- syzkaller ---
PermitRootLogin yes
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
UsePAM no
EOF
fi

printf 'syzkaller\n' | $SUDO tee "$ROOTFS_DIR/etc/hostname" >/dev/null
$SUDO sh -c "printf '127.0.0.1 localhost\\n::1 localhost\\n' > '$ROOTFS_DIR/etc/hosts'"

# debugfs нужен syzkaller для KCOV. systemd монтирует его сам, runit — нет:
# для Void его монтирует сервис netup (ниже).
$SUDO tee "$ROOTFS_DIR/etc/fstab" >/dev/null <<'EOF'
/dev/sda / ext4 defaults,noatime 0 1
debugfs /sys/kernel/debug debugfs defaults 0 0
EOF

# --- сеть и инициализация --------------------------------------------
# Принципиально: DHCP только на интерфейсах, которые НЕ являются mlx4.
# У эмулируемой карты нет data path, DHCP на её порту просто повиснет.

configure_netup_script_dhclient() {
    # Вариант для systemd-гостей (Rocky/Debian): dhclient.
    $SUDO mkdir -p "$ROOTFS_DIR/usr/local/bin"
    $SUDO tee "$ROOTFS_DIR/usr/local/bin/netup.sh" >/dev/null <<'EOF'
#!/bin/sh
# Поднимает все не-mlx4 интерфейсы и получает на них адрес по DHCP.
i=0
while [ $i -lt 60 ]; do
    got=0
    for d in /sys/class/net/*; do
        name=${d##*/}
        [ "$name" = "lo" ] && continue
        vendor=$(cat "$d/device/vendor" 2>/dev/null)
        [ "$vendor" = "0x15b3" ] && continue
        ip link set "$name" up 2>/dev/null
        if command -v dhclient >/dev/null 2>&1; then
            dhclient -1 -timeout 10 "$name" >/dev/null 2>&1 && got=1
        fi
    done
    [ $got -eq 1 ] && exit 0
    i=$((i + 1))
    sleep 1
done
exit 0
EOF
    $SUDO chmod 755 "$ROOTFS_DIR/usr/local/bin/netup.sh"
}

configure_systemd() {
    configure_netup_script_dhclient

    $SUDO mkdir -p "$ROOTFS_DIR/etc/systemd/system"
    $SUDO tee "$ROOTFS_DIR/etc/systemd/system/network-up.service" >/dev/null <<'EOF'
[Unit]
Description=Bring up the syzkaller NIC (DHCP)
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/netup.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    # Отключаем IPv6: иначе автоконфигурация начнёт слать пакеты в mlx4-порт,
    # у которого нет эмулируемого TX, и в dmesg появится NETDEV WATCHDOG.
    $SUDO mkdir -p "$ROOTFS_DIR/etc/sysctl.d"
    $SUDO tee "$ROOTFS_DIR/etc/sysctl.d/99-syzkaller.conf" >/dev/null <<'EOF'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
EOF

    $SUDO sh -c "cat /proc/sys/kernel/random/uuid > '$ROOTFS_DIR/etc/machine-id'"

    # Включаем юниты оффлайн, через симлинки.
    enable_unit() {
        local unit="$1" want="$2" base
        for base in etc/systemd/system usr/lib/systemd/system lib/systemd/system; do
            if [ -f "$ROOTFS_DIR/$base/$unit" ]; then
                $SUDO mkdir -p "$ROOTFS_DIR/etc/systemd/system/$want.wants"
                $SUDO ln -sf "/$base/$unit" "$ROOTFS_DIR/etc/systemd/system/$want.wants/$unit"
                log "включён $unit"
                return 0
            fi
        done
        warn "нет юнита $unit в образе"
        return 1
    }

    if [ -f "$ROOTFS_DIR/usr/lib/systemd/system/sshd.service" ] || \
       [ -f "$ROOTFS_DIR/lib/systemd/system/sshd.service" ]; then
        enable_unit sshd.service multi-user.target || true
    else
        enable_unit ssh.service multi-user.target || true
    fi
    enable_unit network-up.service multi-user.target || true

    # serial-getty@ — шаблонный юнит: линкуем экземпляр ttyS0 вручную.
    for base in usr/lib/systemd/system lib/systemd/system; do
        if [ -f "$ROOTFS_DIR/$base/serial-getty@.service" ]; then
            $SUDO mkdir -p "$ROOTFS_DIR/etc/systemd/system/getty.target.wants"
            $SUDO ln -sf "/$base/serial-getty@.service" \
                "$ROOTFS_DIR/etc/systemd/system/getty.target.wants/serial-getty@ttyS0.service"
            log "включён serial-getty@ttyS0.service"
            break
        fi
    done
}

configure_void() {
    # Void использует runit. Один сервис делает всё: монтирует псевдо-ФС,
    # поднимает сеть (кроме mlx4), получает DHCP и держит процесс живым.
    $SUDO mkdir -p "$ROOTFS_DIR/etc/sv/netup"
    $SUDO tee "$ROOTFS_DIR/etc/sv/netup/run" >/dev/null <<'EOF'
#!/bin/sh
exec 2>&1

# Псевдо-ФС: runit монтирует не всё, а sshd нужен /dev/pts и /run.
mountpoint -q /proc    || mount -t proc proc /proc
mountpoint -q /sys     || mount -t sysfs sysfs /sys
mountpoint -q /dev/pts || mount -t devpts devpts /dev/pts
mountpoint -q /run     || mount -t tmpfs tmpfs /run
mountpoint -q /sys/kernel/debug || mount -t debugfs debugfs /sys/kernel/debug 2>/dev/null || true

sysctl -q -w net.ipv6.conf.all.disable_ipv6=1 2>/dev/null || true
sysctl -q -w net.ipv6.conf.default.disable_ipv6=1 2>/dev/null || true
mkdir -p /run/sshd

i=0
while [ $i -lt 60 ]; do
    got=0
    for d in /sys/class/net/*; do
        name=${d##*/}
        [ "$name" = "lo" ] && continue
        vendor=$(cat "$d/device/vendor" 2>/dev/null)
        [ "$vendor" = "0x15b3" ] && continue
        ip link set "$name" up 2>/dev/null
        dhcpcd -q -1 -w -t 10 "$name" >/dev/null 2>&1 && got=1
    done
    [ $got -eq 1 ] && break
    i=$((i + 1))
    sleep 1
done

# runit перезапускает сервис, если процесс завершился; держим его живым.
exec sleep 86400
EOF
    $SUDO chmod 755 "$ROOTFS_DIR/etc/sv/netup/run"

    # Консоль на ttyS0 — удобно для отладки (необязательно для syzkaller).
    if [ -x "$ROOTFS_DIR/usr/bin/agetty" ] || [ -x "$ROOTFS_DIR/sbin/agetty" ]; then
        $SUDO mkdir -p "$ROOTFS_DIR/etc/sv/agetty-ttyS0"
        $SUDO tee "$ROOTFS_DIR/etc/sv/agetty-ttyS0/run" >/dev/null <<'EOF'
#!/bin/sh
exec agetty -L ttyS0 115200 linux
EOF
        $SUDO chmod 755 "$ROOTFS_DIR/etc/sv/agetty-ttyS0/run"
    fi

    # sshd требует /run/sshd; /run — tmpfs, поэтому создаём каталог в run-скрипте.
    if [ -f "$ROOTFS_DIR/etc/sv/sshd/run" ] && \
       ! grep -q "/run/sshd" "$ROOTFS_DIR/etc/sv/sshd/run"; then
        $SUDO sed -i 's|^exec /usr/bin/sshd|mkdir -p /run/sshd\nexec /usr/bin/sshd|' \
            "$ROOTFS_DIR/etc/sv/sshd/run" 2>/dev/null || true
    fi

    RUNSVDIR="$ROOTFS_DIR/etc/runit/runsvdir/default"
    $SUDO mkdir -p "$RUNSVDIR"
    if [ -d "$ROOTFS_DIR/etc/sv/sshd" ]; then
        $SUDO ln -sfn /etc/sv/sshd "$RUNSVDIR/sshd"
        log "включён sshd (runit)"
    else
        warn "в образе нет /etc/sv/sshd: sshd не будет запущен"
    fi
    $SUDO ln -sfn /etc/sv/netup "$RUNSVDIR/netup"
    log "включён netup (runit)"

    # dhcpcd из пакета мог быть включён автоматически (vsv dhcpcd) и полез бы
    # на mlx4-порты. Сетью управляет только netup.
    for svc in dhcpcd wpa_supplicant; do
        if [ -e "$RUNSVDIR/$svc" ] || [ -L "$RUNSVDIR/$svc" ]; then
            $SUDO rm -f "$RUNSVDIR/$svc"
            log "отключён $svc (runit): сеть настраивает netup"
        fi
    done
    if [ -d "$ROOTFS_DIR/etc/sv/agetty-ttyS0" ]; then
        $SUDO ln -sfn /etc/sv/agetty-ttyS0 "$RUNSVDIR/agetty-ttyS0"
        log "включён agetty-ttyS0 (runit)"
    fi

    # /var/service — стандартная ссылка на активный runsvdir.
    if [ ! -e "$ROOTFS_DIR/var/service" ]; then
        $SUDO mkdir -p "$ROOTFS_DIR/var"
        $SUDO ln -sfn /etc/runit/runsvdir/default "$ROOTFS_DIR/var/service"
    fi
}

case "$DISTRO" in
void)
    configure_void
    ;;
custom)
    if [ -d "$ROOTFS_DIR/etc/runit/runsvdir" ]; then
        configure_void
    else
        configure_systemd
    fi
    ;;
*)
    configure_systemd
    ;;
esac

# host keys генерируем заранее, чтобы не зависеть от первого boot.
if [ "$HOST_ARCH" = "x86_64" ] && [ -x "$ROOTFS_DIR/usr/bin/ssh-keygen" ]; then
    $SUDO chroot "$ROOTFS_DIR" /usr/bin/ssh-keygen -A >/dev/null 2>&1 || \
        warn "не удалось сгенерировать host keys через chroot (sshd сделает это при загрузке)"
fi

# --- упаковка в ext4 --------------------------------------------------
log "создаю ext4-образ: $IMAGE ($IMAGE_SIZE)"
$SUDO rm -f "$IMAGE"
if $SUDO mkfs.ext4 -F -L rootfs -d "$ROOTFS_DIR" "$IMAGE" "$IMAGE_SIZE" \
        >"$LOGS/image_mkfs.log" 2>&1; then
    :
else
    if grep -qi "unknown option\|invalid option" "$LOGS/image_mkfs.log" 2>/dev/null; then
        die "mkfs.ext4 без -d (нужен e2fsprogs >= 1.43): обновите e2fsprogs"
    fi
    tail -n 30 "$LOGS/image_mkfs.log" >&2
    die "mkfs.ext4 (журнал: $LOGS/image_mkfs.log)"
fi

log "образ: $IMAGE ($(du -h "$IMAGE" | cut -f1))"
log "ключ:  $SSHKEY"

success "образ rootfs готов ($DISTRO)"
next_step "bash 05_build_syzkaller.sh"
