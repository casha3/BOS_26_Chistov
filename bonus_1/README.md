# Бонусное задание №1 — «Модификация утилиты genhtml»

Расширение утилиты `genhtml` из пакета LCOV: добавлена метрика
**Basic Block Coverage** (покрытие по базовым блокам) к стандартным
метрикам Line / Function / Branch Coverage.

Сборка базовых блоков выполняется средствами **Clang/LLVM
SanitizerCoverage** (`-fsanitize-coverage=bb,no-prune,inline-bool-flag,pc-table`)
в той же инструментированной сборке, что и стандартное покрытие.

## Структура каталога

```
.
├── run_all.sh                  # главный скрипт (делает всё по порядку)
├── 00_install_deps.sh          # установка зависимостей (Rocky Linux / dnf)
├── 01_build_runtime.sh         # сборка runtime-компонента (build/libbbcov.a)
├── 02_build_genhtml.sh         # скачивание LCOV 1.16, применение патча,
│                               #  vendor/genhtml и vendor/genhtml_orig
├── src/
│   ├── bb_cov_runtime.c        # runtime: SanitizerCoverage-интерфейсы,
│   │                           #  слияние прогонов, запись JSON
│   └── bb_cov_runtime.h
├── tools/
│   ├── lib_common.sh           # общие настройки (поиск LLVM, флаги)
│   ├── bb_cov_finalize.py      # PC -> файл через llvm-addr2line
│   └── build_project.sh        # сборка/прогон произвольного проекта
├── patch/
│   └── genhtml.patch           # патч genhtml 1.16 (опция --bb-report)
├── projects/
│   ├── cjson/                  # тестовый проект 1 (DaveGamble/cJSON)
│   └── microtar/               # тестовый проект 2 (rxi/microtar)
├── verify/
│   └── check_compat.sh         # проверка обратной совместимости + отчёты
└── output/<project>/           # все результаты (создаётся при запуске)
    ├── coverage.info           # стандартное покрытие (llvm-cov export)
    ├── bb_cov_raw.json         # сырой отчёт runtime (PC + выполненные блоки)
    ├── bb_cov.json             # итоговый отчёт: файл -> {found, hit}
    ├── html_orig/              # отчёт оригинального genhtml
    ├── html_plain/             # патченный genhtml БЕЗ --bb-report
    └── html_bb/                # патченный genhtml С  --bb-report
```

## Как это работает

Программа компилируется обычным способом с дополнительными флагами:

```
-fprofile-instr-generate \
-fcoverage-mapping \
-fsanitize-coverage=bb,no-prune,inline-bool-flag,pc-table \
-g -O0 -no-pie
```

* `-fprofile-instr-generate -fcoverage-mapping` — стандартное покрытие
  (строки/функции/ветви), из прогонов получаются `*.profraw`, которые
  `llvm-profdata merge` объединяет в `default.profdata`, а `llvm-cov
  export --format=lcov` превращает в `coverage.info`;
* `-fsanitize-coverage=bb,no-prune,inline-bool-flag,pc-table` —
  инструментирование базовых блоков. Компилятор для каждого блока
  вставляет inline-флаг и вызывает runtime-колбэки
  `__sanitizer_cov_bool_flag_init` (массив флагов) и
  `__sanitizer_cov_pcs_init` (таблица PC всех блоков) — см.
  `src/bb_cov_runtime.c`. По числу флагов/PC определяется общее число
  инструментированных блоков, а по выставленным флагам — число
  выполненных;
* при завершении процесса runtime дописывает сырой JSON
  (`bb_cov_raw.json`), каждый следующий прогон **объединяется** с
  предыдущими (union выполненного множества битов) — базовый блок,
  выполненный в нескольких тестах, считается один раз
  (как и `*.profraw` через `llvm-profdata merge`);
* `tools/bb_cov_finalize.py` резолвит каждый PC в `файл:строку` через
  `llvm-addr2line` (для этого нужен `-no-pie`, чтобы адреса загрузки
  совпадали с адресами линковки) и получает
  `bb_cov.json`: `{ "sources": { file: {found, hit} }, ... }`;
* патченный `genhtml` с опцией `--bb-report bb_cov.json` добавляет
  колонку и строки «Basic Blocks» на страницы проекта, каталогов и
  файлов. Без `--bb-report` он работает ровно как оригинал.

## Запуск на Rocky Linux (x86_64)

Нужны права root и доступ в интернет (скачиваются пакеты, исходники
LCOV и два открытых проекта).

```bash
# 1) закинуть этот каталог на VM, например
#       scp -r bonus_1 user@rocky:~/
cd bonus_1

# 2) всё одной командой (включая установку пакетов):
sudo bash run_all.sh --install

# или по шагам:
sudo bash 00_install_deps.sh     # gcc clang llvm git perl-JSON-PP ...
bash 01_build_runtime.sh         # libbbcov.a
bash 02_build_genhtml.sh         # vendor/genhtml + vendor/genhtml_orig
bash projects/cjson/build_and_run.sh    # сборка/замер проекта 1
bash projects/microtar/build_and_run.sh # сборка/замер проекта 2
bash verify/check_compat.sh cjson
bash verify/check_compat.sh microtar
```

Результаты — в `output/`:

```bash
ls output/cjson/
# coverage.info bb_cov.json html_orig/ html_plain/ html_bb/
# открыть отчёт с метрикой Basic Block Coverage:
xdg-open output/cjson/html_bb/index.html
```

## Соответствие формальным требованиям

| Требование | Где реализовано |
|---|---|
| 1. Инструментация Clang/LLVM | `tools/lib_common.sh` (флаги SanitizerCoverage), `src/bb_cov_runtime.c` |
| 2. Стандартное и BB-покрытие в одной сборке | одни и те же флаги компиляции; из одной бинарки получаются `*.profraw` и `bb_cov_raw.json` |
| 3. Общее/выполненное число блоков | `__sanitizer_cov_bool_flag_init`/`__sanitizer_cov_pcs_init`, поля `total_blocks`/`executed_indices` |
| 4. Привязка блоков к исходным файлам | `tools/bb_cov_finalize.py` (PC→`файл:строка` через `llvm-addr2line`) |
| 5. Объединение нескольких тестовых входов | `llvm-profdata merge` + слияние `bb_cov_raw.json` на каждом прогоне |
| 6. Исключение повторного счёта блока | union выполненного множества в `bb_cov_dump()` / `bb_merge_previous()` |
| 7. Обратная совместимость | `vendor/genhtml_orig` vs `vendor/genhtml` без `--bb-report` — вывод байт-в-байт совпадает (`verify/check_compat.sh`) |
| Метрика на страницах проекта/каталогов/файлов | `patch/genhtml.patch`: колонка в таблицах (`write_file_table`) и строки в шапке (`write_header`) |

## Как проверить результаты

* Обратная совместимость: `diff -r output/<p>/html_orig output/<p>/html_plain`
  не должен выдавать различий (проверяет `check_compat.sh`).
* Новая метрика: в `output/<p>/html_bb/index.html` колонка
  «Basic Block Coverage» (бар + проценты + «выполнено/всего»), строки
  «Basic Blocks» на страницах каталогов и файлов.
* Консольная сводка патченного genhtml печатает
  `basic blcks: N% (M of K basic blocks)`.
* JSON-отчёты: `output/<p>/bb_cov.json` содержит пофайловые
  `found`/`hit`.

## Возможные проблемы

* **Не резолвятся PCC / «attributed 0»**: убедитесь, что бинарники
  собраны с `-no-pie` (для x86_64 ELF). На macOS/Apple-Silicon локально
  это недостижимо, но на Rocky Linux x86_64 работает.
* **Разные версии LLVM**: скрипты пробуют обе формы
  `llvm-cov export` (`--format=lcov` и `-format=lcov`).
* **Нет адресов**: если `llvm-addr2line` отсутствует в PATH, укажите его
  через `LLVM_DIR=/usr/lib/llvm-<N>/bin` или переменные
  `LLVM_ADDR2LINE`/`CLANG`/`LLVM_PROFDATA`/`LLVM_COV`.