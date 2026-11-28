# 7. Падения: как найти, воспроизвести и связать с исходниками

## Что считается падением

syz-manager считает падением всё, что попало в его репорт-парсер:
`KASAN`, `KMSAN`, `UBSAN`, `WARNING`, `BUG`, `panic`, `general protection`,
`INFO: task hung`, `lockdep` и т.п. Ядро собрано с `panic_on_warn=1`, поэтому
любой `WARN` останавливает VM и логируется.

Каталог падения: `work/manager/crashes/<hash>/`:

* `description` — заголовок (например, `KASAN: slab-out-of-bounds in ...`);
* `logN` — полный serial-лог;
* `reportN` — разобранный отчёт со стеком;
* `repro.prog` / `repro.c` — репро (если `reproduce: true`).

## Как воспроизвести вручную

```bash
# 1) программой syzkaller (то же ядро/устройство/образ)
work/syzkaller/bin/syz-execprog -config work/manager.cfg \
    work/manager/crashes/<hash>/repro.prog

# 2) или C-репро (если он есть)
gcc -o repro work/manager/crashes/<hash>/repro.c
```

`syz-repro` менеджер запускает сам; вручную:

```bash
work/syzkaller/bin/syz-repro -config work/manager.cfg \
    work/manager/crashes/<hash>
```

Так как устройство эмулируется детерминированно, репро обычно стабильное —
в отличие от реального железа.

## Таблица падений (crashes.csv)

`bash 08_collect_report.sh` строит `results/latest/crashes.csv`:

| Колонка | Смысл |
|---|---|
| `id` | каталог в `crashes/` |
| `title` | первая строка `description` |
| `top_frame` | верхний кадр из `report0` (`func+0x.../0x...`) |
| `source` | `файл:строка` через `scripts/faddr2line` (нужно дерево ядра) |
| `repro` | `prog` / `c` / `none` |
| `kasan`, `warn` | признаки типа отчёта |
| `first_seen_utc` | время появления каталога |

Это удобно для анализа: можно отфильтровать только `source` с
`drivers/net/ethernet/mellanox/mlx4/` и посчитать, сколько уникальных функций
задето.

## Как связать падение с драйвером

1. В `reportN` верхние кадры стека содержат функцию; ищите её в
   `work/linux-<ver>/drivers/net/ethernet/mellanox/mlx4/`.
2. Для точной строки:

   ```bash
   work/linux-<ver>/scripts/faddr2line work/linux-<ver>/vmlinux \
       mlx4_en_xxx+0x1a/0x2f0
   ```

   или `addr2line -e work/linux-<ver>/vmlinux -f -i <pc>`.
3. Страница `cover` дашборда показывает те же функции/строки, что покрыты
   корпусом — удобно сопоставлять с путями исполнения.

## Если падений нет за отведённое время

Это нормально: административная поверхность mlx4 небольшая. Варианты:

* увеличить время прогона (ночь);
* включить `evil=on` — устройство начнёт отдавать некорректные данные
  (MTU 0xffff, скорость 0x6f, transceiver 0xff), что заставляет драйвер
  считать и проверять граничные значения:

  ```bash
  EVIL=1 bash 07_run_manager.sh
  ```

  Это честный сценарий «malicious device»: ядро обязано корректно обработать
  ответы сомнительного устройства;
* расширить syzlang-описания (новые ioctl/атрибуты) и корпус;
* включить fault injection (ядро уже собрано с `CONFIG_FAILSLAB` и др.);
  syzkaller сам использует `/sys/kernel/debug/failslab`, если включено.

В отчёте (`results/summary.md`) фиксируется фактический результат: список
падений либо явная запись «падений не найдено», плюс динамика покрытия.

## Почему падения в mlx4 правдоподобны

Драйвер доверяет ответам firmware: `QUERY_DEV_CAP`, `QUERY_PORT`, содержимому
EEEPROM (`MAD_IFC`), контекстам CQ/QP, которые приходят из ICM. В модели
часть этих ответов управляема (`evil`), а часть путей (ethtool set-операции с
произвольными значениями) достижима и без «злого» режима — поэтому фаззер
имеет реальные шансы найти выход за границы или некорректную обработку.
