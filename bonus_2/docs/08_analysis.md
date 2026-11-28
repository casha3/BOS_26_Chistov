# 8. Схема данных прогона (для анализа)

Каждый запуск `07_run_manager.sh` получает `run-id` (UTC-время, можно задать
`RUN_ID=...`). `08_collect_report.sh` складывает всё в
`results/runs/<run-id>/` и запускает `tools/analyze.py`. Визуализация не
строится — данные представлены в CSV/JSON/Markdown.

## Файлы и их назначение

| Файл | Формат | Что внутри |
|---|---|---|
| `timeseries.csv` | CSV | минутные срезы всех счётчиков syz-manager |
| `manager_counter.csv` | CSV | `executed/cover/crashes` из консольного журнала (fallback) |
| `coverage_mlx4.csv` | CSV | покрытые кадры: файл, функция, строки, попадания, PC |
| `coverage_by_file.csv` | CSV | агрегат по файлам mlx4 |
| `coverage_functions.csv` | CSV | покрытые функции mlx4 (функция → файл) |
| `crashes.csv` | CSV | падения: заголовок, верхний кадр, `файл:строка`, репро |
| `manifest.json` | JSON | версии, окружение, `qemu_args`, время, хэши файлов |
| `summary.md` | Markdown | человекочитаемая сводка (п.6/п.7 ТЗ) |
| `manager-bench.json` | JSON (поток объектов) | сырые минутные срезы `-bench` |
| `cover.jsonl` | JSONL | сырое покрытие `/cover?jsonl=1` |
| `metrics.txt` | text | снимок `/metrics` (Prometheus) |
| `stats.html` | HTML | снимок `/stats` |
| `qemu.txt` | text | `qemu-system-x86_64 --version` + строка устройства `mlx4` |
| `manager.log` | text | консольный журнал менеджера |
| `manager.cfg`, `kernel.config`, `sources.env`, `run.env` | text | параметры прогона |
| `corpus.db` | binary | корпус на момент сбора |
| `syzlang_dev_mlx4.txt`, `seeds.txt` | text | использованные описания и список seed'ов |
| `crashes/` | каталоги | `description`, `logN`, `reportN`, `repro.prog`/`repro.c` |

## timeseries.csv

Колонки: `minute`, `approx_utc` + все статы, которые были в `-bench`.
Наиболее важные:

| Колонка | Тип | Смысл |
|---|---|---|
| `executed` | накопительно | число исполненных программ |
| `cover` | накопительно | уникальные PC после фильтра `focus_areas` |
| `filtered coverage` | накопительно | счётчик syz-manager `filtered coverage` |
| `corpus` | текущее | размер корпуса |
| `corpus [mlx4]` | текущее | размер корпуса фокус-области |
| `crashes` | накопительно | число падений |
| `crash types` | текущее | число уникальных типов падений |
| `fuzzing`, `uptime` | накопительно | секунды |
| `heap`, `VM` | текущее | память менеджера |

`minute` — номер минутного среза (с 1). `approx_utc` восстановлен как
`STARTED_AT + minute*60` (или по mtime bench-файла, если `run.env` нет);
точность ±минута, счётчик `minute` точный.

Почему так: `-bench` пишет `json.MarshalIndent` раз в минуту и не добавляет
метку времени. Если нужна абсолютная точность — включите внешний сбор
`/metrics` (Prometheus) параллельно с прогоном.

## coverage_mlx4.csv

`file,function,start_line,end_line,hit_count,pc,inline`

* `hit_count` — в скольких программах корпуса встретился этот кадр;
* `pc` — адрес (для `addr2line`/`faddr2line`);
* включены только файлы `drivers/net/ethernet/mellanox/mlx4/`.

## coverage_by_file.csv

`file,frames,unique_lines,functions,file_total_lines,frames_per_kloc`

* `frames` — покрытые кадры (функция+строка), т.е. сколько записей в
  `coverage_mlx4.csv` для файла;
* `unique_lines` — уникальные `start_line`;
* `functions` — уникальные функции;
* `file_total_lines` — всего строк в исходнике (если передан `kernel_src`);
* `frames_per_kloc` — `frames / file_total_lines * 1000` (интенсивность).

Важно: это **не** line coverage. Кадр — это пара «функция + строка входа»;
строки внутри функции не учитываются. Для «процента строк» нужен отдельный
инструмент (llvm-cov/gcov по ядру), здесь его сознательно нет.

## coverage_functions.csv

`function,file` — список функций mlx4, до которых добрался фаззер. Если при
анализе доступен `vmlinux` и `nm`, в `summary.md` добавляется
`functions_total` (все символы `mlx4_*`) и `functions_pct` — приблизительная
доля покрытых функций.

## crashes.csv

`id,title,top_frame,source,repro,kasan,warn,first_seen_utc`

* `id` — имя каталога в `crashes/`;
* `title` — первая строка `description`;
* `top_frame` — первый кадр вида `func+0x.../0x...` из `report0`;
* `source` — `файл:строка` после `scripts/faddr2line` (если есть дерево ядра);
* `repro` — `prog`/`c`/`none`.

## manifest.json

```jsonc
{
  "run_id": "...", "started_at": "...", "finished_at": "...", "duration_sec": "...",
  "host": {"platform": "...", "machine": "...", "cpu_count": 8, "mem_total_kb": ...},
  "versions": {"LINUX_VERSION": "...", "QEMU_VERSION": "...", "SYZKALLER_COMMIT": "..."},
  "env": {"VMMEM": "...", "VMCOUNT": "...", "PROCS": "...", "REPRODUCE": "...", "EVIL": "..."},
  "qemu_args": "-machine q35 ... -device mlx4,ports=2",
  "crashes": 0,
  "files": {"manager.cfg": {"size": ..., "sha256": "..."}, ...}
}
```

## Примеры анализа

```bash
# последний срез счётчиков
tail -n 1 results/latest/timeseries.csv

# рост filtered coverage по минутам (без заголовка)
awk -F, 'NR>1 {print $1, $4}' results/latest/timeseries.csv

# падения и их файлы
column -s, -t < results/latest/crashes.csv | head

# покрытые функции mlx4
cut -d, -f1 results/latest/coverage_functions.csv | head
```

```python
import pandas as pd

ts = pd.read_csv("results/latest/timeseries.csv")
print(ts[["minute", "executed", "filtered coverage", "corpus [mlx4]"]].tail())
print("exec rate, прог/с:",
      (ts["executed"].iloc[-1] - ts["executed"].iloc[0]) / (60 * (len(ts) - 1)))

cov = pd.read_csv("results/latest/coverage_by_file.csv")
print(cov.sort_values("frames", ascending=False).head(10))

cr = pd.read_csv("results/latest/crashes.csv")
print(cr[["title", "source", "repro"]])
```

## Сравнение прогонов

`results/index.md` — таблица всех прогонов (executed, cover, filtered coverage,
crashes). Для детального сравнения соединяйте `timeseries.csv` по `minute`:

```python
import pandas as pd
a = pd.read_csv("results/runs/A/timeseries.csv").set_index("minute")
b = pd.read_csv("results/runs/B/timeseries.csv").set_index("minute")
print(pd.DataFrame({"A filtered": a["filtered coverage"],
                    "B filtered": b["filtered coverage"]}).tail())
```

## Ограничения

1. `filtered coverage` — счётчик PC, а не проценты.
2. Нет общего числа базовых блоков/строк без отдельной инструментации.
3. `approx_utc` — приблизительный (см. выше).
4. `functions_pct` приблизителен: по таблице символов, без учёта инлайнов.
5. Визуализации нет: графики, если нужны, строятся внешними средствами по CSV.
