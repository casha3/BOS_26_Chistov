#!/usr/bin/env bash
#
# run_project.sh - универсальный запуск "genhtml + Basic Block Coverage"
# по пути к каталогу C-проекта.
#
# Пользователь указывает каталог с исходниками - скрипт сам:
#   1. собирает runtime-компонент и патченный genhtml (при необходимости);
#   2. автоматически определяет исходники проекта и main()/harness;
#   3. инструментирует сборку (стандартное покрытие + базовые блоки) и
#      прогоняет тестовые входы;
#   4. получает coverage.info и bb_cov.json (llvm-profdata/llvm-cov/bb_cov_finalize);
#   5. генерирует отчёты genhtml (оригинал, патч без/с --bb-report),
#      проверяет обратную совместимость (diff -r);
#   6. пишет лог команд (transcript.log) и отчёт (report.md) в output/<name>/.
#
# Usage:
#   bash run_project.sh <project_dir> [options]
#
# Options:
#   --name N          имя проекта (по умолчанию: basename каталога)
#   --sources "a.c"   явный список исходников проекта (без main-файла)
#   --main FILE       файл с main()/harness (по умолчанию: автодетект)
#   --include "-Idir" дополнительные include-флаги
#   --libs "-lm"      дополнительные библиотеки при линковке
#   --stdin "text"    подать текст в stdin на каждом тестовом прогоне
#   --tests "t1 t2"   тестовые входы (аргументы запуска); можно несколько раз
#   --output DIR      каталог результатов (по умолчанию: output/)
#   --mode M          режим отчёта: all (по умолчанию) | orig | bb
#                     orig - только оригинальный genhtml (без Basic Blocks)
#                     bb   - только патченный genhtml с --bb-report
#                     (алиасы: --orig = --mode orig, --bb = --mode bb)
#

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$HERE"
source "$ROOT/tools/lib_common.sh"

PROJECT_ROOT=""
PROJECT_NAME=""
OPT_SOURCES=""
OPT_MAIN=""
OPT_INCLUDE=""
OPT_LIBS=""
OPT_STDIN=""
OPT_TESTS=()
OPT_OUTPUT="$OUTPUT_DIR"
OPT_MODE="all"

usage() {
    sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
}

while [ $# -gt 0 ]; do
    case "$1" in
        --name)           PROJECT_NAME="${2:-}"; shift 2 ;;
        --sources)        OPT_SOURCES="${2:-}";  shift 2 ;;
        --main)           OPT_MAIN="${2:-}";     shift 2 ;;
        --include)        OPT_INCLUDE="$OPT_INCLUDE ${2:-}"; shift 2 ;;
        --libs)           OPT_LIBS="${2:-}";     shift 2 ;;
        --stdin)          OPT_STDIN="${2:-}";    shift 2 ;;
        --tests)          OPT_TESTS+=("$2");     shift 2 ;;
        --output)         OPT_OUTPUT="${2:-}";   shift 2 ;;
        --mode)           OPT_MODE="${2:-all}";  shift 2 ;;
        --orig)           OPT_MODE="orig";       shift ;;
        --bb)             OPT_MODE="bb";         shift ;;
        -h|--help)        usage ;;
        -*)               echo "unknown option: $1" >&2; usage ;;
        *)                PROJECT_ROOT="$1"; shift ;;
    esac
done

[ -n "$PROJECT_ROOT" ] || { echo "ERROR: укажите каталог проекта" >&2; usage; }

# --- режим отчёта ----------------------------------------------------------
case "$OPT_MODE" in
    orig|bb|all) ;;
    *) echo "ERROR: --mode должен быть orig|bb|all (получено: $OPT_MODE)" >&2; exit 2 ;;
esac

# Абсолютный путь к проекту
PROJECT_ROOT="$(cd "$PROJECT_ROOT" && pwd)"
[ -d "$PROJECT_ROOT" ] || { echo "ERROR: каталог не существует: $PROJECT_ROOT" >&2; exit 1; }

if [ -z "$PROJECT_NAME" ]; then
    PROJECT_NAME="$(basename "$PROJECT_ROOT")"
fi
OUT="$OPT_OUTPUT/$PROJECT_NAME"
mkdir -p "$OUT"

# --- детектирование исходников и main --------------------------------------
candidates=()
for f in "$PROJECT_ROOT"/*.c; do
    [ -f "$f" ] && candidates+=("$f")
done
if [ -d "$PROJECT_ROOT/src" ]; then
    for f in "$PROJECT_ROOT"/src/*.c; do
        [ -f "$f" ] && candidates+=("$f")
    done
fi
[ ${#candidates[@]} -gt 0 ] || { echo "ERROR: в $PROJECT_ROOT не найдены *.c файлы" >&2; exit 1; }

MAIN_FILE=""
if [ -n "$OPT_MAIN" ]; then
    MAIN_FILE="$PROJECT_ROOT/$OPT_MAIN"
    [ -f "$MAIN_FILE" ] || { echo "ERROR: --main не найден: $OPT_MAIN" >&2; exit 1; }
elif [ -f "$PROJECT_ROOT/harness_main.c" ]; then
    MAIN_FILE="$PROJECT_ROOT/harness_main.c"
else
    # ищем файлы, содержащие main(
    mains=()
    for f in "${candidates[@]}"; do
        grep -q "main[[:space:]]*(" "$f" && mains+=("$f")
    done
    if [ ${#mains[@]} -eq 1 ]; then
        MAIN_FILE="${mains[0]}"
    elif [ ${#mains[@]} -gt 1 ] && [ -f "$PROJECT_ROOT/main.c" ]; then
        MAIN_FILE="$PROJECT_ROOT/main.c"
    elif [ ${#mains[@]} -gt 1 ]; then
        echo "ERROR: несколько файлов содержат main():" >&2
        printf '  %s\n' "${mains[@]}" >&2
        echo "       укажите нужный флагом --main <file>" >&2
        exit 1
    else
        echo "ERROR: не найден файл с main(); укажите --main <file>" >&2
        exit 1
    fi
fi

# исходники проекта = все *.c кроме main-файла (если не заданы явно)
SOURCES=""
if [ -n "$OPT_SOURCES" ]; then
    for s in $OPT_SOURCES; do
        SOURCES="$SOURCES $PROJECT_ROOT/$s"
    done
elif [ -n "$OPT_MAIN" ]; then
    # явный --main без --sources => "одна программа": компилируем только
    # указанный файл (иначе подхватятся все остальные main() и будет
    # ошибка линковки)
    SOURCES=""
else
    for f in "${candidates[@]}"; do
        [ "$f" = "$MAIN_FILE" ] && continue
        SOURCES="$SOURCES $f"
    done
fi
SOURCES="$(echo "$SOURCES" | tr -s ' ' | sed 's/^ //;s/ $//')"

INCLUDES="-I$PROJECT_ROOT"
[ -d "$PROJECT_ROOT/src" ] && INCLUDES="$INCLUDES -I$PROJECT_ROOT/src"
INCLUDES="$INCLUDES $OPT_INCLUDE"

echo "======================================================"
echo " Проект:   $PROJECT_ROOT"
echo " Имя:      $PROJECT_NAME"
echo " main():   $MAIN_FILE"
echo " исходники:${SOURCES:- (отсутствуют, только main)}"
echo " include:  $INCLUDES"
echo " libs:     ${OPT_LIBS:- -}"
echo " тесты:    ${OPT_TESTS[*]:- (без аргументов)}"
echo " каталог результатов: $OUT"
echo "======================================================"

# --- временный build.conf с абсолютными путями -----------------------------
CONF_DIR="$OUTPUT_DIR/.conf/$PROJECT_NAME"
mkdir -p "$CONF_DIR"
{
    echo '#!/usr/bin/env bash'
    echo "# generated by run_project.sh for $PROJECT_ROOT"
    echo "PROJECT_C_FILES=\"$SOURCES\""
    echo "HARNESS_C_FILE=\"$MAIN_FILE\""
    echo "EXTRA_INCLUDES=\"$INCLUDES\""
    echo "EXTRA_LDFLAGS=\"$OPT_LIBS\""
    if [ -n "$OPT_STDIN" ]; then
        # подавать этот текст в stdin на каждом тестовом прогоне
        echo "TEST_STDIN=$(printf '%q' "$OPT_STDIN")"
    else
        echo 'TEST_STDIN='
    fi
    if [ ${#OPT_TESTS[@]} -gt 0 ]; then
        printf 'TESTS=('
        for t in "${OPT_TESTS[@]}"; do printf ' "%s"' "$t"; done
        echo " )"
    else
        echo 'TESTS=()'
    fi
} > "$CONF_DIR/build.conf"

TRANSCRIPT="$OUT/transcript.log"
: > "$TRANSCRIPT"

note() { echo "$*" | tee -a "$TRANSCRIPT"; }
run()  { echo "\$ $*" | tee -a "$TRANSCRIPT"; "$@" 2>&1 | tee -a "$TRANSCRIPT"; }

note "==== run_project.sh для проекта $PROJECT_NAME ===="
note "date: $(date '+%Y-%m-%d %H:%M:%S')"
note ""

# --- сборка инструментов (если ещё не собраны) ----------------------------
note "## Шаг 0. сборка runtime и патченного genhtml"
if [ ! -f "$RUNTIME_LIB" ]; then
    run bash "$ROOT/01_build_runtime.sh"
else
    note "(runtime уже собран: $RUNTIME_LIB)"
fi
if [ ! -x "$GENHTML" ]; then
    run bash "$ROOT/02_build_genhtml.sh"
else
    note "(патченный genhtml уже собран: $GENHTML)"
fi
note ""

# --- подготовка данных о покрытии -----------------------------------------
note "## Шаг 1. инструментированная сборка, тестовые прогоны, coverage.info и bb_cov.json"
if ! run bash "$ROOT/tools/build_project.sh" "$CONF_DIR" "$PROJECT_NAME"; then
    note "!! build_project.sh завершился с ошибкой (см. выше)"
fi
note ""

INFO="$OUT/coverage.info"
BB_JSON="$OUT/bb_cov.json"

# Некоторые программы заменяют собственный процесс через exec* и не
# доходят до atexit-обработчика runtime -> bb_cov_raw.json не создаётся.
if [ ! -f "$OUT/bb_cov_raw.json" ]; then
    note "!! bb_cov_raw.json не создан (программа, вероятно, делает exec-замену"
    note "   процесса); создаю пустой bb_cov.json - покроется только line/branch."
    echo '{"sources": {}, "total": {"found": 0, "hit": 0}, "resolved_found": 0, "resolved_hit": 0}' \
        > "$BB_JSON"
fi
[ -f "$INFO" ] || die "coverage.info не создан - сборка/прогон не удались"

# --- genhtml по режиму отчёта ----------------------------------------------
note "режим отчёта: $OPT_MODE"
note ""

case "$OPT_MODE" in
    orig)
        note "## Шаг 2. genhtml: оригинал (без Basic Blocks)"
        run "$GENHTML_ORIG" "$INFO" --branch-coverage -o "$OUT/html_orig"
        note ""
        ;;
    bb)
        note "## Шаг 5. genhtml: патченный с --bb-report (Basic Block Coverage)"
        run "$GENHTML" "$INFO" --bb-report "$BB_JSON" --branch-coverage \
            -o "$OUT/html_bb"
        note ""
        ;;
    *)
        note "## Шаг 2. genhtml: оригинал "
        run "$GENHTML_ORIG" "$INFO" --branch-coverage -o "$OUT/html_orig"
        note ""

        note "## Шаг 3. genhtml: патченный без --bb-report"
        run "$GENHTML" "$INFO" --branch-coverage -o "$OUT/html_plain"
        note ""

        note "## Шаг 4. обратная совместимость (diff, без поля Date)"
        if tree_diff_identical "$OUT/html_orig" "$OUT/html_plain"; then
            COMPAT="PASS: html_orig =~ html_plain (идентичны по содержимому)"
        else
            COMPAT="FAIL: отчёты различаются, см. $OUT/compat.diff"
            diff -r "$OUT/html_orig" "$OUT/html_plain" \
                > "$OUT/compat.diff" 2>&1 || true
        fi
        note "result: $COMPAT"
        note ""

        note "## Шаг 5. genhtml: патченный с --bb-report"
        run "$GENHTML" "$INFO" --bb-report "$BB_JSON" --branch-coverage \
            -o "$OUT/html_bb"
        note ""
        ;;
esac

# --- проверки -------------------------------------------------------------
HAS_BB_PLAIN="-"
HAS_BB_BB="-"
BB_HEADER="-"
FILES_WITH_BB="-"
DIRS_WITH_BB="-"

case "$OPT_MODE" in
    all)
        HAS_BB_PLAIN=$(grep -r -l '>Basic Block Coverage</td>' "$OUT"/html_plain \
                       2>/dev/null | wc -l | tr -d ' ' || true)
        HAS_BB_BB=$(grep -r -l '>Basic Block Coverage</td>' "$OUT/html_bb" \
                    2>/dev/null | wc -l | tr -d ' ' || true)
        BB_HEADER=$(grep -A4 'headerItem">Basic Blocks:' \
                    "$OUT/html_bb/index.html" 2>/dev/null \
                    | tr '\n' ' ' | sed -E 's/<[^>]+>/ /g' | tr -s ' ' || true)
        FILES_WITH_BB=$(grep -r -l "Basic Blocks:" \
                       "$OUT/html_bb" --include="*.gcov.html" \
                       2>/dev/null | wc -l | tr -d ' ' || true)
        DIRS_WITH_BB=$(grep -r -l '>Basic Block Coverage</td>' \
                      "$OUT/html_bb" --include="index.html" \
                      2>/dev/null | wc -l | tr -d ' ' || true)
        ;;
    bb)
        HAS_BB_BB=$(grep -r -l '>Basic Block Coverage</td>' "$OUT/html_bb" \
                    2>/dev/null | wc -l | tr -d ' ' || true)
        BB_HEADER=$(grep -A4 'headerItem">Basic Blocks:' \
                    "$OUT/html_bb/index.html" 2>/dev/null \
                    | tr '\n' ' ' | sed -E 's/<[^>]+>/ /g' | tr -s ' ' || true)
        FILES_WITH_BB=$(grep -r -l "Basic Blocks:" \
                       "$OUT/html_bb" --include="*.gcov.html" \
                       2>/dev/null | wc -l | tr -d ' ' || true)
        DIRS_WITH_BB=$(grep -r -l '>Basic Block Coverage</td>' \
                      "$OUT/html_bb" --include="index.html" \
                      2>/dev/null | wc -l | tr -d ' ' || true)
        ;;
    orig)
        : ;;
esac

note "## Шаг 6. проверка результатов (режим: $OPT_MODE)"
[ "$HAS_BB_PLAIN" != "-" ] && \
    note "grep '>Basic Block Coverage</td>' html_plain -> $HAS_BB_PLAIN (ожидается 0)"
[ "$HAS_BB_BB" != "-" ] && \
    note "grep '>Basic Block Coverage</td>' html_bb    -> $HAS_BB_BB (ожидается > 0)"
[ -n "$BB_HEADER" ] && [ "$BB_HEADER" != "-" ] && note "header проекта: $BB_HEADER"
[ "$FILES_WITH_BB" != "-" ] && note "страницы файлов с Basic Blocks: $FILES_WITH_BB"
[ "$DIRS_WITH_BB" != "-" ] && note "индексные страницы с метрикой: $DIRS_WITH_BB"
note ""

# --- итоговый отчёт report.md ---------------------------------------------
case "$OPT_MODE" in
    orig)
        R_CMDS="# оригинальный (непатченный) genhtml, без Basic Blocks:
${GENHTML_ORIG} $INFO --branch-coverage -o $OUT/html_orig"
        R_RESULTS="| Режим отчёта | orig (оригинальный genhtml, без Basic Blocks) |
| Сгенерирован | \`$OUT/html_orig/\` |"
        R_LINK="$OUT/html_orig/index.html"
        ;;
    bb)
        R_CMDS="# патченный genhtml С --bb-report (Basic Block Coverage):
${GENHTML} $INFO --bb-report $BB_JSON --branch-coverage -o $OUT/html_bb"
        R_RESULTS="| Режим отчёта | bb (патченный genhtml с --bb-report) |
| Вхождений \"Basic Block Coverage\" в html_bb | $HAS_BB_BB (ожидается > 0) |
| Страницы файлов с метрикой | $FILES_WITH_BB |
| Индексные страницы с метрикой | $DIRS_WITH_BB |
| Заголовок на странице проекта | ${BB_HEADER:-}- |"
        R_LINK="$OUT/html_bb/index.html"
        ;;
    *)
        R_CMDS="# оригинал (эталон):
${GENHTML_ORIG} $INFO --branch-coverage -o $OUT/html_orig

# патченный БЕЗ --bb-report (поведение = оригинал):
${GENHTML} $INFO --branch-coverage -o $OUT/html_plain

# обратная совместимость:
diff -r $OUT/html_orig $OUT/html_plain

# патченный С --bb-report (метрика Basic Block Coverage):
${GENHTML} $INFO --bb-report $BB_JSON --branch-coverage -o $OUT/html_bb"
        R_RESULTS="| Обратная совместимость (diff) | **$COMPAT** |
| Вхождений \"Basic Block Coverage\" в html_plain | $HAS_BB_PLAIN (ожидается 0) |
| Вхождений \"Basic Block Coverage\" в html_bb | $HAS_BB_BB (ожидается > 0) |
| Страницы файлов с метрикой | $FILES_WITH_BB |
| Индексные страницы с метрикой | $DIRS_WITH_BB |
| Заголовок на странице проекта | ${BB_HEADER:-}- |"
        R_LINK="$OUT/html_bb/index.html"
        ;;
esac

{
    cat <<EOF
# Отчёт: genhtml + Basic Block Coverage для проекта *$PROJECT_NAME*

**Каталог проекта:** \`$PROJECT_ROOT\`
**Дата прогона:** $(date '+%Y-%m-%d %H:%M:%S')
**Режим отчёта:** $OPT_MODE

## 1. Использованные команды

### 1.1 Сборка инструментов

\`\`\`bash
bash 01_build_runtime.sh
bash 02_build_genhtml.sh
\`\`\`

### 1.2 Инструментированная сборка и прогоны (tools/build_project.sh, внутренние команды)

\`\`\`bash
clang -g -O0 -no-pie \
      -fprofile-instr-generate \\
      -fcoverage-mapping \\
      -fsanitize-coverage=bb,no-prune,inline-bool-flag,pc-table \\
      $INCLUDES \\
      $SOURCES $MAIN_FILE build/libbbcov.a \\
      $OPT_LIBS -o $OUT/bin/$PROJECT_NAME

# тестовые прогоны (каждый -> свой .profraw, объединение в bb_cov_raw.json):
LLVM_PROFILE_FILE=$OUT/runs/run_N.profraw BB_COV_OUT=$OUT/bb_cov_raw.json \\
    $OUT/bin/$PROJECT_NAME${OPT_TESTS:+ <test>}
# тестовые входы: ${OPT_TESTS[*]:-<без аргументов>}

llvm-profdata merge -sparse $OUT/runs/*.profraw -o $OUT/default.profdata

llvm-cov export --format=lcov --instr-profile=$OUT/default.profdata \\
    $OUT/bin/$PROJECT_NAME > $OUT/coverage.info

python3 tools/bb_cov_finalize.py --raw $OUT/bb_cov_raw.json \\
    --binary $OUT/bin/$PROJECT_NAME --output $OUT/bb_cov.json
\`\`\`

### 1.3 Команды с genhtml (режим: $OPT_MODE)

\`\`\`bash
$R_CMDS
\`\`\`

## 2. Результаты

| Проверка | Результат |
|---|---|
$R_RESULTS

Полный журнал команд и вывода: \`$TRANSCRIPT\`.
Отчёт: \`$R_LINK\`.

## 3. Примечание про окружение

$([ "$(uname -s)" = "Darwin" ] \
   && echo "Это macOS/arm64: ld игнорирует -no_pie, поэтому адреса базовых" \
   && echo "блоков недоступны для llvm-addr2line и Basic Blocks = 0/0." \
   && echo "На Rocky Linux x86_64 (ELF, -no-pie) метрика заполняется реальными значениями." \
   || echo "Окружение Linux/ELF: -no-pie работает, метрика заполняется." )

Для корректного счёта базовых блоков на x86_64/ELF сборка должна идти с -no-pie (задано в tools/lib_common.sh автоматически).
EOF
} > "$OUT/report.md"

echo "======================================================"
echo " Готово (режим: $OPT_MODE). Смотрите:"
echo "   $OUT/report.md"
echo "   $OUT/transcript.log"
echo "   $R_LINK"
echo "======================================================"