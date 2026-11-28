# 6. focus_areas и работа с покрытием

## Конфигурация

`config/manager.cfg.in` (рендерится в `work/manager.cfg` скриптом 07):

```jsonc
"experimental": {
  "cover_edges": false,
  "focus_areas": [
    { "name": "mlx4",
      "filter": { "files": ["^drivers/net/ethernet/mellanox/mlx4/"] },
      "weight": 1.0 }
  ]
}
```

Что это даёт:

* менеджер учитывает **только** покрытие файлов `drivers/net/ethernet/mellanox/mlx4/`;
* программы, не задевшие драйвер, не пополняют корпус (корпус компактный,
  RAM экономится);
* на дашборде появляется отдельная статистика `corpus [mlx4]`, а страница
  `cover` показывает покрытие по файлам/строкам только целевой подсистемы.

`cover_edges: false` — сигнал по базовым блокам (PC), а не по рёбрам; так
«filtered coverage» ближе к метрике базовых блоков, которую требует ТЗ
(и меньше памяти).

## Что смотреть на дашборде

`http://127.0.0.1:56741`

| Страница | Что показывает |
|---|---|
| главная | `executed`, `cover` (уникальные PC после фильтра), `corpus`, `crashes` |
| `cover` | дерево файлов; раскрыть `drivers/net/ethernet/mellanox/mlx4/` и посмотреть покрытые строки |
| `corpus` | программы, давшие новое покрытие (видно, что это ethtool/ioctl-программы) |
| `crashes` | падения с логами и репро |

Рост `cover`/`corpus [mlx4]` — прямое подтверждение пункта 6 ТЗ. Если
`cover` стоит на нуле, смотрите раздел «Troubleshooting» в README: обычно это
значит, что драйвер не загрузился (нет netdev) или KCOV не включён.

## Снятие данных и метрика filtered coverage

```bash
bash 08_collect_report.sh   # данные прогона -> results/runs/<run-id>/
bash 09_analyze.sh          # пересобрать анализ (опционально)
```

Что важно знать про метрику:

* syz-manager считает `filtered coverage` — накопительное число PC, попавших
  в `focus_areas`. В консольный журнал она **не** пишется, но есть в
  минутных срезах `-bench` и на странице `/stats`.
* После фазы 8 она попадает в `results/runs/<id>/timeseries.csv` (колонка
  `filtered coverage`) и в `summary.md`.
* `cover` в журнале — это уникальные PC после фильтра; `filtered coverage` —
  счётчик новых PC за прогон. Они близки, но не идентичны.
* Корпус фокус-области — колонка `corpus [mlx4]` в `timeseries.csv`.

Пример сводки:

```
- executed: **152340**
- cover (PC после фильтра): **1841**
- filtered coverage: **1815**
- corpus: 220
- corpus [mlx4]: 190
- прирост за прогон: executed +150000, cover +1200
```

Полная схема данных — `docs/08_analysis.md`.

## Настройка под железо

| RAM хоста | VMMEM | VMCOUNT | PROCS | REPRODUCE |
|---|---|---|---|---|
| 4 ГБ | 1024 | 1 | 1 | false |
| 8 ГБ | 2048 | 1 | 2 | true |
| 16 ГБ | 2048 | 2 | 4 | true |
| 32 ГБ | 3072 | 4 | 4 | true |

Задаётся переменными окружения перед `bash 07_run_manager.sh`, например:

```bash
VMMEM=2048 VMCOUNT=1 PROCS=2 REPRODUCE=false bash 07_run_manager.sh
```

## Фокус и «широкий» режим

Если нужно убедиться, что фаззер вообще работает, можно временно добавить
вторую focus area с пустым фильтром (`{"weight": 1.0}`) — тогда покрытие
всего ядра тоже учитывается. Для сдачи ТЗ нужен именно узкий фокус на mlx4.
