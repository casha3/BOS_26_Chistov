# 1. syzkaller: как он устроен и что нам нужно

## Архитектура

```
syz-manager (хост)
 ├─ генерация программ на syzlang, мутации, минимизация, корпус
 ├─ QEMU-пул: запуск/перезагрузка VM, доставка syz-executor по SSH
 └─ приём покрытия (KCOV) и логов падений (serial console)

syz-executor (гость)
 └─ исполняет одну программу (последовательность syscall/ioctl) и
    снимает покрытие через /sys/kernel/debug/kcov
```

Ключевые свойства, важные для задания:

* **Покрытие** собирается ядром (KCOV) и передаётся менеджеру; без `CONFIG_KCOV=y`
  фаззер работает «слепо».
* **Корпус** (`workdir/corpus.db`) — набор программ, давших новое покрытие.
  Начальный корпус можно загрузить самим (`syz-db pack`).
* **focus_areas** — фильтр покрытия: менеджер учитывает только те PC, которые
  попали в указанные файлы/функции. Это ровно то, что требует ТЗ (фокус на
  `drivers/net/ethernet/mellanox/mlx4/`).
* **Дашборд** (`http://127.0.0.1:56741`) показывает статистику, корпус,
  покрытие по файлам/строкам и падения.
* **Репро** — `syz-repro`/`syz-execprog` позволяют повторить падение на той же
  VM-конфигурации (важно: у нас устройство эмулируется, поэтому репро
  детерминировано).

## Что понадобилось от нас

| Требование syzkaller | Как выполнено |
|---|---|
| Ядро с KCOV/KASAN/DEBUG_INFO | `kernel/syzkaller.fragment` + `kernel/lvc.fragment` |
| Машина, которую можно перезагружать | QEMU-инстансы syz-manager |
| rootfs с sshd и debugfs | `04_build_image.sh` |
| Цель, до которой можно добраться syscall'ами | эмулируемая карта mlx4 + netdev |
| Описания цели | `syzlang/dev_mlx4.txt` + штатные ethtool/devlink-описания |
| Начальный корпус | `syzlang/seeds/*.prog` → `corpus.db` |

## Почему без эмуляции карты фаззинг mlx4 невозможен

`mlx4_core` — PCI-драйвер. Без устройства с `15b3:1003` он не получит
`probe`, `mlx4_en` не создаст netdev, а все ioctl'ы (ethtool, MTU, MAC)
будут уходить в `-ENODEV`. Поэтому пункт 4 ТЗ (эмуляция в QEMU) — обязательное
условие для пунктов 5–7.

## Полезные ссылки

* https://github.com/google/syzkaller
* docs/linux/kernel_configs.md, docs/linux/setup.md
* docs/syscall_descriptions.md, docs/syscall_descriptions_syntax.md
* pkg/mgrconfig/config.go (focus_areas, qemu_args)
