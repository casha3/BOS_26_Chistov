#!/usr/bin/env bash
# Фаза 5: сборка syzkaller и подключение собственных syzlang-описаний.
#
# На Linux собирается всё (syz-manager + syz-executor для linux/amd64).
# На macOS собираются host-инструменты (syz-manager, syz-db, syz-prog2c):
# это позволяет проверить описания и корпус, но полноценный прогон — на Linux.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")" && pwd)
. "$ROOT/tools/lib_common.sh"

phase 5 "Сборка syzkaller"

need git
need_file "$SYZ_SRC/Makefile" "bash 01_fetch_sources.sh"

if ! have go; then
    die "нет Go. Установите: macOS — brew install go; Rocky — sudo dnf install golang"
fi

# --- syzlang: добавляем свой файл описаний ----------------------------
cp "$ROOT/syzlang/dev_mlx4.txt" "$SYZ_SRC/sys/linux/dev_mlx4.txt"
log "описания установлены: sys/linux/dev_mlx4.txt"

cd "$SYZ_SRC"

if [ "$HOST_OS" = "Linux" ]; then
    log "make TARGETOS=linux TARGETARCH=amd64 -j$JOBS (host + executor)"
    if ! run_logged "$LOGS/syzkaller_build.log" \
            make TARGETOS=linux TARGETARCH=amd64 -j"$JOBS"; then
        die "сборка syzkaller (журнал: $LOGS/syzkaller_build.log)"
    fi
    need_file "$SYZ_SRC/bin/syz-manager" "make syzkaller"
    need_file "$SYZ_SRC/bin/syz-executor" "make syzkaller"
    need_file "$SYZ_SRC/bin/syz-execprog" "make syzkaller"
    log "bin/syz-manager, bin/syz-executor, bin/syz-execprog — готовы"
else
    log "macOS: собираю host-инструменты (make host)"
    if ! run_logged "$LOGS/syzkaller_build.log" make host TARGETOS=linux TARGETARCH=amd64 -j"$JOBS"; then
        die "сборка host-инструментов syzkaller (журнал: $LOGS/syzkaller_build.log)"
    fi
    need_file "$SYZ_SRC/bin/syz-manager" "make host"
    warn "syz-executor для linux/amd64 на macOS не собирается (нужен ELF-кросс-компилятор)."
    warn "Полный прогон фаззера выполняйте на Rocky — там фаза 5 собирает всё."
fi

# syz-db нужен для упаковки корпуса; на всякий случай собираем отдельно.
if [ ! -x "$SYZ_SRC/bin/syz-db" ]; then
    log "собираю bin/syz-db"
    ( cd "$SYZ_SRC" && go build -o bin/syz-db ./tools/syz-db ) \
        >"$LOGS/syzkaller_syzdb.log" 2>&1 \
        || die "не удалось собрать syz-db (журнал: $LOGS/syzkaller_syzdb.log)"
fi

SYZ_COMMIT=$(git -C "$SYZ_SRC" rev-parse --short HEAD 2>/dev/null || echo unknown)
log "syzkaller: $SYZ_COMMIT"

success "syzkaller готов"
next_step "bash 06_prepare_corpus.sh"
