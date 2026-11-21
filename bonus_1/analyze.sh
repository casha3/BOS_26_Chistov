#!/usr/bin/env bash
#
# analyze.sh - анализ репозитория целиком (genhtml + Basic Block Coverage).
#
# Пользователь сам клонирует репозиторий в projects/ (или указывает путь) и
# запускает утилиту по имени репозитория + флаг:
#
#   bash analyze.sh <имя_репозитория> [флаги]
#
# Флаги:
#   --orig            только оригинальный (непатченный) genhtml, без Basic Blocks
#   --bb              только патченный genhtml с --bb-report (Basic Block Coverage)
#   --mode=M          все три варианта выше через перечисление: orig|bb|all
#   --tests "a b c"   тестовые входы (аргументы запуска); можно несколько раз
#   --stdin "text"    подать текст в stdin на каждом прогоне
#   --libs "-lm"      дополнительные библиотеки
#   --include "-Idir" дополнительные include-флаги
#   --output DIR      базовый каталог результатов (по умолчанию output/)
#   --list            список репозиториев в projects/
#
# Автоматическое определение структуры репозитория:
#   рекурсивно сканируется ВЕСЬ скачанный репозиторий (корень, src/,
#   include/, test/, examples/, contrib/ и пр.; пропускаются .git и
#   build/каталоги) в поисках исполняемых программ (main()).
#   - не найдено main()  -> "анализировать нечего" (это библиотека);
#   - одна программа     -> одиночный анализ всего кода;
#   - несколько программ -> все анализируются и объединяются в один отчёт.
# Никаких новых файлов (harness'ей) не создаётся - анализируется только
# то, что скачано с GitHub.
#
# Постоянные параметры для конкретного репозитория можно задать в
# projects/<имя>/project.conf (bash-совместимый):
#   PROJECT_LIBS, PROJECT_INCLUDE, PROJECT_TESTS, PROJECT_STDIN,
#   PROJECT_NAME, PROJECT_OUTPUT.
# Флаги командной строки имеют приоритет над project.conf.
#

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/tools/lib_common.sh"

export RUN_TIMEOUT="${RUN_TIMEOUT:-20}"

MODE="all"
CLI_LIBS=""
CLI_INCLUDE=""
CLI_STDIN=""
CLI_OUTPUT=""
PROJ_NAME=""
CLI_TESTS=()
REPO=""

usage() {
    sed -n '2,48p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        --orig)         MODE="orig"; shift ;;
        --bb)           MODE="bb"; shift ;;
        --mode=*)       MODE="${1#--mode=}"; shift ;;
        --mode)         MODE="${2:-all}"; shift 2 ;;
        --tests)        CLI_TESTS+=("$2"); shift 2 ;;
        --stdin)        CLI_STDIN="$2"; shift 2 ;;
        --libs)         CLI_LIBS="$2"; shift 2 ;;
        --include)      CLI_INCLUDE="$CLI_INCLUDE ${2:-}"; shift 2 ;;
        --output)       CLI_OUTPUT="$2"; shift 2 ;;
        --name)         PROJ_NAME="$2"; shift 2 ;;
        --list|-l)
            echo "Репозитории в projects/:"
            for d in "$HERE"/projects/*/; do
                [ -d "$d" ] && echo "  $(basename "$d")"
            done
            exit 0
            ;;
        -h|--help)      usage ;;
        -*)             echo "unknown option: $1" >&2; exit 2 ;;
        *)              REPO="$1"; shift ;;
    esac
done

[ -n "$REPO" ] || { echo "использование: bash analyze.sh <имя_репозитория> [флаги]" >&2; exit 2; }
case "$MODE" in orig|bb|all) ;; *) echo "ERROR: --mode должен быть orig|bb|all" >&2; exit 2 ;; esac

# --- разрешение каталога репозитория ---------------------------------------
if [ -d "$REPO" ]; then
    DIR="$(cd "$REPO" && pwd)"
elif [ -d "$HERE/projects/$REPO" ]; then
    DIR="$HERE/projects/$REPO"
else
    echo "ERROR: репозиторий '$REPO' не найден." >&2
    echo "       положите его в projects/$REPO или укажите путь" >&2
    exit 1
fi

# --- project.conf (по умолчанию для репозитория) ----------------------------
if [ -f "$DIR/project.conf" ]; then
    source "$DIR/project.conf"
fi
LIBS="${CLI_LIBS:-${PROJECT_LIBS:-}}"
INCLUDE="${CLI_INCLUDE:-${PROJECT_INCLUDE:-}}"
STDIN="${CLI_STDIN:-${PROJECT_STDIN:-}}"
if [ ${#CLI_TESTS[@]} -gt 0 ]; then
    TESTS=("${CLI_TESTS[@]}")
else
    TESTS=("${PROJECT_TESTS[@]:-}")
fi

NAME="${PROJ_NAME:-${PROJECT_NAME:-$(basename "$DIR")}}"
OUT_BASE="${CLI_OUTPUT:-${PROJECT_OUTPUT:-$OUTPUT_DIR}}"
OUT="$OUT_BASE/$NAME"
mkdir -p "$OUT"

find_llvm_tools

echo "======================================================"
echo " Репозиторий : $DIR"
echo " Имя         : $NAME"
echo " Режим       : $MODE"
echo " Результаты  : $OUT"
echo "======================================================"

# --- сборка инструментов, если ещё не собраны -------------------------------
if [ ! -f "$RUNTIME_LIB" ]; then bash "$HERE/01_build_runtime.sh"; fi
if [ ! -x "$GENHTML" ]; then bash "$HERE/02_build_genhtml.sh"; fi

# --- рекурсивный поиск исполняемых программ (main()) ------------------------
# Сканируем ВЕСЬ скачанный репозиторий (корень, src/, include/, test/,
# examples/, contrib/ и пр.), пропуская .git и build-каталоги.
candidates=()
while IFS= read -r f; do
    candidates+=("$f")
done < <(find "$DIR" -name '*.c' \
    ! -path '*/\.git/*' \
    ! -path '*/build/*' \
    ! -path '*/bin/*' \
    ! -path '*/output/*' \
    ! -path '*/.build*/*' 2>/dev/null | sort)

[ ${#candidates[@]} -gt 0 ] || { echo "ERROR: в репозитории нет *.c файлов" >&2; exit 1; }

# find_main_line <file> : номер строки первого main( вне комментариев (или пусто)
find_main_line() {
    awk '
        BEGIN{inblk=0}
        {
            line=$0; out=""; n=length(line); i=1
            while (i<=n) {
                c=substr(line,i,1); d=substr(line,i,2)
                if (inblk) { if (d=="*/"){inblk=0;i+=2;continue} i++; continue }
                if (d=="/*"){inblk=1;i+=2;continue}
                if (d=="//"){ i=n; continue }
                out=out c; i++
            }
            if (out ~ /[^A-Za-z0-9_]main[[:space:]]*\(/) { print NR; exit }
        }
    ' "$1"
}

mains=()
for f in "${candidates[@]}"; do
    ln=$(find_main_line "$f" || true)
    [ -n "$ln" ] || continue
    # пропускаем main() внутри #if-guard (например crc32.c под MAKECRCH) -
    # это библиотечный файл, а не исполняемая программа
    open=$(awk -v ln="$ln" '
        /^[[:space:]]*#[[:space:]]*(ifdef|ifndef)/ {o++}
        /^[[:space:]]*#[[:space:]]*if[[:space:](]/ {o++}
        /^[[:space:]]*#[[:space:]]*endif/ {o--}
        NR==ln {print o+0; exit}
    ' "$f")
    if [ "${open:-0}" -eq 0 ]; then
        mains+=("$f")
    fi
done

if [ ${#mains[@]} -eq 0 ]; then
    echo "В скачанном репозитории не найдено исполняемых программ (main())." >&2
    echo "Проанализировать нечего: это библиотека без исполняемого драйвера." >&2
    exit 1
fi

# --- автоматические include-флаги репозитория ------------------------------
AUTO_INC="-I$DIR"
[ -d "$DIR/src" ] && AUTO_INC="$AUTO_INC -I$DIR/src"
[ -d "$DIR/include" ] && AUTO_INC="$AUTO_INC -I$DIR/include"
# zlib-style: если есть gz*-исходники, подключаем <unistd.h>
if grep -rq -E 'gz(lib|read|write|close).*\.c|gzguts\.h' "$DIR" 2>/dev/null; then
    AUTO_INC="$AUTO_INC -DZ_HAVE_UNISTD_H"
fi
INCLUDE="${INCLUDE:+$INCLUDE }$AUTO_INC"

# ================= mode: multi (все программы объединяются) ===================
TRANSCRIPT="$OUT/transcript.log"
: > "$TRANSCRIPT"
note() { echo "$*" | tee -a "$TRANSCRIPT"; }
run()  { echo "\$ $*" | tee -a "$TRANSCRIPT"; "$@" 2>&1 | tee -a "$TRANSCRIPT"; }

note "==== analyze.sh для $NAME, режим $MODE ===="
note "найдено исполняемых программ: ${#mains[@]} (объединяются в один отчёт)"
note ""

feed_stdin() { [ -n "$STDIN" ] && printf '%s' "$STDIN"; true; }

with_timeout() {
    local secs="$1"; shift
    local rc=0
    "$@" & local pid=$!
    ( sleep "$secs"; kill -9 "$pid" 2>/dev/null ) &
    local killer=$!
    wait "$pid" 2>/dev/null; rc=$?
    kill "$killer" 2>/dev/null
    wait "$killer" 2>/dev/null || true
    return $rc
}

mkdir -p "$OUT/bin" "$OUT/runs" "$OUT/info" "$OUT/bb"

# shared sources для программы = не-main *.c из каталога этой программы и её
# предков (до корня репо). Так для test/example.c подтягивается библиотека
# в корне, но НЕ попадают платформенные contrib/* (crc32vx, iowin32 и т.п.).

is_member() {  # is_member <value> <list...>
    local v="$1"; shift
    local x
    for x in "$@"; do [ "$v" = "$x" ] && return 0; done
    return 1
}

idx=0
for m in "${mains[@]}"; do
    idx=$((idx + 1))
    bname="$(basename "$m" .c)"
    BIN="$OUT/bin/p${idx}_$bname"
    BBRAW="$OUT/runs/p${idx}_$bname.bbjson"

    # каталоги-предки файла main (относительно корня репо)
    rel="${m#"$DIR"/}"
    adir="$(dirname "$rel")"
    [ "$adir" = "." ] && adir=""
    anc_dirs="$adir"
    cur="$adir"
    while [ -n "$cur" ]; do
        cur="$(dirname "$cur")"
        [ "$cur" = "." ] && cur=""
        [ -n "$cur" ] && anc_dirs="$cur $anc_dirs"
    done

    shared=""
    for f in "${candidates[@]}"; do
        is_member "$f" "${mains[@]}" && continue
        frel="${f#"$DIR"/}"
        fd="$(dirname "$frel")"
        [ "$fd" = "." ] && fd=""
        if [ -z "$fd" ] || is_member "$fd" $anc_dirs; then
            shared="$shared $f"
        fi
    done

    note "## Программа $idx: $m"
    if ! ( cd "$DIR" && \
           "$CLANG" "${INSTR_FLAGS[@]}" $INCLUDE \
               $shared "$m" "$RUNTIME_LIB" $LIBS -o "$BIN" ); then
        note "!! сборка не удалась: $m (пропускаю)"
        continue
    fi

    # тестовые прогоны (по умолчанию один запуск без аргументов)
    t=0
    mkdir -p "$OUT/run_work"
    for testname in "${TESTS[@]:-}"; do
        t=$((t + 1))
        profraw="$OUT/runs/p${idx}_${bname}_t${t}.profraw"
        if [ -n "$testname" ]; then note "   run: '$testname'"; else note "   run (default)"; fi
        export LLVM_PROFILE_FILE="$profraw" BB_COV_OUT="$BBRAW" BB_COV_QUIET=1
        if [ -n "${RUN_TIMEOUT:-}" ]; then
            ( cd "$OUT/run_work" && feed_stdin \
              | with_timeout "$RUN_TIMEOUT" "$BIN" $testname ) || true
        else
            ( cd "$OUT/run_work" && feed_stdin | "$BIN" $testname ) || true
        fi
        unset LLVM_PROFILE_FILE BB_COV_OUT BB_COV_QUIET
    done
    rm -rf "$OUT/run_work"

    # профили + экспорт + basic blocks для этой программы
    "$LLVM_PROFDATA" merge -sparse "$OUT/runs"/p${idx}_${bname}_t*.profraw \
        -o "$OUT/p${idx}_$bname.profdata" 2>/dev/null || true
    if [ -f "$OUT/p${idx}_$bname.profdata" ]; then
        llvm_cov_export_lcov "$BIN" "$OUT/p${idx}_$bname.profdata" \
            "$OUT/info/p${idx}_$bname.info"
    fi
    if [ -f "$BBRAW" ]; then
        python3 "$TOOLS_DIR/bb_cov_finalize.py" --raw "$BBRAW" \
            --binary "$BIN" --output "$OUT/bb/p${idx}_$bname.json" \
            --addr2line "$LLVM_ADDR2LINE" 2>&1 | tee -a "$TRANSCRIPT" || true
    else
        note "!! bb_cov_raw.json не создан для $bname (exec/незавершение?)"
        echo '{"sources": {}, "total": {"found": 0, "hit": 0}, "resolved_found": 0, "resolved_hit": 0}' \
            > "$OUT/bb/p${idx}_$bname.json"
    fi
    note ""
done

# --- объединение .info -------------------------------------------------------
INFOS=("$OUT"/info/*.info)
if [ ${#INFOS[@]} -eq 0 ]; then
    echo "ERROR: ни одна программа не собрана/не дала покрытие" >&2
    exit 1
fi
note "## объединение ${#INFOS[@]} .info в coverage.info (lcov -a)"
combine=( "$LCOV_DIR/bin/lcov" )
for f in "${INFOS[@]}"; do combine+=( -a "$f" ); done
combine+=( --rc lcov_branch_coverage=1 -o "$OUT/coverage.info" )
run "${combine[@]}"

# --- объединение bb_cov.json ------------------------------------------------
# Для каждого файла: один и тот же набор базовых блоков инструментируется во
# всех программах (в каждом бинарнике - вся библиотека). Поэтому берём
# found = максимум по программам (общее число блоков файла), а hit = максимум
# выполненных (блок выполнен, если он выполнен хотя бы в одной программе).
# Суммирование раздувало бы total числом программ и занижало BB-покрытие.
python3 - "$OUT/bb" "$OUT/bb_cov.json" <<'PYEOF'
import json, glob, os, sys
bbdir, out = sys.argv[1], sys.argv[2]
sources = {}
for p in sorted(glob.glob(os.path.join(bbdir, '*.json'))):
    try:
        d = json.load(open(p))
    except Exception:
        continue
    for f, v in d.get('sources', {}).items():
        s = sources.setdefault(f, {'found': 0, 'hit': 0})
        s['found'] = max(s['found'], v['found'])
        s['hit'] = max(s['hit'], v['hit'])
report = {
    'sources': sources,
    'total': {'found': sum(v['found'] for v in sources.values()),
              'hit': sum(v['hit'] for v in sources.values())},
}
json.dump(report, open(out, 'w'), indent=2, sort_keys=True)
PYEOF

INFO="$OUT/coverage.info"
BB_JSON="$OUT/bb_cov.json"

# --- genhtml по режиму -------------------------------------------------------
note "## genhtml (режим: $MODE)"
COMPAT="(не выполнялось в режиме $MODE)"
case "$MODE" in
    orig)
        run "$GENHTML_ORIG" "$INFO" --branch-coverage -o "$OUT/html_orig";;
    bb)
        run "$GENHTML" "$INFO" --bb-report "$BB_JSON" --branch-coverage \
            -o "$OUT/html_bb";;
    *)
        run "$GENHTML_ORIG" "$INFO" --branch-coverage -o "$OUT/html_orig"
        run "$GENHTML" "$INFO" --branch-coverage -o "$OUT/html_plain"
        if tree_diff_identical "$OUT/html_orig" "$OUT/html_plain"; then
            COMPAT="PASS: html_orig =~ html_plain (идентичны по содержимому)"
        else
            COMPAT="FAIL: отчёты различаются, см. $OUT/compat.diff"
            diff -r "$OUT/html_orig" "$OUT/html_plain" > "$OUT/compat.diff" 2>&1 || true
        fi
        note "result: $COMPAT"
        run "$GENHTML" "$INFO" --bb-report "$BB_JSON" --branch-coverage \
            -o "$OUT/html_bb";;
esac
note ""

# --- проверки ----------------------------------------------------------------
BB_HEADER="-"; HAS_BB="-"; FILES_BB="-"; DIRS_BB="-"
if [ -d "$OUT/html_bb" ]; then
    HAS_BB=$(grep -r -l '>Basic Block Coverage</td>' "$OUT/html_bb" \
             2>/dev/null | wc -l | tr -d ' ' || true)
    BB_HEADER=$(grep -A4 'headerItem">Basic Blocks:' "$OUT/html_bb/index.html" 2>/dev/null \
                | tr '\n' ' ' | sed -E 's/<[^>]+>/ /g' | tr -s ' ' || true)
    FILES_BB=$(grep -r -l "Basic Blocks:" "$OUT/html_bb" --include="*.gcov.html" \
               2>/dev/null | wc -l | tr -d ' ' || true)
    DIRS_BB=$(grep -r -l '>Basic Block Coverage</td>' "$OUT/html_bb" \
              --include="index.html" 2>/dev/null | wc -l | tr -d ' ' || true)
fi
[ "$HAS_BB" != "-" ] && note "Basic Block Coverage в html_bb: $HAS_BB (>0)"
[ -n "$BB_HEADER" ] && [ "$BB_HEADER" != "-" ] && note "header: $BB_HEADER"

# --- отчёт -------------------------------------------------------------------
{
    cat <<EOF
# Отчёт analyze.sh (multi) для репозитория *$NAME*

**Каталог:** \`$DIR\`
**Режим:** $MODE
**Дата:** $(date '+%Y-%m-%d %H:%M:%S')

Проанализировано программ: ${#mains[@]} (объединены в один отчёт).

Результаты:
| Проверка | Значение |
|---|---|
| Совместимость | $COMPAT |
| Вхождений "Basic Block Coverage" в html_bb | ${HAS_BB:--} (ожидается >0) |
| Страницы файлов | ${FILES_BB:--} |
| Индексные страницы | ${DIRS_BB:--} |
| Заголовок | ${BB_HEADER:--} |

Журнал: \`$TRANSCRIPT\`
Отчёт: \`$OUT/html_bb/index.html\` (если режим bb/all)
EOF
} > "$OUT/report.md"

echo "======================================================"
echo " Готово (режим: $MODE). Смотрите:"
echo "   $OUT/report.md"
echo "   $OUT/transcript.log"
echo "======================================================"