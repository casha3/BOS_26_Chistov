# bonus_2 — фаззинг драйвера `mlx4` через syzkaller с эмуляцией Mellanox ConnectX-3 в QEMU

Проект выполняет все 7 пунктов `tz.md`:

1. syzkaller собран из исходников и используется как есть;
2. разобран драйвер `mlx4` (`mlx4_core` + `mlx4_en`) и выбрана самая свежая
   стабильная версия ядра (**7.3.6**, см. `tools/versions.env`);
3. ядро собирается с рекомендациями ИСП РАН (`kernel/lvc.fragment`) плюс
   `KCOV/KASAN` и опциями под `mlx4` (`kernel/syzkaller.fragment`,
   `kernel/mlx4.fragment`);
4. в QEMU добавлена **собственная модель Mellanox ConnectX-3**
   (`qemu/hw/net/mlx4.c`), потому что апстрим её не эмулирует; драйвер
   загружается, `mlx4_en` создаёт netdev;
5. написаны syzlang-описания (`syzlang/dev_mlx4.txt`) и входной корпус
   (`syzlang/seeds/*.prog` → `corpus.db`);
6. `manager.cfg` запускает syzkaller с `focus_areas` на
   `drivers/net/ethernet/mellanox/mlx4/`; рост `cover` и `corpus [mlx4]`
   виден на дашборде `http://127.0.0.1:56741`;
7. падения собираются в `work/manager/crashes`, воспроизводятся
   `syz-repro`/`syz-execprog`, стек связывается с исходниками драйвера.

> **Проверено фактически.** Модель устройства собрана с QEMU 11.1.3 и
> запущена на реальном ядре Linux 6.18.60 (Alpine virt, x86_64): `mlx4_core`
> проходит probe, `mlx4_en` создаёт `eth1`/`eth2`, работают
> `ethtool -i`, `ethtool -c`, `ethtool -g`, `ip link set ... up`.
> Подробности — `docs/04_qemu_emulation.md`.

---

## 1. Требования

### Два стенда

| Стенд | Что на нём делается |
|---|---|
| **MacBook ARM (macOS)** | `00`, `01`, `03`, `05`, `06`, `make check` — сборка QEMU, syzkaller (host-инструменты), проверка syzlang/корпуса |
| **Rocky Linux x86_64 (VM)** | всё, включая `02` (ядро), `04` (образ), `07` (фаззинг), `08` (отчёт) |

Это ограничение объективное: ядро Linux и `dnf --installroot` нельзя собрать
на macOS. Всё, что относится к «коду проекта» (модель устройства, описания,
корпус, конфиги), собирается и проверяется на обеих платформах.

### Минимальные ресурсы

| Ресурс | Минимум | Комфортно |
|---|---|---|
| RAM | 4 ГБ (с оговорками) | 8–16 ГБ |
| vCPU | 2 | 4–8 |
| Диск | 35 ГБ | 60 ГБ |
| KVM | желателен | обязателен для скорости |
| Права | `sudo` (нужен для `02`/`04`) | root |

Профили RAM и времени — в разделе 7.

---

## 2. Быстрый старт

### 2.1. На Rocky Linux (полный цикл)

```bash
# скопировать каталог bonus_2 на VM, затем:
cd bonus_2

bash 00_install_deps.sh     # пакеты dnf (gcc, meson, libslirp-devel, go, ...)
bash 01_fetch_sources.sh    # скачать linux-7.3.6, qemu-11.1.3, syzkaller
bash 02_build_kernel.sh     # ядро: KASAN + KCOV + рекомендации ИСП РАН + mlx4
bash 03_build_qemu_mlx4.sh  # QEMU с устройством mlx4
bash 04_build_image.sh      # rootfs + SSH-ключ
bash 05_build_syzkaller.sh  # syzkaller + наши syzlang-описания
bash 06_prepare_corpus.sh   # seeds -> corpus.db (проверка описаний)
bash 07_run_manager.sh      # фаззинг, дашборд http://127.0.0.1:56741
bash 08_collect_report.sh   # данные -> results/runs/<id>/ (CSV/JSON/MD)
bash 09_analyze.sh          # опционально: пересобрать анализ
```

Можно и через `make`:

```bash
make deps && make sources && make kernel && make qemu && make image \
  && make syzkaller && make corpus && make run && make report
# позже, при необходимости: make analyze
```

### 2.2. На macOS ARM (сборка и проверка)

```bash
cd bonus_2

bash 00_install_deps.sh     # brew: ninja meson go libslirp glib pixman
bash 01_fetch_sources.sh
bash 03_build_qemu_mlx4.sh  # QEMU x86_64-softmmu с моделью mlx4
bash 05_build_syzkaller.sh  # host-инструменты + генерация описаний
bash 06_prepare_corpus.sh   # проверка syzlang и корпуса (syz-db pack)
make check                  # устройство регистрируется и создаётся
bash tools/status.sh        # что готово
```

Дальше `02`, `04`, `07` выполняются на Rocky. Каталог `work/` можно
скопировать на VM, чтобы не качать исходники заново.

### 2.3. На Void Linux (одной командой)

```bash
cd bonus_2
./run_void_linux.sh all        # deps → fetch → kernel → qemu → image →
                               # syzkaller → corpus → run (в фоне)
./run_void_linux.sh status     # pid, счётчики, покрытие, падения
./run_void_linux.sh stop       # остановить и зафиксировать время
./run_void_linux.sh report     # данные прогона -> results/runs/<id>/
./run_void_linux.sh analyze    # пересобрать CSV/JSON/Markdown
```

* Запускать **от обычного пользователя**: `sudo` нужен только для `deps`
  (`xbps-install`) и `image` (rootfs/mkfs).
* Параметры подбираются по CPU/RAM: для 24 CPU / 62 ГиБ — `JOBS=24`,
  `VMCOUNT=6`, `VMCPU=4`, `VMMEM=4096`, `PROCS=4`, `GOMEMLIMIT=15GiB`.
* Для `run` нужен доступ к `/dev/kvm`: `sudo usermod -aG kvm "$USER"`.
  Без KVM: `ALLOW_TCG=1 ./run_void_linux.sh run`.
* Альтернатива: `make void` (то же, что `./run_void_linux.sh all`).
* Подробности, пакеты и runit-специфика — `docs/09_void_linux.md`.

---

## 3. Фазы подробно

### 00 — зависимости

```bash
bash 00_install_deps.sh
```

* macOS: `brew install pkg-config ninja meson go wget xz libslirp glib pixman`.
* Rocky: `dnf install gcc gcc-c++ make flex bison bc elfutils-libelf-devel
  openssl-devel ncurses-devel dwarves glib2-devel pixman-devel libslirp-devel
  ninja-build meson golang python3 e2fsprogs dhcp-client ...`
* В конце печатает версии и наличие `/dev/kvm`.

### 01 — исходники

```bash
bash 01_fetch_sources.sh
```

* `work/linux-7.3.6` (cdn.kernel.org), `work/qemu-11.1.3`
  (download.qemu.org), `work/syzkaller` (git, shallow).
* Версии и commit syzkaller сохраняются в `work/sources.env`.
* Повторный запуск ничего не перекачивает.

### 02 — ядро (Linux)

```bash
bash 02_build_kernel.sh
```

* `make defconfig` → `make kvm_guest.config` → слияние трёх фрагментов →
  `make olddefconfig` → проверка ключевых символов → `make -j4 bzImage`.
* Результат: `work/linux-7.3.6/arch/x86/boot/bzImage`,
  `work/linux-7.3.6/vmlinux`, `work/kernel.config`.
* Время: 40–100 минут (зависит от vCPU и RAM). Для 4 ГБ:
  `JOBS=2 bash 02_build_kernel.sh`.

### 03 — QEMU с устройством mlx4

```bash
bash 03_build_qemu_mlx4.sh
```

* Копирует `qemu/hw/net/mlx4.c` в дерево QEMU, добавляет
  `CONFIG_MLX4_PCI` в `hw/net/{meson.build,Kconfig}`.
* `configure --target-list=x86_64-softmmu --disable-*` + `ninja`.
* Проверяет, что `-device help` содержит `"mlx4"`, и что собран slirp
  (нужен для `-netdev user` syzkaller).
* Результат: `work/qemu-11.1.3/build/qemu-system-x86_64`.
* Время: 8–25 минут.

### 04 — образ rootfs (Linux)

```bash
bash 04_build_image.sh
```

* Генерирует `work/image/syzkaller.id_rsa` (+ `.pub`).
* Собирает минимальный rootfs через `dnf --installroot` (Rocky) или
  `debootstrap` (Debian/Ubuntu).
* Настраивает: `sshd` (root по ключу), `network-up.service` (DHCP только на
  не-mlx4 интерфейсах), `debugfs` в fstab, отключение IPv6.
* Упаковывает в ext4 через `mkfs.ext4 -d` (без loop/mount).
* Результат: `work/image/rootfs.img` (~3 ГБ).

### 05 — syzkaller

```bash
bash 05_build_syzkaller.sh
```

* Устанавливает `syzlang/dev_mlx4.txt` в `sys/linux/`.
* Linux: `make TARGETOS=linux TARGETARCH=amd64` (manager + executor).
  macOS: `make host` (manager, syz-db, syz-prog2c); executor собирается на
  Rocky.
* Результат: `work/syzkaller/bin/*`.

### 06 — корпус

```bash
bash 06_prepare_corpus.sh
```

* При необходимости генерирует описания (`make descriptions`) и
  пересобирает `syz-db` (иначе у него пустой список target'ов).
* `syz-db -os linux -arch amd64 pack syzlang/seeds work/manager/corpus.db`.
* Это же — проверка syzlang: при ошибке в описании/seed скрипт падает с
  указанием файла.
* Результат: `work/manager/corpus.db`.

### 07 — фаззинг

```bash
bash 07_run_manager.sh
```

* Рендерит `work/manager.cfg` из `config/manager.cfg.in` (абсолютные пути,
  `qemu_args` под вашу ОС, `focus_areas` на mlx4).
* Запускает `syz-manager` с `-bench work/manager-bench-<run-id>.json`
  (минутные срезы всех счётчиков — сырьё для анализа).
* Пишет `work/run.env`: `RUN_ID`, время старта/финиша, `qemu_args`, профиль
  (`VMMEM`, `VMCOUNT`, `PROCS`, `EVIL`, ...). Run id по умолчанию — UTC-время,
  можно задать: `RUN_ID=my-run bash 07_run_manager.sh`.
* Журнал дублируется в `work/manager.log`.
* Дашборд: **http://127.0.0.1:56741**.
* Остановка — `Ctrl+C` (корпус, падения и `run.env` сохраняются).

Типичный старт в журнале:

```
booting test machines...
received first connection from test machine vm-0
executed 120, cover 0, crashes 0
executed 5400, cover 312, crashes 0
...
```

Рост `cover` — это и есть покрытие после фильтра (`filtered_coverage`),
только в терминах syz-manager.

### 08 — сбор данных прогона

```bash
bash 08_collect_report.sh
```

* Создаёт `results/runs/<run-id>/` и складывает туда: `manager.log`,
  `manager.cfg`, `kernel.config`, `sources.env`, `run.env`,
  `manager-bench.json`, `stats.html`, `metrics.txt`, `cover.jsonl`,
  `crashes/`, `corpus.db`, `syzlang_dev_mlx4.txt`, `seeds.txt`.
* Запускает `tools/analyze.py`, который строит:
  `timeseries.csv`, `manager_counter.csv`, `coverage_mlx4.csv`,
  `coverage_by_file.csv`, `coverage_functions.csv`, `crashes.csv`,
  `manifest.json`, `summary.md`.
* Обновляет `results/latest` (симлинк) и `results/index.md` (таблица прогонов),
  копирует сводку в `results/summary.md`.
* Визуализация не строится — только CSV/JSON/Markdown.

### 09 — повторный анализ

```bash
bash 09_analyze.sh                  # последний прогон (results/latest)
bash 09_analyze.sh 20261128-153000  # конкретный run id
```

Пересобирает CSV/JSON/Markdown из уже собранного каталога прогона. Работает и
на macOS: скопируйте `results/runs/<id>/` с Rocky и запустите (символизация и
подсчёт строк требуют дерева ядра — без него поля останутся пустыми).

---

## 4. Дашборд и покрытие (пункт 6 ТЗ)

Откройте `http://127.0.0.1:56741` (с Rocky — через SSH-туннель:
`ssh -L 56741:127.0.0.1:56741 user@rocky`).

| Что смотреть | Ожидание |
|---|---|
| главная, `cover` | растёт от 0 в первые минуты |
| `corpus [mlx4]` | появляются программы про ethtool/ioctl |
| страница `cover` → `drivers/net/ethernet/mellanox/mlx4/` | видны покрытые строки, в т.ч. `mlx4_en_ethtool_ops` |
| `crashes` | либо пусто, либо отчёты с репро |

Почему покрытие вообще появляется: syzkaller исполняет ioctl'ы на
`eth1/eth2`, они попадают в `mlx4_en_*`, KCOV отдаёт PC, фильтр
`focus_areas` оставляет только файлы драйвера.

---

## 5. Данные для анализа

Каждый запуск сохраняется отдельно: `results/runs/<run-id>/` (run id — UTC
время, например `20261128-153000`). `results/latest` — симлинк на последний
прогон, `results/index.md` — таблица всех прогонов, `results/summary.md` —
копия сводки последнего.

```text
results/
├── index.md                     # сравнение прогонов
├── latest -> runs/20261128-153000
└── runs/20261128-153000/
    ├── summary.md               # сводка (п.6/п.7 ТЗ)
    ├── timeseries.csv           # минутные срезы счётчиков
    ├── manager_counter.csv      # executed/cover/crashes из журнала
    ├── coverage_mlx4.csv        # файл, функция, строка, попадания, PC
    ├── coverage_by_file.csv     # по файлам mlx4
    ├── coverage_functions.csv   # покрытые функции
    ├── crashes.csv              # падения + файл:строка + наличие репро
    ├── manifest.json            # версии, окружение, хэши, время
    ├── manager-bench.json       # сырые минутные срезы (-bench)
    ├── cover.jsonl              # сырое покрытие (/cover?jsonl=1)
    ├── metrics.txt              # снимок /metrics (Prometheus)
    ├── stats.html               # снимок /stats
    ├── manager.log, manager.cfg, kernel.config, sources.env, run.env
    ├── corpus.db                # корпус на момент сбора
    ├── syzlang_dev_mlx4.txt, seeds.txt
    └── crashes/                 # description/log/report/repro по каждому
```

### timeseries.csv

Колонки: `minute`, `approx_utc`, затем счётчики syz-manager. Ключевые:

| Колонка | Смысл |
|---|---|
| `executed` | сколько программ исполнено |
| `cover` | уникальные PC после фильтра focus_areas |
| `filtered coverage` | счётчик syz-manager «filtered coverage» (метрика из ТЗ) |
| `corpus`, `corpus [mlx4]` | размер корпуса всего / по фокус-области |
| `crashes`, `crash types` | падения |

Источник — `-bench`: syz-manager раз в минуту пишет JSON со всеми статами,
включая `filtered coverage` (в консольный журнал она не попадает).
`approx_utc` восстановлен как `STARTED_AT + N*60` (или по mtime bench-файла),
счётчик `minute` точный.

### Ограничения (честно)

* `filtered coverage` — накопительный счётчик PC, а не проценты. Локальный
  syz-manager не считает проценты по строкам ядра: в `cover.jsonl` есть только
  покрытые кадры, без общего числа.
* `coverage_by_file.csv`: `file_total_lines` — все строки файла (включая
  комментарии и пустые), `frames` — покрытые кадры (функция+строка). Это
  ориентир, а не «line coverage».
* `functions_pct` (если есть `vmlinux` и `nm`): доля покрытых функций от всех
  символов `mlx4_*` в ядре — приблизительно (инлайн, static и т.п.).
* `crashes.csv` символизирует верхний кадр через `scripts/faddr2line`; для
  этого нужен `kernel_obj` (дерево ядра). Без него колонка `source` пустая.
* Визуализация намеренно не строится — только CSV/JSON/Markdown.

Схема данных и примеры запросов (pandas/awk) — `docs/08_analysis.md`.

---

## 6. Падения и репро (пункт 7 ТЗ)

```bash
# найти падения
ls work/manager/crashes/
cat work/manager/crashes/<hash>/description
sed -n '1,40p' work/manager/crashes/<hash>/report0

# воспроизвести
work/syzkaller/bin/syz-execprog -config work/manager.cfg \
    work/manager/crashes/<hash>/repro.prog

# связать стек с исходником
work/linux-7.3.6/scripts/faddr2line work/linux-7.3.6/vmlinux \
    mlx4_en_some_func+0x1a/0x2f0
```

Сводка по падениям также попадает в `crashes.csv` (id, заголовок, верхний
кадр, `файл:строка`, наличие репро) и в `summary.md`.

Если падений нет — включите «злое» устройство и/или увеличьте время:

```bash
EVIL=1 bash 07_run_manager.sh
```

`evil=on` заставляет модель отдавать некорректные ответы (MTU `0xffff`,
скорость `0x6f`, transceiver `0xff`, «рваный» MAC) — это легитимный сценарий
«недоверенное устройство». Подробнее: `docs/07_crashes.md`.

---

## 7. Память и время

### Профили syz-manager

| RAM хоста | Параметры |
|---|---|
| 4 ГБ | `VMMEM=1024 VMCOUNT=1 PROCS=1 REPRODUCE=false bash 07_run_manager.sh` |
| 8 ГБ | `VMMEM=2048 VMCOUNT=1 PROCS=2` (по умолчанию) |
| 16 ГБ | `VMMEM=2048 VMCOUNT=2 PROCS=4` |
| 32 ГБ | `VMMEM=3072 VMCOUNT=4 PROCS=4` |
| 62 ГБ / 24 CPU | `JOBS=24 VMCOUNT=6 VMMEM=4096 PROCS=4` (так считает `run_void_linux.sh`) |

Формула `JOBS` в `tools/lib_common.sh`:
`min(nproc, max(2, RAM_GiB/2), 32)` — примерно 1 ГиБ на сборочный процесс
(KASAN + debug info). На 8 ГиБ это по-прежнему `-j4`, на 62 ГиБ — `-j24`.

Пик памяти:

* сборка ядра `-j2` — 2.5–3.5 ГБ; `-j4` — 4–6 ГБ;
* сборка QEMU — 1.5–2.5 ГБ;
* прогон (1 VM, mem=2048) — 3.2–3.8 ГБ (гость + QEMU + manager).

Чтобы уменьшить память менеджера: `GOMEMLIMIT=1200MiB bash 07_run_manager.sh`.

### Время (Rocky, 4–8 vCPU)

| Шаг | Время |
|---|---|
| 01 исходники | 10–25 мин |
| 02 ядро | 40–100 мин |
| 03 QEMU | 8–25 мин |
| 04 образ | 8–20 мин |
| 05 syzkaller | 3–8 мин |
| 06 корпус | секунды |
| 07 первый рост покрытия | 20–60 мин |
| 07 плато / падения | 4–12 ч (ночной прогон) |

macOS: 01+03+05+06 ≈ 20–40 минут (без ядра).

---

## 8. Troubleshooting

| Симптом | Причина / решение |
|---|---|
| `configure: slirp support : NO` | нет libslirp. Rocky: `sudo dnf install libslirp-devel`; macOS: `brew install libslirp`; затем `FORCE_CONFIGURE=1 bash 03_build_qemu_mlx4.sh` |
| `syz-manager: unknown target` | не сгенерированы описания/`syz-db` собран до генерации. Повторите `bash 06_prepare_corpus.sh` |
| `invalid descriptions_mode` | в `manager.cfg` попал неверный ключ; перегенерируйте конфиг: `bash 07_run_manager.sh` |
| VM не поднимается, SSH timeout | проверьте, что `-netdev user` доступен (slirp), что образ собран, что ключ `chmod 600`; запустите QEMU вручную (см. ниже) |
| `mlx4_core: probe ... failed` | смотрите `dmesg`: чаще всего модель невернула команду. Пересоберите QEMU с `verbose=on` и посмотрите последнюю HCR-команду |
| нет `eth1/eth2` | драйвер не загрузился; проверьте `dmesg | grep mlx4` и `lspci -nn | grep 15b3` |
| `NOP command failed to generate MSI-X interrupt` | это ожидаемо только при `MSIX=1`; по умолчанию INTx, сообщения быть не должно |
| `NETDEV WATCHDOG ... TX timeout` | интерфейс поднят, но data path не эмулируется. В образе отключён IPv6; для фаззинга не критично |
| `mkfs.ext4: invalid option -- d` | старый e2fsprogs; обновите (`dnf install e2fsprogs`) |
| не хватает RAM на ядро | `JOBS=2`, swap/zram; см. профили |
| Void: `found no usable distlib` | `sudo xbps-install -y python3-distlib python3-packaging` |
| Void: `xbps-install: repository not found` | проверить `/etc/xbps.d/00-repository-main.conf` или задать `VOID_REPO=...` |
| Void: нет доступа к `/dev/kvm` | `sudo usermod -aG kvm "$USER"` и перелогиниться; или `ALLOW_TCG=1` |
| `run_void_linux.sh`: «не запускайте от root» | запускать от пользователя; `image` можно, остальное — нет |

Ручной запуск QEMU для отладки:

```bash
Q=work/qemu-11.1.3/build/qemu-system-x86_64
$Q -M q35 -cpu max -accel tcg -m 2048 \
   -kernel work/linux-7.3.6/arch/x86/boot/bzImage \
   -append "root=/dev/sda console=ttyS0 net.ifnames=0" \
   -drive file=work/image/rootfs.img,format=raw,if=ide \
   -netdev user,id=n0 -device e1000,netdev=n0 \
   -device mlx4,ports=2,verbose=on -nographic
```

В госте: `lspci -nn | grep 15b3`, `dmesg | grep mlx4`, `ip link`,
`ethtool -i eth1`.

---

## 9. Структура каталога

```
bonus_2/
├── README.md                  # этот файл
├── Makefile                   # make deps|sources|kernel|...|check|status
├── 00_install_deps.sh         # зависимости (brew/dnf/apt)
├── 01_fetch_sources.sh        # linux, qemu, syzkaller
├── 02_build_kernel.sh         # ядро (Linux)
├── 03_build_qemu_mlx4.sh      # QEMU + модель mlx4
├── 04_build_image.sh          # rootfs + SSH-ключ (Linux)
├── 05_build_syzkaller.sh      # syzkaller + syzlang
├── 06_prepare_corpus.sh       # corpus.db + проверка описаний
├── 07_run_manager.sh          # фаззинг + дашборд
├── 08_collect_report.sh       # данные -> results/runs/<id>/ (CSV/JSON/MD)
├── 09_analyze.sh              # повторный анализ готового прогона
├── run_void_linux.sh          # все фазы одной командой на Void Linux
├── qemu/hw/net/mlx4.c         # модель Mellanox ConnectX-3 (QOM)
├── kernel/                    # фрагменты .config (syzkaller/lvc/mlx4)
├── syzlang/dev_mlx4.txt       # описания ioctl для mlx4
├── syzlang/seeds/*.prog       # входной корпус
├── config/manager.cfg.in      # шаблон конфигурации syz-manager
├── tools/                     # lib_common.sh, analyze.py, check_device.sh, status.sh
├── docs/01..09_*.md           # ответы по пунктам ТЗ, схема данных, Void
├── work/                      # исходники, сборки, корпус, падения (gitignore)
└── results/                   # runs/<id>/*.csv, manifest.json, index.md (gitignore)
```

---

## 10. Соответствие ТЗ

| Пункт ТЗ | Где реализовано | Чем подтверждается |
|---|---|---|
| 1. Исследовать syzkaller | `docs/01_syzkaller.md` | архитектура, конфиги, запуск |
| 2. Изучить mlx4, версии ядра | `docs/02_mlx4.md` | PCI ID, модули, выбор 7.3.6 |
| 3. Спец. сборка ядра (ИСП РАН + mlx4) | `02_build_kernel.sh`, `run_void_linux.sh`, `kernel/*.fragment` | проверка символов, `work/kernel.config` |
| 4. Эмуляция QEMU, драйвер загружается | `qemu/hw/net/mlx4.c`, `03_build_qemu_mlx4.sh` | `lspci`, `dmesg`, `eth1/eth2`, `ethtool -i` (проверено на 6.18.60) |
| 5. syzlang + входной корпус | `syzlang/`, `06_prepare_corpus.sh` | `syz-db pack` (валидация), `corpus.db` |
| 6. focus_areas + рост filtered_coverage | `config/manager.cfg.in`, `07_run_manager.sh` | дашборд + `timeseries.csv` (`filtered coverage`, `corpus [mlx4]`) |
| 7. Падения, репро, связь с исходниками | `08_collect_report.sh`, `docs/07_crashes.md` | `crashes/`, `crashes.csv` (файл:строка), `syz-repro`, `faddr2line` |

---

## 11. Как менять параметры

* Версии Linux/QEMU/syzkaller — `tools/versions.env`.
* Набор опций ядра — `kernel/*.fragment`.
* Фокус фаззинга — `config/manager.cfg.in` (`focus_areas`).
* Память/параллелизм — переменные `VMMEM`, `VMCOUNT`, `PROCS`, `REPRODUCE`,
  `JOBS`, `GOMEMLIMIT`.
* Модель устройства — `qemu/hw/net/mlx4.c`; свойства:
  `ports`, `mac`, `msix`, `evil`, `verbose`.
* Другие имена интерфейсов — `mlx4_devnames` в `syzlang/dev_mlx4.txt`.

После правки модели пересоберите только QEMU (2–5 минут):

```bash
bash 03_build_qemu_mlx4.sh
```
