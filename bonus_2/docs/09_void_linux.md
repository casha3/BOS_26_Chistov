# 9. Void Linux: запуск одной командой

`run_void_linux.sh` — обёртка над фазами 00–09, адаптированная под Void
(xbps + runit). Предполагается, что каталог `bonus_2` уже скопирован на
машину.

## Команды

```bash
./run_void_linux.sh all       # deps → fetch → kernel → qemu → image →
                              # syzkaller → corpus → run (в фоне)
./run_void_linux.sh params    # показать вычисленные параметры, ничего не делать
./run_void_linux.sh status    # pid, счётчики, покрытие, падения, дашборд
./run_void_linux.sh stop      # SIGINT, затем SIGTERM; фиксирует FINISHED_AT
./run_void_linux.sh report    # данные прогона -> results/runs/<id>/
./run_void_linux.sh analyze   # повторный анализ (CSV/JSON/MD)
```

Отдельные фазы: `deps`, `fetch`, `kernel`, `qemu`, `image`, `syzkaller`,
`corpus`, `run`. Уже собранные артефакты пропускаются; пересборка —
`FORCE_KERNEL=1`, `FORCE_QEMU=1`, `FORCE_IMAGE=1`, `FORCE_SYZ=1`,
`FORCE_CORPUS=1`, `FORCE_FETCH=1`.

## Автоподбор параметров

Скрипт считает параметры по CPU/RAM (формулы в `run_void_linux.sh`):

| Ресурсы | JOBS | VMCOUNT | VMCPU | VMMEM | PROCS | GOMEMLIMIT |
|---|---|---|---|---|---|---|
| 62 ГиБ / 24 CPU | 24 | 6 | 4 | 4096 | 4 | 15GiB |
| 16 ГиБ / 8 CPU | 8 | 2 | 4 | 4096 | 4 | 4GiB |
| 8 ГиБ / 8 CPU | 4 | 1 | 4 | 4096 | 4 | 2GiB |

* `JOBS = min(nproc, max(2, RAM_GiB/2), 32)` — ~1 ГиБ на сборочный процесс.
* `VMCOUNT = min(nproc/VMCPU, (RAM_GiB-8)/VMMEM_GiB, 8)`.
* Всё переопределяется переменными: `JOBS=24 VMCOUNT=4 VMMEM=3072 ./run_void_linux.sh run`.

`params` печатает итог и сохраняет его в `work/void.env` (для отчёта).

## Root: что и когда

Запускать нужно **от обычного пользователя**. `sudo` используется только:

* `deps` — `xbps-install -Sy`;
* `image` — `xbps-install -r rootfs`, `ssh-keygen` по rootfs, `mkfs.ext4`.

Фаззинг, сборка ядра/QEMU/syzkaller — без root. Для `run` нужен доступ к
`/dev/kvm`:

```bash
sudo usermod -aG kvm "$USER"   # затем перелогиниться
```

Если KVM нет вообще, `ALLOW_TCG=1 ./run_void_linux.sh run` запустит 1 VM в
TCG (медленно, только проверка).

Скрипт отказывается работать от root (кроме `image`), потому что артефакты в
`work/` должны принадлежать пользователю. Если `image` всё же запускали через
`sudo`, скрипт вернёт владельца `work/` обратно (`chown -R $SUDO_USER`).

## Пакеты Void (ставит `deps`)

```
base-devel gcc make binutils flex bison bc elfutils-devel openssl-devel
zlib-devel ncurses-devel pkgconf glib-devel pixman-devel libslirp-devel
ninja meson python3 python3-distlib python3-packaging go perl cpio rsync
e2fsprogs openssh sudo curl wget xz tar gzip git kmod
```

`python3-distlib` обязателен: Void собирает python3 с `--without-ensurepip`,
а QEMU при configure создаёт venv и ставит meson из вендорных wheel'ов через
`distlib`. Без него configure падает с «found no usable distlib».

`pkgconf` обычно предоставляет `pkg-config`; если ссылки нет, `deps` создаст
`/usr/local/bin/pkg-config`.

## Rootfs гостя на Void

`04_build_image.sh` с `IMAGE_DISTRO=void`:

1. `XBPS_ARCH=x86_64 xbps-install -S -y -r work/image/rootfs -R <repo> base-minimal openssh dhcpcd iproute2 bash kmod`
   (repo — `current` или `current/musl`, определяется по `xbps-uhelper arch`);
2. SSH: `authorized_keys`, `sshd_config.d/99-syzkaller.conf`, host keys через
   `chroot rootfs ssh-keygen -A`;
3. runit-сервис `/etc/sv/netup/run`:
   * монтирует `/proc`, `/sys`, `/dev/pts`, `/run`, `debugfs` (нужен KCOV);
   * выключает IPv6;
   * поднимает интерфейсы, кроме `vendor=0x15b3` (mlx4 без data path);
   * `dhcpcd -q -1 -w -t 10 <iface>`;
   * `exec sleep 86400` (runit держит сервис живым);
4. включает `sshd`, `netup`, `agetty-ttyS0` симлинками в
   `/etc/runit/runsvdir/default`;
5. `mkfs.ext4 -F -d rootfs rootfs.img 3G`.

`base-minimal` — переходный метапакет на `base-container`, который включает
`runit-void` и `xbps`; отдельный `linux` в образ не тянется (грузим своё ядро).

## Проверка после запуска

```bash
./run_void_linux.sh status
# ожидаемо: «работает (pid ...)», счётчики executed/cover растут,
# дашборд http://127.0.0.1:56741 отвечает

ssh -L 56741:127.0.0.1:56741 "$USER"@$(hostname)   # с другой машины
```

## Типичные проблемы Void

| Симптом | Решение |
|---|---|
| `xbps-install: repository not found` | проверить `/etc/xbps.d/00-repository-main.conf`; задать `VOID_REPO=...` |
| QEMU configure: `found no usable distlib` | `sudo xbps-install -y python3-distlib python3-packaging` |
| `pkg-config: command not found` | `sudo xbps-install -y pkgconf`; `deps` создаёт ссылку |
| `run`: нет доступа к `/dev/kvm` | `sudo usermod -aG kvm $USER`, перелогиниться |
| образ собрался, но SSH недоступен | проверить `work/logs/image_xbps.log`, что `/etc/sv/sshd` есть; посмотреть serial-консоль (`-nographic`) |
| `dhcpcd` не получает адрес | в госте `ip link`, `ls /sys/class/net`; mlx4-порты намеренно пропускаются |
