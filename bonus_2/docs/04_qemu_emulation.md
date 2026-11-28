# 4. Эмуляция Mellanox ConnectX-3 в QEMU

## Почему своя модель

В QEMU нет устройства mlx4 (есть e1000, virtio-net, rtl8139, vmxnet3, но не
Mellanox). Без него `mlx4_core` не получит `probe`. Поэтому написана
собственная модель: `qemu/hw/net/mlx4.c` (~1000 строк, QOM, переносимый C).

Модель встраивается в QEMU 11.x двумя строками в `hw/net/meson.build` и
`hw/net/Kconfig` (это делает `03_build_qemu_mlx4.sh`). Сборка идёт для
`x86_64-softmmu`, поэтому host-платформа (macOS/arm64 или Linux/x86_64)
значения не имеет.

## Что эмулируется

PCI-функция `15b3:1003`, class 0200, BAR0 = 1 МиБ (DCS), BAR2 = 8 МиБ (UAR).

| Область BAR0 | Смещение | Назначение |
|---|---|---|
| HCR | `0x80680` | 7 big-endian dword'ов firmware-команды |
| Ownership | `0x8069c` | семафор: первое чтение = 0 (владение), повторное = 1 |
| Reset block | `0xf0000` | семафор `0xf03fc`, регистр сброса `0xf0010` |
| CLR_INT | `0x1000` | подтверждение INTx (запись снимает линию) |
| Catas | `0x6000` | буфер фатальных ошибок (всегда нули) |
| MSI-X table/PBA | `0x4000`/`0x5000` | только при `msix=on` |

HCR: `in_param` (2 dword), `in_modifier`, `out_param` (2 dword), `token`,
`status/go`. Команда запускается записью бита GO; модель выполняет её
синхронно, снимает GO и заполняет status. Если выставлен бит E (event), по
завершении пишется EQE в асинхронный EQ и поднимается прерывание.

## Реализованные команды

| Группа | Команды |
|---|---|
| Инициализация | `QUERY_FW`, `MAP_FA`, `RUN_FW`, `MOD_STAT_CFG`, `QUERY_DEV_CAP`, `QUERY_PORT`, `QUERY_ADAPTER`, `SET_ICM_SIZE`, `MAP_ICM(_AUX)`, `INIT_HCA`, `CLOSE_HCA` |
| EQ | `SW2HW_EQ`, `HW2SW_EQ`, `MAP_EQ` (запоминаем async EQN) |
| Объекты | `SW2HW_MPT/HW2SW_MPT`, `WRITE_MTT`, `SW2HW/HW2SW_CQ`, QP-state команды, `CONF_SPECIAL_QP`, `WRITE_MCG`, `MGID_HASH` |
| Порт | `SET_PORT`, `INIT_PORT`, `CLOSE_PORT`, `SET_MCAST_FLTR`, `SET_VLAN_FLTR` |
| Прочее | `NOP`, `DUMP_ETH_STATS`, `MAD_IFC`, `ACCESS_REG`, `QUERY_*` (возвращают нули) |

Неизвестные команды завершаются успехом и пишутся в лог при `verbose=on` —
это позволяет быстро добавлять недостающее при отладке.

## Тонкости, найденные при проверке на реальном ядре

Модель проверялась на ядре **6.18.60** (Alpine virt, TCG). Найденные и
исправленные моменты (важно, если будете развивать модель):

1. **`max_icm_sz` должен быть ≥ 4 ГиБ.** Профиль драйвера содержит cMPT
   размером `4 << 24` записей × 64 байта = ровно 4 ГиБ. При 512 МиБ
   `mlx4_core` падает с `Profile requires ... won't fit`.
2. **`mtt_entry_sz = 8`.** Драйвер пишет MTT-записи как плотный массив
   `u64`, поэтому шаг между записями — 8 байт, а не 16.
3. **Адрес MTT в контексте EQ относительный.** В EQ-контексте лежит
   `offset * mtt_entry_sz`; база таблицы MTT приходит в `INIT_HCA` (0x100).
   Модель запоминает её и складывает.
4. **`owner` в `struct mlx4_eqe` — последний байт (смещение 31), не первый.**
   При `SW2HW_EQ` firmware должна инициализировать owner-биты кольца:
   для первой половины кольца `0x80` (невалидно при phase=0), иначе драйвер
   «съедает» нулевые записи и уходит в таймаут.
5. **MSI-X.** Модель умеет MSI-X (`msix=on`), но по умолчанию используется
   INTx: драйвер поддерживает legacy-режим, а INTx избавляет от 60-секундной
   проверки `NOP` перед fallback.

## Свойства устройства

```
-device mlx4,ports=2,mac=0x525400dead01,msix=off,evil=off,verbose=off
```

| Свойство | По умолчанию | Смысл |
|---|---|---|
| `ports` | 2 | число портов (1–2) |
| `mac` | `52:54:00:de:ad:01` | MAC первого порта (второй — +1) |
| `msix` | off | включить MSI-X |
| `evil` | off | «злое» устройство: MTU 0xffff, скорость 0x6f, transceiver 0xff, «рваный» MAC |
| `verbose` | off | печать всех HCR-команд, EQE и UAR-записей в stderr QEMU |

## Как проверить вручную (без syzkaller)

```bash
QEMU=work/qemu-11.1.3/build/qemu-system-x86_64
$QEMU -M q35 -cpu max -accel tcg -m 2048 \
      -kernel <bzImage> -append "console=ttyS0 root=/dev/sda" \
      -drive file=work/image/rootfs.img,format=raw,if=ide \
      -device mlx4,ports=2,verbose=on -nographic
```

В госте:

```sh
lspci -nn | grep 15b3          # 15b3:1003
dmesg | grep mlx4              # mlx4_core: Initializing ...
ip link                        # eth1/eth2 (или eth0/eth1)
ethtool -i eth1                # driver: mlx4_en
```

## Отладка

* `verbose=on` + журнал QEMU (`-serial file:`/stderr) показывает каждую
  команду и её статус;
* если драйвер «зависает» на команде — видно opcode и `in_modifier`;
* если EQE не доставляется — видно `cannot translate MTT entry`,
  `MTT entry ... is not present`, `no async EQ`;
* `dmesg` драйвера содержит причину отказа probe (например,
  `QUERY_DEV_CAP command failed`, `Profile requires ...`).

## Приложение: фактическая проверка (6.18.60, Alpine virt)

```
$ lspci -nn | grep 15b3
00:03.0 Ethernet controller [0200]: Mellanox Technologies MT27500 Family
        [ConnectX-3] [15b3:1003]

$ dmesg | grep mlx4
mlx4_core: Mellanox ConnectX core driver v4.0-0
mlx4_core 0000:00:03.0: FW version 2.42.5000 (cmd intf rev 3), max commands 32
mlx4_core 0000:00:03.0: Max ICM size 8192 MB
mlx4_core 0000:00:03.0: Steering mode is: A0 steering ...
mlx4_en: Mellanox ConnectX HCA Ethernet driver v4.0-0
mlx4_en 0000:00:03.0: Activating port:1
mlx4_en: eth1: Link Up
mlx4_en 0000:00:03.0: Activating port:2
mlx4_en: eth2: Link Up

$ ip link
3: eth1: <BROADCAST,MULTICAST> mtu 1500 ... link/ether 52:54:00:de:ad:01
4: eth2: <BROADCAST,MULTICAST> mtu 1500 ... link/ether 52:54:00:de:ad:02

$ ethtool -i eth1
driver: mlx4_en
version: 4.0-0
firmware-version: 2.42.5000
bus-info: 0000:00:03.0

$ ethtool -c eth1     # coalesce: значения из mlx4_en_ethtool_ops
$ ethtool -g eth1     # ringparam: RX/TX 1024, максимум 8192
$ ip link set eth1 up # ndo_open -> mlx4_en_start_port, state UP
```

Это подтверждает пункт 4 ТЗ: устройство эмулируется, драйвер загружается и
создаёт netdev, административные операции доходят до `mlx4_en`.
