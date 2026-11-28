#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Сбор структурированных данных прогона syzkaller для последующего анализа.

Скрипт НЕ строит графики и не делает визуализацию: только CSV/JSON/Markdown.

Вход: каталог прогона results/runs/<run-id>/ со стандартными файлами:
    manager-bench.json   — минутные срезы всех статов syz-manager (-bench);
    manager.log          — консольный журнал (fallback, если bench нет);
    cover.jsonl          — покрытие по кадрам (/cover?jsonl=1);
    crashes/             — каталоги падений;
    run.env, sources.env — метаданные;
    metrics.txt, stats.html, manager.cfg, kernel.config — снимки.

Выход (в тот же каталог):
    timeseries.csv          — минута, approx_utc, executed, cover,
                              filtered_coverage, corpus, corpus_mlx4, crashes, ...
    manager_counter.csv     — executed/cover/crashes из журнала (если есть)
    coverage_mlx4.csv       — файл, функция, строка, попадания, PC
    coverage_by_file.csv    — по файлам mlx4: кадров, функций, строк в файле
    coverage_functions.csv  — покрытые функции mlx4
    crashes.csv             — id, заголовок, верхний кадр, файл:строка, репро
    manifest.json           — версии, окружение, хэши артефактов, время
    summary.md              — человекочитаемая сводка
    (опционально) <results-dir>/index.md — таблица всех прогонов

Зависимости: только стандартная библиотека Python 3.
"""

import argparse
import csv
import hashlib
import json
import os
import platform
import re
import shutil
import subprocess
import sys
from datetime import datetime, timezone

MLX4_PATH = "drivers/net/ethernet/mellanox/mlx4/"

PRIORITY_STATS = [
    "executed",
    "cover",
    "filtered coverage",
    "corpus",
    "corpus [mlx4]",
    "crashes",
    "crash types",
    "fuzzing",
    "uptime",
]


def utc_now():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def utc_from_ts(ts):
    try:
        return datetime.fromtimestamp(ts, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    except (OSError, OverflowError, ValueError):
        return ""


def norm(name):
    return re.sub(r"[^0-9a-zA-Z]+", "_", name).strip("_").lower()


def read_kv(path):
    data = {}
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                data[k.strip()] = v.strip()
    except OSError:
        pass
    return data


def sha256_file(path, limit=64 * 1024 * 1024):
    h = hashlib.sha256()
    size = 0
    try:
        with open(path, "rb") as f:
            while True:
                chunk = f.read(1024 * 1024)
                if not chunk:
                    break
                size += len(chunk)
                if size > limit:
                    return {"size": size, "sha256": "skipped(too large)"}
                h.update(chunk)
    except OSError as e:
        return {"error": str(e)}
    return {"size": size, "sha256": h.hexdigest()}


# ---------------------------------------------------------------- bench ---

def parse_bench(path):
    """-bench пишет json.MarshalIndent + \\n, т.е. НЕ jsonl, а поток объектов."""
    try:
        text = open(path, "r", encoding="utf-8", errors="replace").read()
    except OSError:
        return []
    dec = json.JSONDecoder()
    rows = []
    i = 0
    n = len(text)
    while i < n:
        while i < n and text[i] in " \t\r\n":
            i += 1
        if i >= n:
            break
        try:
            obj, end = dec.raw_decode(text, i)
        except ValueError:
            break
        if isinstance(obj, dict):
            rows.append(obj)
        i = end
    return rows


def write_timeseries(run_dir, bench_path, run_env):
    rows = parse_bench(bench_path)
    if not rows:
        return 0
    keys = set()
    for r in rows:
        keys.update(r.keys())
    ordered = [k for k in PRIORITY_STATS if k in keys]
    ordered += sorted(k for k in keys if k not in ordered)
    mtime = os.path.getmtime(bench_path)
    started = run_env.get("STARTED_AT", "")
    start_ts = None
    if started:
        try:
            start_ts = datetime.strptime(started, "%Y-%m-%dT%H:%M:%SZ").replace(
                tzinfo=timezone.utc).timestamp()
        except ValueError:
            start_ts = None
    out = os.path.join(run_dir, "timeseries.csv")
    with open(out, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["minute", "approx_utc"] + ordered)
        total = len(rows)
        for idx, r in enumerate(rows):
            if start_ts is not None:
                ts = start_ts + (idx + 1) * 60
            else:
                ts = mtime - (total - 1 - idx) * 60
            w.writerow([idx + 1, utc_from_ts(ts)] + [r.get(k, "") for k in ordered])
    return len(rows)


def write_manager_counter(run_dir, log_path):
    pat = re.compile(r"executed (\d+), cover (\d+), crashes (\d+)")
    rows = []
    try:
        with open(log_path, "r", encoding="utf-8", errors="replace") as f:
            for line in f:
                m = pat.search(line)
                if m:
                    rows.append(m.groups())
    except OSError:
        return 0
    if not rows:
        return 0
    out = os.path.join(run_dir, "manager_counter.csv")
    with open(out, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["sample", "executed", "cover", "crashes"])
        for i, (e, c, cr) in enumerate(rows):
            w.writerow([i + 1, e, c, cr])
    return len(rows)


# ------------------------------------------------------------- coverage ---

def load_cover(path):
    rows = []
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    rec = json.loads(line)
                except ValueError:
                    continue
                rows.append({
                    "file": rec.get("file_path") or rec.get("FilePath") or "",
                    "func": rec.get("func_name") or rec.get("FuncName") or "",
                    "start": int(rec.get("start_line") or rec.get("StartLine") or 0),
                    "end": int(rec.get("end_line") or rec.get("EndLine") or 0),
                    "hit": int(rec.get("hit_count") or rec.get("HitCount") or 0),
                    "pc": rec.get("pc") or rec.get("PC") or "",
                    "inline": bool(rec.get("inline") or rec.get("Inline") or False),
                })
    except OSError:
        return []
    return rows


def count_lines(path):
    try:
        with open(path, "rb") as f:
            return sum(1 for _ in f)
    except OSError:
        return 0


def mlx4_functions_total(vmlinux):
    """Все функции ядра с префиксом mlx4_ (t/T в таблице символов)."""
    if not vmlinux or not os.path.exists(vmlinux):
        return set()
    for tool in ("llvm-nm", "nm"):
        if not shutil.which(tool):
            continue
        try:
            res = subprocess.run([tool, "--defined-only", vmlinux],
                                 stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                 timeout=120, text=True)
        except (OSError, subprocess.SubprocessError):
            continue
        if res.returncode != 0:
            continue
        funcs = set()
        for line in res.stdout.splitlines():
            parts = line.split()
            if len(parts) < 3:
                continue
            if parts[1] in ("t", "T") and parts[2].startswith("mlx4_"):
                funcs.add(parts[2])
        if funcs:
            return funcs
    return set()


def write_coverage(run_dir, cover_path, kernel_src, vmlinux):
    rows = load_cover(cover_path)
    mlx4 = [r for r in rows if MLX4_PATH in r["file"]]

    with open(os.path.join(run_dir, "coverage_mlx4.csv"), "w",
              newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["file", "function", "start_line", "end_line", "hit_count", "pc", "inline"])
        for r in sorted(mlx4, key=lambda x: (x["file"], x["start"], x["func"])):
            w.writerow([r["file"], r["func"], r["start"], r["end"], r["hit"],
                        r["pc"], int(r["inline"])])

    by_file = {}
    funcs = {}
    for r in mlx4:
        d = by_file.setdefault(r["file"], {"frames": 0, "lines": set()})
        d["frames"] += 1
        d["lines"].add(r["start"])
        funcs.setdefault(r["func"], r["file"])

    with open(os.path.join(run_dir, "coverage_by_file.csv"), "w",
              newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["file", "frames", "unique_lines", "functions",
                    "file_total_lines", "frames_per_kloc"])
        for path in sorted(by_file):
            d = by_file[path]
            total_lines = 0
            if kernel_src:
                total_lines = count_lines(os.path.join(kernel_src, path))
            nfuncs = sum(1 for fn, fp in funcs.items() if fp == path)
            per_kloc = (d["frames"] * 1000.0 / total_lines) if total_lines else ""
            w.writerow([path, d["frames"], len(d["lines"]), nfuncs,
                        total_lines or "", round(per_kloc, 2) if per_kloc != "" else ""])

    with open(os.path.join(run_dir, "coverage_functions.csv"), "w",
              newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["function", "file"])
        for fn in sorted(funcs):
            w.writerow([fn, funcs[fn]])

    total_funcs = mlx4_functions_total(vmlinux)
    covered = set(funcs) & total_funcs if total_funcs else set(funcs)
    stats = {
        "frames": len(mlx4),
        "files": len(by_file),
        "functions_covered": len(covered),
        "functions_total": len(total_funcs),
        "pcs": len({r["pc"] for r in mlx4 if r["pc"]}),
    }
    if total_funcs:
        stats["functions_pct"] = round(100.0 * len(covered) / len(total_funcs), 2)
    return stats


# -------------------------------------------------------------- crashes ---

FRAME_RE = re.compile(r"([A-Za-z_][A-Za-z0-9_.]*\+0x[0-9a-fA-F]+/0x[0-9a-fA-F]+)")


def symbolize(vmlinux, kernel_src, frame, timeout=25):
    if not vmlinux or not kernel_src or not frame:
        return ""
    faddr2line = os.path.join(kernel_src, "scripts", "faddr2line")
    if not os.path.exists(faddr2line):
        return ""
    try:
        res = subprocess.run(["bash", faddr2line, vmlinux, frame],
                             stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                             timeout=timeout, text=True)
    except (OSError, subprocess.SubprocessError):
        return ""
    if res.returncode != 0:
        return ""
    first = res.stdout.strip().splitlines()
    return first[0].strip() if first else ""


def write_crashes(run_dir, crashes_dir, vmlinux, kernel_src, limit_symbolize=20):
    out = os.path.join(run_dir, "crashes.csv")
    rows = []
    if not os.path.isdir(crashes_dir):
        with open(out, "w", newline="", encoding="utf-8") as f:
            csv.writer(f).writerow(["id", "title", "top_frame", "source",
                                    "repro", "kasan", "warn", "first_seen_utc"])
        return 0

    dirs = sorted(
        (d for d in os.listdir(crashes_dir)
         if os.path.isdir(os.path.join(crashes_dir, d))),
        key=lambda d: os.path.getmtime(os.path.join(crashes_dir, d)),
    )
    for i, cid in enumerate(dirs):
        cdir = os.path.join(crashes_dir, cid)
        title = ""
        desc = os.path.join(cdir, "description")
        if os.path.exists(desc):
            title = open(desc, encoding="utf-8", errors="replace").read().strip().splitlines()[0]
        reports = sorted(
            os.path.join(cdir, n) for n in os.listdir(cdir)
            if n.startswith("report")
        )
        report = reports[0] if reports else ""
        text = ""
        if report:
            text = open(report, encoding="utf-8", errors="replace").read()
        m = FRAME_RE.search(text)
        frame = m.group(1) if m else ""
        source = symbolize(vmlinux, kernel_src, frame) if i < limit_symbolize else ""
        repro = "none"
        if os.path.exists(os.path.join(cdir, "repro.prog")):
            repro = "prog"
        elif os.path.exists(os.path.join(cdir, "repro.c")):
            repro = "c"
        rows.append({
            "id": cid,
            "title": title,
            "top_frame": frame,
            "source": source,
            "repro": repro,
            "kasan": int("KASAN" in text or "kasan" in text.lower()),
            "warn": int("WARNING" in text or "WARN" in text),
            "first_seen_utc": utc_from_ts(os.path.getmtime(cdir)),
        })
    with open(out, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=["id", "title", "top_frame", "source",
                                          "repro", "kasan", "warn", "first_seen_utc"])
        w.writeheader()
        w.writerows(rows)
    return len(rows)


# ------------------------------------------------------------- manifest ---

def read_os_release():
    data = read_kv("/etc/os-release")
    return data.get("PRETTY_NAME", "")


def host_info():
    info = {
        "platform": platform.platform(),
        "machine": platform.machine(),
        "python": platform.python_version(),
        "cpu_count": os.cpu_count(),
        "os_release": read_os_release(),
    }
    try:
        info["mem_total_kb"] = os.sysconf("SC_PHYS_PAGES") * os.sysconf("SC_PAGE_SIZE") // 1024
    except (ValueError, OSError, AttributeError):
        pass
    return info


def write_manifest(run_dir, run_env, sources_env, kernel_src, vmlinux):
    files = {}
    for name in ("manager.cfg", "kernel.config", "sources.env", "run.env",
                 "manager.log", "manager-bench.json", "stats.html",
                 "cover.jsonl", "metrics.txt", "corpus.db",
                 "syzlang_dev_mlx4.txt", "seeds.txt", "qemu.txt"):
        p = os.path.join(run_dir, name)
        if os.path.exists(p):
            files[name] = sha256_file(p)
    for csv_name in ("timeseries.csv", "coverage_mlx4.csv", "coverage_by_file.csv",
                     "coverage_functions.csv", "crashes.csv"):
        p = os.path.join(run_dir, csv_name)
        if os.path.exists(p):
            files[csv_name] = sha256_file(p)

    crashes_dir = os.path.join(run_dir, "crashes")
    crashes = 0
    if os.path.isdir(crashes_dir):
        crashes = sum(1 for d in os.listdir(crashes_dir)
                      if os.path.isdir(os.path.join(crashes_dir, d)))

    env_names = ("VMMEM", "VMCPU", "VMCOUNT", "PROCS", "REPRODUCE", "EVIL",
                 "MSIX", "QEMU_EXTRA_ARGS", "JOBS", "GOMEMLIMIT", "RUN_ID")
    env = {k: run_env.get(k, os.environ.get(k, "")) for k in env_names}

    manifest = {
        "generated_at": utc_now(),
        "run_id": run_env.get("RUN_ID", os.path.basename(run_dir.rstrip("/"))),
        "started_at": run_env.get("STARTED_AT", ""),
        "finished_at": run_env.get("FINISHED_AT", ""),
        "duration_sec": run_env.get("DURATION_SEC", ""),
        "host": host_info(),
        "versions": sources_env,
        "env": env,
        "qemu_args": run_env.get("QEMU_ARGS", ""),
        "kernel_src": kernel_src or "",
        "vmlinux": vmlinux or "",
        "crashes": crashes,
        "files": files,
    }
    with open(os.path.join(run_dir, "manifest.json"), "w", encoding="utf-8") as f:
        json.dump(manifest, f, indent=2, ensure_ascii=False)
        f.write("\n")
    return manifest


# -------------------------------------------------------------- summary ---

def latest_counters(run_dir, run_env):
    bench = os.path.join(run_dir, "manager-bench.json")
    rows = parse_bench(bench)
    if rows:
        last = rows[-1]
        first = rows[0]
        return last, first, rows
    # fallback: журнал
    log = os.path.join(run_dir, "manager.log")
    pat = re.compile(r"executed (\d+), cover (\d+), crashes (\d+)")
    found = []
    try:
        with open(log, "r", encoding="utf-8", errors="replace") as f:
            for line in f:
                m = pat.search(line)
                if m:
                    found.append({"executed": int(m.group(1)),
                                  "cover": int(m.group(2)),
                                  "crashes": int(m.group(3))})
    except OSError:
        pass
    if found:
        return found[-1], found[0], found
    return {}, {}, []


def write_summary(run_dir, run_env, sources_env, cov_stats, crash_count, manifest):
    last, first, rows = latest_counters(run_dir, run_env)
    crashes_csv = os.path.join(run_dir, "crashes.csv")
    crash_rows = []
    if os.path.exists(crashes_csv):
        with open(crashes_csv, encoding="utf-8", errors="replace") as f:
            crash_rows = list(csv.DictReader(f))

    lines = []
    add = lines.append
    add("# Результаты прогона syzkaller (focus: mlx4)")
    add("")
    add(f"- run id: `{run_env.get('RUN_ID', '')}`")
    add(f"- старт: `{run_env.get('STARTED_AT', '')}`")
    add(f"- конец: `{run_env.get('FINISHED_AT', '')}`")
    if run_env.get("DURATION_SEC"):
        add(f"- длительность: `{run_env['DURATION_SEC']}` c")
    add("")
    add("## Версии")
    for k in ("LINUX_VERSION", "QEMU_VERSION", "SYZKALLER_COMMIT", "HOST"):
        if sources_env.get(k):
            add(f"- {k}: `{sources_env[k]}`")
    add("")
    add("## Счётчики (последний минутный срез)")
    for key, label in (("executed", "executed"),
                       ("cover", "cover (PC после фильтра)"),
                       ("filtered coverage", "filtered coverage"),
                       ("corpus", "corpus"),
                       ("corpus [mlx4]", "corpus [mlx4]"),
                       ("crashes", "crashes")):
        if key in last:
            add(f"- {label}: **{last[key]}**")
    if first and last:
        d_exec = last.get("executed", 0) - first.get("executed", 0)
        d_cov = last.get("cover", 0) - first.get("cover", 0)
        add(f"- прирост за прогон: executed +{d_exec}, cover +{d_cov}")
    if rows:
        add(f"- минутных срезов: {len(rows)} (см. `timeseries.csv`)")
    add("")
    add("## Покрытие mlx4")
    add(f"- кадров (функция/строка): **{cov_stats.get('frames', 0)}**")
    add(f"- файлов: **{cov_stats.get('files', 0)}**")
    add(f"- уникальных функций в покрытии: **{cov_stats.get('functions_covered', 0)}**")
    if cov_stats.get("functions_total"):
        add(f"- всего функций `mlx4_*` в vmlinux: **{cov_stats['functions_total']}**")
        add(f"- доля покрытых функций: **{cov_stats.get('functions_pct', '')}%**"
            " (приблизительно: по таблице символов)")
    add(f"- уникальных PC: **{cov_stats.get('pcs', 0)}**")
    add("")
    add("Детализация: `coverage_mlx4.csv`, `coverage_by_file.csv`, `coverage_functions.csv`.")
    add("")
    add("## Падения")
    if not crash_rows:
        add("- падений не найдено")
    else:
        add(f"- всего: **{len(crash_rows)}** (см. `crashes.csv`)")
        add("")
        add("| id | заголовок | верхний кадр | файл:строка | репро |")
        add("|---|---|---|---|---|")
        for r in crash_rows:
            title = (r.get("title") or "").replace("|", "\\|")[:110]
            frame = (r.get("top_frame") or "").replace("|", "\\|")[:60]
            src = (r.get("source") or "").replace("|", "\\|")[:80]
            add(f"| `{r.get('id','')}` | {title} | `{frame}` | `{src}` | {r.get('repro','')} |")
    add("")
    add("## Артефакты")
    for name in sorted(manifest.get("files", {})):
        add(f"- `{name}`")
    add("")
    add("> Визуализация намеренно не строится: все данные — в CSV/JSON/Markdown.")
    add("")

    with open(os.path.join(run_dir, "summary.md"), "w", encoding="utf-8") as f:
        f.write("\n".join(lines))


# ---------------------------------------------------------------- index ---

def rebuild_index(results_dir):
    runs_dir = os.path.join(results_dir, "runs")
    if not os.path.isdir(runs_dir):
        return
    rows = []
    for rid in sorted(os.listdir(runs_dir), reverse=True):
        mpath = os.path.join(runs_dir, rid, "manifest.json")
        if not os.path.exists(mpath):
            continue
        try:
            m = json.load(open(mpath, encoding="utf-8"))
        except (OSError, ValueError):
            continue
        summary = os.path.join(runs_dir, rid, "summary.md")
        counters = {}
        bench = os.path.join(runs_dir, rid, "manager-bench.json")
        brows = parse_bench(bench)
        if brows:
            counters = brows[-1]
        elif os.path.exists(summary):
            txt = open(summary, encoding="utf-8", errors="replace").read()
            for key in ("executed", "filtered coverage", "cover", "crashes"):
                m2 = re.search(r"^- %s[^:]*: \*\*(\d+)\*\*" % re.escape(key), txt, re.M)
                if m2:
                    counters[key] = int(m2.group(1))
        rows.append({
            "id": rid,
            "started": m.get("started_at", ""),
            "duration": m.get("duration_sec", ""),
            "executed": counters.get("executed", ""),
            "cover": counters.get("cover", ""),
            "filtered": counters.get("filtered coverage", ""),
            "crashes": m.get("crashes", ""),
        })
    lines = ["# Прогоны", "",
             "| run id | старт | длительность, с | executed | cover | filtered coverage | crashes |",
             "|---|---|---|---|---|---|---|"]
    for r in rows:
        lines.append("| `{id}` | {started} | {duration} | {executed} | {cover} | {filtered} | {crashes} |".
                     format(**r))
    lines.append("")
    lines.append("Подробности — в `runs/<run id>/summary.md` и CSV.")
    lines.append("")
    with open(os.path.join(results_dir, "index.md"), "w", encoding="utf-8") as f:
        f.write("\n".join(lines))


# ----------------------------------------------------------------- main ---

def main():
    ap = argparse.ArgumentParser(description="Сбор данных прогона syzkaller (без визуализации)")
    ap.add_argument("--run-dir", required=True, help="каталог прогона results/runs/<id>")
    ap.add_argument("--kernel-src", default="", help="дерево ядра (для scripts/faddr2line и строк)")
    ap.add_argument("--vmlinux", default="", help="vmlinux (для символов и faddr2line)")
    ap.add_argument("--results-dir", default="", help="каталог results для index.md")
    args = ap.parse_args()

    run_dir = os.path.abspath(args.run_dir)
    if not os.path.isdir(run_dir):
        sys.exit("нет каталога прогона: %s" % run_dir)

    run_env = read_kv(os.path.join(run_dir, "run.env"))
    sources_env = read_kv(os.path.join(run_dir, "sources.env"))

    bench = os.path.join(run_dir, "manager-bench.json")
    ts_rows = write_timeseries(run_dir, bench, run_env) if os.path.exists(bench) else 0
    log_rows = write_manager_counter(run_dir, os.path.join(run_dir, "manager.log"))

    cov_path = os.path.join(run_dir, "cover.jsonl")
    cov_stats = write_coverage(run_dir, cov_path, args.kernel_src, args.vmlinux) \
        if os.path.exists(cov_path) else {"frames": 0, "files": 0,
                                          "functions_covered": 0, "functions_total": 0,
                                          "pcs": 0}

    crash_count = write_crashes(run_dir, os.path.join(run_dir, "crashes"),
                                args.vmlinux, args.kernel_src)

    manifest = write_manifest(run_dir, run_env, sources_env, args.kernel_src, args.vmlinux)
    write_summary(run_dir, run_env, sources_env, cov_stats, crash_count, manifest)

    if args.results_dir:
        rebuild_index(os.path.abspath(args.results_dir))

    print("timeseries: %d строк, manager_counter: %d, coverage: %d кадров, crashes: %d"
          % (ts_rows, log_rows, cov_stats.get("frames", 0), crash_count))
    print("summary:", os.path.join(run_dir, "summary.md"))


if __name__ == "__main__":
    main()
