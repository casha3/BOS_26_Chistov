#!/usr/bin/env bash
#
# test_box.sh - протестировать утилиту genhtml+BasicBlockCoverage на
# выбранном подпроекте репозитория project-box.
#
# Репозиторий клонируется при первом запуске в test_projects/project-box.
#
# Usage:
#   bash test_box.sh <подпроект> [доп. опции run_project.sh...]
#
# Примеры:
#   bash test_box.sh lexer
#   bash test_box.sh sha512
#   bash test_box.sh compiler
#   bash test_box.sh notes
#   bash test_box.sh --list            # список поддерживаемых подпроектов
#
# Каждый подпроект заранее описан (main/sources/include/stdin/libs/tests),
# чтобы "на выбор" можно было протестировать любой из них одной командой.
#

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
BOX_DIR="$HERE/test_projects/project-box"
OUTBASE="$HERE/output"

# серверы/игры не завершаются сами - по умолчанию ограничиваем время прогона
export RUN_TIMEOUT="${RUN_TIMEOUT:-20}"

# --- режим отчёта: флаги перед именем подпроекта --------------------------
MODE="all"
while [ $# -gt 0 ]; do
    case "$1" in
        --orig)        MODE="orig"; shift ;;
        --bb)          MODE="bb";   shift ;;
        --mode=*)      MODE="${1#--mode=}"; shift ;;
        --mode)        MODE="${2:-all}"; shift 2 ;;
        *)             break ;;
    esac
done
case "$MODE" in orig|bb|all) ;; *) echo "ERROR: --mode должен быть orig|bb|all" >&2; exit 2 ;; esac

# --- клонирование при необходимости -------------------------------------
if [ ! -d "$BOX_DIR/.git" ]; then
    echo "==> Клонирую project-box"
    mkdir -p "$HERE/test_projects"
    git clone --depth 1 https://github.com/TrisH0x2A/project-box "$BOX_DIR"
fi

# --- описание подпроектов ------------------------------------------------
# переменные: SRC (main), SOURCES, INCLUDE, STDIN, LIBS, TESTS
run_lexer()    { run generic lexical-analyser --main lexer.c; }
run_sha512()   { run generic SHA-512          --main main.c --stdin "hello\n8\n"; }
run_compiler() { run generic arithmetic-compiler \
                    --main src/main.c \
                    --sources "src/tokenizer.c src/parser.c src/assembly.c" \
                    --include "-I$BOX_DIR/arithmetic-compiler/include" \
                    --stdin "2+3*4\n10-2-3\n"; }
run_notes()    { run generic "Notes Manager" --name box_notes \
                    --main main.c --sources "db.c" --libs "-lsqlite3" \
                    --tests help --tests list --tests "add Hello World" \
                    --tests list --tests "view 1"; }
run_shortener(){ run generic url-shortener \
                    --main shortener.c --libs "-lsqlite3" \
                    --stdin "shorten https://example.com\nquit\n"; }
run_ping()     { run generic ping --main ping.c --tests "localhost"; }
run_scanner()  { run generic port-scanner --main scanner.c --tests "localhost 1 10"; }
run_http()     { run generic http-server --main server.c --stdin "\n"; }
run_tcp()      { run generic tcp-server --main server.c --stdin "\n"; }
run_udp()      { run generic udp-server-client --main server.c --stdin "\n"; }
run_asteroid() { run generic asteroid-game \
                    --main game.c \
                    --stdin "a d a d a a d d a d"; }
run_chat()     { run generic chat-system --main server.c --libs "-pthread"; }
run_ftp()      { run generic ftp \
                    --main src/server.c \
                    --sources "src/file_ops.c src/protocol.c" \
                    --include "-I$BOX_DIR/ftp/include" \
                    --libs "-pthread"; }
run_tictactoe(){ run generic tic-tac-toe \
                    --main src/server.c \
                    --include "-I$BOX_DIR/tic-tac-toe/include" \
                    --libs "-pthread"; }
run_qr()       { local hbp; hbp="$(brew --prefix 2>/dev/null || echo /opt/homebrew)"; \
                 run generic "QR Generator" --name box_qr \
                    --main main.c \
                    --sources "display.c png_writer.c" \
                    --include "-I$hbp/include" \
                    --libs "-L$hbp/lib -lqrencode -lpng" \
                    --tests "https://example.com" --tests "https://github.com out.png"; }

ZLIB_LIBS="adler32 compress crc32 deflate gzclose gzlib gzread gzwrite infback inffast inflate inftrees trees uncompr zutil"

run_zlib() {
    local ZDIR
    # пользуемся репозиторием пользователя, если он скачан в projects/zlib
    if [ -d "$HERE/projects/zlib/.git" ]; then
        ZDIR="$HERE/projects/zlib"
    else
        ZDIR="$HERE/test_projects/zlib"
        if [ ! -d "$ZDIR/.git" ]; then
            echo "==> Cloning zlib (madler/zlib)"
            mkdir -p "$HERE/test_projects"
            git clone --depth 1 https://github.com/madler/zlib "$ZDIR"
        fi
    fi
    # анализируем собственные исполняемые программы zlib (test/, examples/)
    echo "==> Анализ репозитория zlib (без добавленных файлов)"
    bash "$HERE/analyze.sh" "$ZDIR" --name box_zlib --mode "$MODE"
}

run_openssl() {
    local ODIR="$HERE/test_projects/openssl"
    if [ ! -d "$ODIR/.git" ]; then
        echo "==> Cloning openssl (openssl/openssl)"
        mkdir -p "$HERE/test_projects"
        git clone --depth 1 https://github.com/openssl/openssl "$ODIR"
    fi
    # инструментированная сборка libcrypto (один раз)
    if [ ! -f "$ODIR/libcrypto.a" ] || [ -f "$ODIR/.bbcov_rebuild" ]; then
        # таргет ./Configure выбирается по ОС и архитектуре
        local target
        case "$(uname -s):$(uname -m)" in
            Darwin:arm64)   target=darwin64-arm64-cc ;;
            Darwin:x86_64)  target=darwin64-x86_64-cc ;;
            Linux:x86_64)   target=linux-x86_64 ;;
            Linux:aarch64)  target=linux-aarch64 ;;
            *) echo "ERROR: неподдерживаемая платформа: $(uname -s) $(uname -m)" >&2; exit 1 ;;
        esac
        echo "==> Configure ($target no-shared, инструментирование)"
        ( cd "$ODIR" && ./Configure "$target" no-shared \
              -O0 -g \
              -fprofile-instr-generate \
              -fcoverage-mapping \
              -fsanitize-coverage=bb,no-prune,inline-bool-flag,pc-table \
              > configure.log 2>&1 ) || { echo "Configure failed:" >&2; tail -30 "$ODIR/configure.log" >&2; exit 1; }
        echo "==> make build_libs (может занять несколько минут)"
        ( cd "$ODIR" && make -j8 build_libs > build.log 2>&1 ) \
            || { echo "make failed:" >&2; tail -40 "$ODIR/build.log" >&2; exit 1; }
        rm -f "$ODIR/.bbcov_rebuild"
    fi
    [ -f "$ODIR/libcrypto.a" ] || { echo "ERROR: libcrypto.a не собран" >&2; exit 1; }
    # анализируем СОБСТВЕННУЮ программу репозитория: apps/openssl.c
    echo "==> Анализ собственной программы openssl (apps/openssl.c)"
    bash "$HERE/run_project.sh" "$ODIR/apps" --name box_openssl --mode "$MODE" \
        --include "-I$ODIR/include" \
        --libs "$ODIR/libcrypto.a -lpthread -lm" \
        --tests version --tests "list -cipher-algorithms"
}

# --- обёртка: вызов run_project.sh ---------------------------------------
run() {
    # $1 = generic, $2 = подкаталог, остальное = опции
    local sub="$2"; shift 2
    local dir="$BOX_DIR/$sub"
    local safe work
    [ -d "$dir" ] || { echo "ERROR: подкаталог не найден: $sub" >&2; exit 1; }
    safe="$(printf '%s' "$sub" | tr ' ' '_')"
    # Каталоги с пробелом в имени копируем во временную папку без пробелов
    # (пути с пробелами ломают построение списка исходников).
    work="$dir"
    if [[ "$sub" == *" "* ]]; then
        work="$BOX_DIR/../.box_work/$safe"
        mkdir -p "$(dirname "$work")"
        rm -rf "$work"
        cp -R "$dir" "$work"
    fi
    bash "$HERE/run_project.sh" "$work" --name "box_$safe" --mode "$MODE" "$@"
}

# --- выбор подпроекта ----------------------------------------------------
case "${1:-}" in
    --list|-l)      echo "Доступные подпроекты:"; sed -n 's/^run_\(.*\)() *{.*/\1/p' "$0" | sort -u; exit 0 ;;
    lexer)          run_lexer ;;
    sha512)         run_sha512 ;;
    compiler)       run_compiler ;;
    notes)          run_notes ;;
    shortener)      run_shortener ;;
    ping)           run_ping ;;
    scanner)        run_scanner ;;
    http)           run_http ;;
    tcp)            run_tcp ;;
    udp)            run_udp ;;
    asteroid)       run_asteroid ;;
    chat)           run_chat ;;
    ftp)            run_ftp ;;
    tictactoe)      run_tictactoe ;;
    qr)             run_qr ;;
    zlib)           run_zlib ;;
    openssl)        run_openssl ;;
    "")
        echo "использование: bash test_box.sh [--orig|--bb|--mode=M] <подпроект> [опции]"
        echo "  --orig  - только оригинальный genhtml (без Basic Blocks)"
        echo "  --bb    - только патченный genhtml с --bb-report (Basic Blocks)"
        echo "  (по умолчанию: полный прогон: оригинал + совместимость + BB)"
        echo "подпроекты: lexer sha512 compiler notes shortener ping scanner"
        echo "            http tcp udp asteroid chat ftp tictactoe qr"
        echo "            zlib openssl"
        echo "  или  bash test_box.sh --list"
        exit 2
        ;;
    *)
        echo "ERROR: неизвестный подпроект '$1'" >&2
        echo "подпроекты: lexer sha512 compiler notes shortener ping scanner" >&2
        echo "            http tcp udp asteroid chat ftp tictactoe qr zlib openssl" >&2
        exit 2
        ;;
esac