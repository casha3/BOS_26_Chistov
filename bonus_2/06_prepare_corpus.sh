#!/usr/bin/env bash
# Фаза 6: входной корпус -> work/manager/corpus.db
#
# syz-db pack заодно проверяет, что все .prog-файлы корректно разбираются
# вместе с нашими syzlang-описаниями (dev_mlx4.txt).
set -euo pipefail

ROOT=$(cd "$(dirname "$0")" && pwd)
. "$ROOT/tools/lib_common.sh"

phase 6 "Подготовка корпуса (corpus.db)"

need python3
need_file "$SYZ_SRC/sys/linux/dev_mlx4.txt" "bash 05_build_syzkaller.sh"
need_file "$ROOT/syzlang/seeds" "повреждён репозиторий"

mkdirs
rm -f "$MANAGER_WORKDIR/corpus.db"

SYZ_DB="$SYZ_SRC/bin/syz-db"

# --- описания и инструмент -------------------------------------------
if [ ! -f "$SYZ_SRC/sys/gen/linux_amd64.gob.flate" ] || [ ! -f "$SYZ_SRC/.descriptions" ]; then
    if have go; then
        log "генерирую описания (make descriptions)"
        ( cd "$SYZ_SRC" && make TARGETOS=linux TARGETARCH=amd64 descriptions ) \
            >"$LOGS/syzkaller_descriptions.log" 2>&1 \
            || die "make descriptions (журнал: $LOGS/syzkaller_descriptions.log)"
    else
        die "нет сгенерированных описаний и нет Go: выполните 05_build_syzkaller.sh на этой машине"
    fi
fi

# syz-db должен быть собран ПОСЛЕ генерации описаний (иначе target пуст).
if have go; then
    log "собираю bin/syz-db (с актуальными описаниями)"
    ( cd "$SYZ_SRC" && go build -o bin/syz-db ./tools/syz-db ) \
        >"$LOGS/syzkaller_syzdb.log" 2>&1 \
        || die "не удалось собрать syz-db (журнал: $LOGS/syzkaller_syzdb.log)"
fi
[ -x "$SYZ_DB" ] || die "нет $SYZ_DB: соберите syzkaller (фаза 5)"

log "проверяю описания и упаковываю корпус: syz-db pack"
if ! "$SYZ_DB" -os linux -arch amd64 pack "$ROOT/syzlang/seeds" \
        "$MANAGER_WORKDIR/corpus.db" >"$LOGS/corpus_pack.log" 2>&1; then
    tail -n 40 "$LOGS/corpus_pack.log" >&2
    die "syz-db pack не смог разобрать корпус/описания (журнал: $LOGS/corpus_pack.log)"
fi

COUNT=$(find "$ROOT/syzlang/seeds" -name '*.prog' | wc -l | tr -d ' ')
SIZE=$(du -h "$MANAGER_WORKDIR/corpus.db" | cut -f1)
log "seed-программ: $COUNT"
log "corpus.db: $MANAGER_WORKDIR/corpus.db ($SIZE)"

success "корпус готов"
next_step "bash 07_run_manager.sh   (только Linux)"
