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
├── projects/                   # сюда кладёте свои репозитории (по умолчанию пусто)
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

## Анализ произвольного репозитория (analyze.sh)

Единый интерфейс: вы сами клонируете репозиторий в `projects/<имя>` и
запускаете утилиту по имени + флаг — она анализирует репозиторий целиком.

```bash
git clone <github-url> projects/<имя>     # вы скачиваете сами

bash analyze.sh <имя>                     # полный анализ
bash analyze.sh <имя> --orig               # только оригинальный genhtml (без BB)
bash analyze.sh <имя> --bb                 # только патченный genhtml с --bb-report
```

Автоматика (без указания файлов, без добавления новых файлов):
- рекурсивно ищется `main()` по ВСЕМУ скачанному репозиторию (корень,
  `src/`, `include/`, `test/`, `examples/`, `contrib/` и пр.; пропускаются
  `.git` и build-каталоги);
- не найдено `main()` → «анализировать нечего» (чистая библиотека);
- один `main()` → одиночный анализ всего кода репозитория;
- несколько `main()` → все программы анализируются и объединяются в один
  отчёт; includes подхватываются сами (`-I<repo>`, `-I<repo>/src`,
  `-I<repo>/include`).

Дополнительно:
- `bash analyze.sh --list` — список репозиториев в `projects/`;
- флаги: `--tests "a b"`, `--stdin "text"`, `--libs "-lm"`, `--include "-Idir"`,
  `--output DIR`, `--mode orig|bb|all`, `--name`;
- постоянные параметры на репозиторий — файл `projects/<имя>/project.conf`
  (`PROJECT_NAME`, `PROJECT_LIBS`, `PROJECT_INCLUDE`, `PROJECT_TESTS`,
  `PROJECT_STDIN`, `PROJECT_OUTPUT`); флаги командной строки имеют приоритет.
- серверы/игры/циклы автоматически ограничены таймаутом `RUN_TIMEOUT`
  (по умолчанию 20 c, переопределяется переменной).

### Как запустить для произвольного кода (пошагово)

**0. Подготовка (один раз).** Нужен Clang/LLVM (`brew install llvm` на
macOS, `dnf install clang llvm` на Rocky). Инструменты соберутся
автоматически, либо вручную:

```bash
bash 01_build_runtime.sh     # runtime базовых блоков
bash 02_build_genhtml.sh     # патченный genhtml
```

**1. Любой каталог с C-исходниками (произвольный путь).** Передайте
`analyze.sh` путь — он проанализирует весь код внутри:

```bash
bash analyze.sh /путь/к/папке/с/кодом --bb     # только патченный с BB
bash analyze.sh /путь/к/папке/с/кодом --orig   # только оригинальный (без BB)
bash analyze.sh /путь/к/папке/с/кодом          # полный анализ
```

**2. Репозиторий с GitHub (скачанный в `projects/`).** Склонируйте сами и
запустите по имени:

```bash
git clone <url> projects/<имя>
bash analyze.sh <имя> --bb
bash analyze.sh --list        # список репозиториев в projects/
```

**3. Автоматика (без указания файлов и без добавления новых).**
Рекурсивно ищется `main()` по всему коду (корень, `src/`, `include/`,
`test/`, `examples/`, `contrib/`; пропускаются `.git` и build-каталоги).
Один `main()` → одиночный анализ; несколько → все программы объединяются в
один отчёт; нет `main()` → «анализировать нечего» (чистая библиотека).
Includes подхватываются сами (`-I<repo>`, `-I<repo>/src`, `-I<repo>/include`).

**4. Полезные флаги.**
- `--orig` / `--bb` / `--mode=M` — режим отчёта;
- `--tests "a b"` — аргументы тестовых запусков;
- `--stdin "text"` — подать текст в stdin на каждом прогоне;
- `--libs "-lm"` / `--include "-Idir"` — дополнительные библиотеки/пути;
- `--output DIR` / `--name N` — куда и под каким именем сохранить результат.

**5. Результат.** В `output/<имя>/`:
```
coverage.info     # line/func/branch покрытие
bb_cov.json       # basic block покрытие (по файлам)
html_orig/        # оригинальный genhtml (если --orig/полный)
html_bb/          # патченный genhtml с Basic Block Coverage (--bb/полный)
report.md         # оформленный лог команд + результат
transcript.log    # журнал
```
Открыть отчёт: `open output/<имя>/html_bb/index.html` (macOS).

**6. Ограничения.**
- чистая библиотека без `main()` — нет исполняемого драйвера, анализ
  невозможен (новые файлы не создаются);
- серверы/игры/циклы не завершаются сами — `RUN_TIMEOUT` (по умолчанию
  20 c) прерывает их, поэтому Basic Blocks могут быть `0/0`;
- платформенно-зависимый код (`windows.h` и т.п.) на другой ОС может не
  собраться — такие программы просто пропускаются.

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
  `llvm-addr2line` и получает `bb_cov.json`:
  `{ "sources": { file: {found, hit} }, ... }`. Чтобы адреса совпадали с
  линковочными: на Linux/ELF используется `-no-pie`; на macOS бинарник
  всегда PIE, поэтому runtime сохраняет ASLR-сдвиг (`slide`), а
  `bb_cov_finalize.py` вычитает его перед символизацией — работать
  должно и на Apple Silicon;
* патченный `genhtml` с опцией `--bb-report bb_cov.json` добавляет
  колонку и строки «Basic Blocks» на страницы проекта, каталогов и
  файлов. Без `--bb-report` он работает ровно как оригинал.

## Запуск на Rocky Linux (x86_64)

Нужны права root и доступ в интернет (скачиваются пакеты и исходники LCOV).

```bash
# 1) закинуть этот каталог на VM, например
#       scp -r bonus_1 user@rocky:~/
cd bonus_1

# 2) установить зависимости:
sudo bash 00_install_deps.sh     # gcc clang llvm git perl-JSON-PP ...

# 3) собрать инструменты:
bash 01_build_runtime.sh         # libbbcov.a
bash 02_build_genhtml.sh         # vendor/genhtml + vendor/genhtml_orig

# 4) проанализировать произвольный репозиторий
#    (положить клон в projects/<имя> или передать path):
bash analyze.sh <имя> --bb
```

Результаты — в `output/<имя>/`:

```bash
ls output/<имя>/
# coverage.info bb_cov.json bb_cov_raw.json html_bb/
# открыть отчёт с метрикой Basic Block Coverage:
xdg-open output/<имя>/html_bb/index.html
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

* **LLVM не найден (macOS)**: скрипт берёт каталог только если в нём есть
  весь набор (clang+llvm-profdata+llvm-cov+llvm-addr2line). На Apple
  Silicon обычно авто-выбирается Homebrew LLVM; если нет, задайте
  `export LLVM_DIR=/opt/homebrew/opt/llvm/bin` (или `brew install llvm`).
* **«attributed 0» / Basic Blocks 0/0**: на Linux/ELF соберите с
  `-no-pie`; на macOS/Apple Silicon сдвиг ASLR обрабатывается runtime +
  `bb_cov_finalize.py` автоматически. Если вручную отлаживаете — укажите
  `LLVM_ADDR2LINE`.
* **Разные версии LLVM**: скрипты пробуют обе формы
  `llvm-cov export` (`--format=lcov` и `-format=lcov`).
* **Нет адресов**: если `llvm-addr2line` отсутствует в PATH, укажите его
  через `LLVM_DIR=/usr/lib/llvm-<N>/bin` или переменные
  `LLVM_ADDR2LINE`/`CLANG`/`LLVM_PROFDATA`/`LLVM_COV`.