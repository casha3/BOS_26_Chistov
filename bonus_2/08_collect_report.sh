#!/usr/bin/env bash
# Фаза 8: сбор данных прогона в results/runs/<run-id>/ и их структурирование.
#
# Собирается:
#   manager.log, manager.cfg, kernel.config, sources.env, run.env
#   manager-bench.json   — минутные срезы счётчиков (-bench из фазы 7)
#   metrics.txt          — снимок /metrics (Prometheus)
#   stats.html           — снимок /stats
#   cover.jsonl          — покрытие по кадрам (/cover?jsonl=1)
#   crashes/             — падения (описания, логи, отчёты, репро)
#   corpus.db            — корпус на момент сбора
#   syzlang_dev_mlx4.txt, seeds.txt — использованные описания/корпус
#
# Затем tools/analyze.py строит CSV/JSON/Markdown (без визуализации):
#   timeseries.csv, manager_counter.csv,
#   coverage_mlx4.csv, coverage_by_file.csv, coverage_functions.csv,
#   crashes.csv, manifest.json, summary.md
#
# Дополнительно обновляются results/latest и results/index.md.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")" && pwd)
. "$ROOT/tools/lib_common.sh"

phase 8 "Сбор данных прогона"

need python3
mkdirs

HTTP="${HTTP:-http://127.0.0.1:56741}"
RUN_ENV="$WORK/run.env"

kv() {
    local key="$1"
    [ -f "$RUN_ENV" ] || return 0
    sed -n "s/^${key}=//p" "$RUN_ENV" | head -n 1
}

RUN_ID="${RUN_ID:-$(kv RUN_ID)}"
if [ -z "$RUN_ID" ]; then
    RUN_ID=$(python3 -c 'from datetime import datetime,timezone;print(datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S"))')
fi

RUN_DIR="$RESULTS/runs/$RUN_ID"
mkdir -p "$RUN_DIR"
log "каталог прогона: $RUN_DIR"

# --- копирование артефактов ------------------------------------------
copy_if() {
    local src="$1" dst="$2"
    if [ -e "$src" ]; then
        cp -R "$src" "$dst"
        log "скопировано: $dst"
    fi
}

copy_if "$MANAGER_LOG" "$RUN_DIR/manager.log"
copy_if "$MANAGER_CFG" "$RUN_DIR/manager.cfg"
copy_if "$WORK/kernel.config" "$RUN_DIR/kernel.config"
copy_if "$WORK/sources.env" "$RUN_DIR/sources.env"
copy_if "$WORK/run.env" "$RUN_DIR/run.env"
copy_if "$ROOT/syzlang/dev_mlx4.txt" "$RUN_DIR/syzlang_dev_mlx4.txt"
copy_if "$MANAGER_WORKDIR/corpus.db" "$RUN_DIR/corpus.db"

if [ -x "$QEMU_BIN" ]; then
    {
        "$QEMU_BIN" --version 2>&1 | head -n 2
        "$QEMU_BIN" -device help 2>/dev/null | grep '"mlx4"' || true
    } > "$RUN_DIR/qemu.txt"
    log "qemu.txt"
fi

if [ -d "$ROOT/syzlang/seeds" ]; then
    ( cd "$ROOT/syzlang/seeds" && ls -1 *.prog 2>/dev/null ) > "$RUN_DIR/seeds.txt" || true
fi

BENCH_FILE="$(kv BENCH_FILE)"
if [ -n "$BENCH_FILE" ] && [ ! -f "$BENCH_FILE" ]; then
    warn "файл bench из run.env не найден: $BENCH_FILE"
    BENCH_FILE=""
fi
if [ -z "$BENCH_FILE" ]; then
    BENCH_FILE=$(ls -1t "$WORK"/manager-bench-*.json 2>/dev/null | head -n 1 || true)
fi
if [ -n "$BENCH_FILE" ] && [ -f "$BENCH_FILE" ]; then
    cp "$BENCH_FILE" "$RUN_DIR/manager-bench.json"
    log "bench: $RUN_DIR/manager-bench.json"
else
    warn "нет файла -bench (менеджер не запускался или запускался без фазы 7)"
fi

if [ -d "$MANAGER_WORKDIR/crashes" ]; then
    rm -rf "$RUN_DIR/crashes"
    mkdir -p "$RUN_DIR/crashes"
    cp -R "$MANAGER_WORKDIR/crashes/." "$RUN_DIR/crashes/" 2>/dev/null || true
    N=$(find "$RUN_DIR/crashes" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
    log "падений: $N"
fi

# --- снимки с живого менеджера ---------------------------------------
if have curl; then
    if curl -fsS --max-time 10 "$HTTP/stats" -o "$RUN_DIR/stats.html" 2>/dev/null; then
        log "stats.html"
    else
        warn "менеджер не отвечает на $HTTP/stats (уже остановлен?)"
    fi
    if curl -fsS --max-time 20 "$HTTP/metrics" -o "$RUN_DIR/metrics.txt" 2>/dev/null; then
        log "metrics.txt"
    else
        warn "нет /metrics (менеджер остановлен?)"
    fi
    if curl -fsS --max-time 60 "$HTTP/cover?jsonl=1" -o "$RUN_DIR/cover.jsonl" 2>/dev/null; then
        log "cover.jsonl"
    else
        warn "нет покрытия (/cover?jsonl=1): нужен работающий менеджер"
    fi
fi

# --- финализация run.env ---------------------------------------------
# Если прогон уже останавливали (07/stop), сохраняем его FINISHED_AT и
# длительность, а не время сбора отчёта.
FINISHED_AT="$(kv FINISHED_AT)"
DURATION="$(kv DURATION_SEC)"
if [ -f "$RUN_DIR/run.env" ]; then
    if [ -z "$FINISHED_AT" ]; then
        FINISHED_AT=$(python3 -c 'from datetime import datetime,timezone;print(datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))')
    fi
    if [ -z "$DURATION" ] && [ -n "$(kv START_EPOCH)" ]; then
        DURATION=$(( $(date +%s) - $(kv START_EPOCH) ))
    fi
    python3 - "$RUN_DIR/run.env" "$FINISHED_AT" "$DURATION" <<'PY'
import sys
path, finished, duration = sys.argv[1], sys.argv[2], sys.argv[3]
lines, seen = [], set()
for line in open(path, encoding="utf-8"):
    line = line.rstrip("\n")
    if line.startswith("FINISHED_AT="):
        line = "FINISHED_AT=" + finished
        seen.add("FINISHED_AT")
    elif line.startswith("DURATION_SEC="):
        line = "DURATION_SEC=" + (duration or line.split("=", 1)[1])
        seen.add("DURATION_SEC")
    lines.append(line)
if "FINISHED_AT" not in seen:
    lines.append("FINISHED_AT=" + finished)
if "DURATION_SEC" not in seen:
    lines.append("DURATION_SEC=" + duration)
open(path, "w", encoding="utf-8").write("\n".join(lines) + "\n")
PY
else
    {
        echo "RUN_ID=$RUN_ID"
        echo "FINISHED_AT=$FINISHED_AT"
    } > "$RUN_DIR/run.env"
fi

# --- структурирование -------------------------------------------------
KERNEL_SRC_ARG=""
VMLINUX_ARG=""
[ -d "$LINUX_SRC" ] && KERNEL_SRC_ARG="--kernel-src $LINUX_SRC"
[ -f "$KERNEL_VMLINUX" ] && VMLINUX_ARG="--vmlinux $KERNEL_VMLINUX"

# shellcheck disable=SC2086
if ! python3 "$ROOT/tools/analyze.py" \
        --run-dir "$RUN_DIR" --results-dir "$RESULTS" \
        $KERNEL_SRC_ARG $VMLINUX_ARG; then
    die "tools/analyze.py завершился с ошибкой"
fi

if [ -f "$RESULTS/index.md" ]; then
    log "индекс прогонов: results/index.md"
fi

rm -f "$RESULTS/latest"
ln -sfn "runs/$RUN_ID" "$RESULTS/latest"
log "последний прогон: results/latest -> runs/$RUN_ID"

if [ -f "$RUN_DIR/summary.md" ]; then
    cp "$RUN_DIR/summary.md" "$RESULTS/summary.md"
    log "сводка: results/summary.md"
fi

success "данные прогона собраны в results/runs/$RUN_ID/"
log "  summary.md, timeseries.csv, coverage_*.csv, crashes.csv, manifest.json"
[ -d "$LINUX_SRC" ] || warn "анализ выполнен без дерева ядра: нет строк в файлах и символизации стеков"
