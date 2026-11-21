# Команды, использованные при работе с модифицированным genhtml

Документ фиксирует реальные команды, которыми запускался **genhtml**
(пакет LCOV 1.16 + `patch/genhtml.patch`, опция `--bb-report`) в рамках
бонусного задания №1.

> Быстрый путь: `bash run_project.sh /path/to/project` сделает
> всю цепочку автоматически (инструментирование, `coverage.info`,
> `bb_cov.json`, отчёты `html_orig`/`html_plain`/`html_bb`, `diff -r` и
> лог команд в `output/<name>/report.md`). Ниже — те же команды руками.

Тестовый прогон выполнялся на проекте `bonus_1/projects/lab2` —
C-модели bash-скриптов лабораторной работы №2
(`filter_numbers.sh`, `smart_calc.sh`, `geometry.sh`).

> Полный «живой» журнал с выводом каждой команды сохранён также в
> `output/lab2/transcript.log`, сводка — в `output/lab2/report.md`.

---

## 1. Сборка инструментов (runtime + патченный genhtml)

```bash
# (все команды выполняются из каталога bonus_1)

bash 01_build_runtime.sh
# результат: build/libbbcov.a (runtime-компонент базовых блоков из src/bb_cov_runtime.c)

bash 02_build_genhtml.sh
# результат:
#   vendor/lcov-1.16/bin/genhtml      - исходник LCOV 1.16 + наш патч
#   vendor/genhtml                    - патченный genhtml (обёртка)
#   vendor/genhtml_orig               - оригинальный genhtml (обёртка, для совместимости)
```

Проверка, что у патченного genhtml появилась опция:

```bash
vendor/genhtml --version
# genhtml: LCOV version 1.16

vendor/genhtml --help | grep -A2 "bb-report"
#       --bb-report FILENAME          Add basic block coverage data from
#                                     FILENAME to the report
```

---

## 2. Подготовка данных о покрытии (для проекта lab2)

Выполняется скриптом `tools/build_project.sh` (команды внутри него):

```bash
# 2.1 компиляция одной инструментированной сборки
#     (стандартное покрытие + базовые блоки в одной бинарке):
#     на Linux/Rocky (ELF):
clang -g -O0 -no-pie \
      -fprofile-instr-generate \
      -fcoverage-mapping \
      -fsanitize-coverage=bb,no-prune,inline-bool-flag,pc-table \
      -I. lab2.c harness_main.c build/libbbcov.a \
      -o output/lab2/bin/lab2
#     (на этой машине macOS/arm64 скрипт сам подставляет -Wl,-no_pie)

# 2.2 тестовые прогоны (10 тестов; каждый пишет свой .profraw и
#     объединяется в bb_cov_raw.json — union, без двойного счёта):
LLVM_PROFILE_FILE=output/lab2/runs/run_1.profraw \
BB_COV_OUT=output/lab2/bb_cov_raw.json \
    output/lab2/bin/lab2 filter
LLVM_PROFILE_FILE=output/lab2/runs/run_2.profraw \
BB_COV_OUT=output/lab2/bb_cov_raw.json \
    output/lab2/bin/lab2 filter2
... # и так далее: calc-add, calc-sub, calc-mul, calc-div, calc-div0,
    # calc-pow, geometry-yes, geometry-no

# 2.3 объединение профилей стандартного покрытия:
llvm-profdata merge -sparse output/lab2/runs/*.profraw \
    -o output/lab2/default.profdata

# 2.4 экспорт line/function/branch покрытия в lcov-формат:
llvm-cov export --format=lcov \
    --instr-profile=output/lab2/default.profdata \
    output/lab2/bin/lab2 > output/lab2/coverage.info

# 2.5 привязка базовых блоков к исходным файлам (PC -> файл:строка):
python3 tools/bb_cov_finalize.py \
    --raw      output/lab2/bb_cov_raw.json \
    --binary   output/lab2/bin/lab2 \
    --output   output/lab2/bb_cov.json \
    --addr2line $(llvm-config --bindir)/llvm-addr2line
```

---

## 3. Команды с genhtml (главное)

### 3.1 Оригинальный (непатченный) genhtml — эталон

```bash
vendor/genhtml_orig output/lab2/coverage.info \
    --branch-coverage -o output/lab2/html_orig
```

Реальный вывод (фрагмент):

```
Reading data file .../output/lab2/coverage.info
Found 2 entries.
...
Overall coverage rate:
  lines......: 88.2% (134 of 152 lines)
  functions..: 100.0% (17 of 17 functions)
  branches...: 78.6% (55 of 70 branches)
```

### 3.2 Патченный genhtml БЕЗ `--bb-report` — обратная совместимость

```bash
vendor/genhtml output/lab2/coverage.info \
    --branch-coverage -o output/lab2/html_plain
```

Вывод идентичен оригиналу (строки про базовые блоки отсутствуют).

### 3.3 Проверка обратной совместимости — сравнение отчётов

```bash
diff -r output/lab2/html_orig output/lab2/html_plain
```

Результат прогона: **PASS: html_orig == html_plain (bit-identical)** —
патченный genhtml без `--bb-report` работает ровно как оригинал.

### 3.4 Патченный genhtml С `--bb-report` — метрика Basic Block Coverage

```bash
vendor/genhtml output/lab2/coverage.info \
    --bb-report output/lab2/bb_cov.json \
    --branch-coverage -o output/lab2/html_bb
```

Реальный вывод (фрагмент):

```
Reading basic block report file .../output/lab2/bb_cov.json
Found 0 basic block report entries.
...
Overall coverage rate:
  lines......: 88.2% (134 of 152 lines)
  functions..: 100.0% (17 of 17 functions)
  branches...: 78.6% (55 of 70 branches)
  basic blcks: no data found
```

На странице проекта (`html_bb/index.html`) появляются:
- колонка **Basic Block Coverage** с баровым индикатором и «выполнено / всего»;
- строка **Basic Blocks:** в шапке (проект, каталоги, файлы).

### 3.5 Контрольные проверки после генерации

```bash
# в патченном отчёте без --bb-report метрики быть НЕ должно:
grep -r -l '>Basic Block Coverage</td>' output/lab2/html_plain | wc -l
# результат: 0

# в отчёте с --bb-report метрика должна присутствовать:
grep -r -l '>Basic Block Coverage</td>' output/lab2/html_bb | wc -l
# результат: 8 (> 0)

# строки Basic Blocks на страницах исходников:
grep -r -l 'Basic Blocks:' output/lab2/html_bb --include='*.gcov.html' | wc -l
# результат: 2
```

---

## 4. Справочник: какие опции genhtml использовались

| Опция | Что делает |
|---|---|
| `-o, --output-directory OUTDIR` | каталог для HTML-отчёта |
| `--branch-coverage` | показать колонку «Branches» (в 1.16 выключена по умолчанию) |
| `--bb-report FILENAME` | **новая опция из нашего патча** — добавить метрику Basic Block Coverage из JSON `FILENAME` |
| (без `--bb-report`) | поведение полностью идентично оригинальному genhtml |

Согласованный вызов (команда из задания):

```bash
genhtml coverage.info \
    --bb-report bb_coverage.json \
    --output-directory html
```

---

## 5. Примечание про окружение

- Прогон выполнен на **macOS/arm64**: там `ld` игнорирует `-no_pie`,
  поэтому `llvm-addr2line` не может связать PC базовых блоков с файлами,
  и в отчёте показывается `Basic Blocks: 0 0 -`.
- На целевой виртуальной машине **Rocky Linux x86_64 (ELF)** сборка
  идёт с `-no-pie` — адреса фиксированы, PC резолвятся в файлы, и
  метрика Basic Block Coverage отображается с реальными числами
  (проверено на проектах cJSON/microtar).