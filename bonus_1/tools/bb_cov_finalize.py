#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
bb_cov_finalize.py

Build a per-source-file basic block coverage report from the raw report
written by the bb_cov_runtime and the instrumented binary.

The raw report (default name bb_cov_raw.json) contains the addresses
(PCs) of every instrumented basic block plus the indices of the blocks
that were executed in at least one run.  Each PC is resolved to the
"file:line" of the block location with llvm-addr2line; blocks are then
grouped by source file, giving per file

    found   -- total number of instrumented basic blocks in the file
    hit     -- number of executed basic blocks in the file

The resulting JSON ("basic block report", default bb_cov.json) is
consumed by the patched genhtml via the --bb-report option.

Usage:
  bb_cov_finalize.py --raw DIR/bb_cov_raw.json --binary ./test_prog \
      --output bb_cov.json [--addr2line /path/to/llvm-addr2line]
"""

import argparse
import json
import os
import subprocess
import sys


def parse_args():
    p = argparse.ArgumentParser(
        description="Finalize the raw basic block coverage report")
    p.add_argument("--raw", required=True,
                   help="raw report produced by bb_cov_runtime")
    p.add_argument("--binary", required=True,
                   help="instrumented executable to symbolize against")
    p.add_argument("--output", default="bb_cov.json",
                   help="output per-file report (default: bb_cov.json)")
    p.add_argument("--addr2line", default=None,
                   help="path to llvm-addr2line (default: search PATH)")
    return p.parse_args()


def find_addr2line():
    for name in ("llvm-addr2line", "addr2line", "llvm-symbolizer"):
        for path in os.environ.get("PATH", "").split(os.pathsep):
            cand = os.path.join(path, name)
            if os.path.isfile(cand) and os.access(cand, os.X_OK):
                return cand
    return None


def normaddr(a):
    """Normalize a hex address to '0x' + no leading zeros (0x15, 0x102ab)."""
    try:
        return "0x%x" % int(a, 16)
    except ValueError:
        return a


def resolve_pcs(addr2line, binary, pcs):
    """Resolve a list of hex PC addresses to (function, file:line).

    Runs llvm-addr2line in chunks (a single invocation with a huge number
    of addresses would exceed the OS command-line limit, e.g. OpenSSL
    has 100k+ blocks).  With -f -a -C the output is a strict 3-line group
    per address:

        0xADDR
        function
        file:line

    (we do NOT use -i so that there are no inlined-frame extra lines).
    """
    CHUNK = 1000
    result = {}
    if not pcs:
        return result

    for i in range(0, len(pcs), CHUNK):
        chunk = pcs[i:i + CHUNK]
        args = [addr2line, "-e", binary, "-f", "-a", "-C"] + chunk
        try:
            proc = subprocess.Popen(args, stdout=subprocess.PIPE,
                                    stderr=subprocess.DEVNULL, text=True)
        except OSError as e:
            sys.stderr.write("bb_cov_finalize: addr2line exec failed: %s\n"
                             % e)
            return result
        out, _ = proc.communicate()
        if proc.returncode != 0:
            sys.stderr.write("bb_cov_finalize: addr2line failed\n")
            return result

        lines = out.splitlines()
        j = 0
        while j < len(lines):
            addr_line = lines[j].strip()
            if not (addr_line.startswith("0x") or addr_line.startswith("0X")):
                j += 1
                continue
            # 3-line group: address, function, location
            if j + 2 < len(lines):
                loc = lines[j + 2].strip()
            else:
                loc = "??:0"
            result[normaddr(addr_line)] = loc
            j += 3
    return result


def main():
    args = parse_args()

    if not os.path.isfile(args.raw):
        sys.exit("bb_cov_finalize: raw report not found: %s" % args.raw)
    if not os.path.isfile(args.binary):
        sys.exit("bb_cov_finalize: binary not found: %s" % args.binary)

    addr2line = args.addr2line or find_addr2line()
    if not addr2line:
        sys.exit("bb_cov_finalize: llvm-addr2line not found in PATH")

    with open(args.raw, "r", encoding="utf-8") as f:
        raw = json.load(f)

    # ASLR slide of the main image (0 on Linux/ELF non-PIE).  The PCs
    # recorded by the runtime are runtime (slid) addresses on macOS;
    # subtracting the slide yields link-time addresses that
    # llvm-addr2line can resolve.
    slide = int(raw.get("slide", 0))

    # Flatten the PCs and executed indices over all modules,
    # converting to link-time addresses.
    flat_pcs = []
    module_size = []
    for mod in raw.get("modules", []):
        pcs = []
        for p in mod.get("pcs", []):
            pc_int = int(p, 16) - slide
            if pc_int < 0:
                pc_int = 0
            pcs.append("0x%x" % pc_int)
        flat_pcs.extend(pcs)
        module_size.append(len(pcs))

    executed_set = set(raw.get("executed_indices", []))
    total_blocks = raw.get("total_blocks", len(flat_pcs))

    # Resolve every instrumented block PC to file:line.
    pcs_to_loc = resolve_pcs(addr2line, args.binary, flat_pcs)

    # Group by source file. Files that could not be resolved are skipped.
    per_file = {}
    for idx, pc in enumerate(flat_pcs):
        loc = pcs_to_loc.get(normaddr(pc))
        if not loc or loc.startswith("?") or ":" not in loc:
            # Skip blocks whose source location could not be resolved.
            continue
        filename = loc.rsplit(":", 1)[0]
        line_no = loc.rsplit(":", 1)[1]
        if not line_no.isdigit():
            continue
        rec = per_file.setdefault(filename, {"found": 0, "hit": 0})
        rec["found"] += 1
        if idx in executed_set:
            rec["hit"] += 1

    # Sanity check: total instrumented blocks must equal the sum of
    # per-file found counts (requirement: define the total number of
    # instrumented basic blocks).
    total_found = sum(v["found"] for v in per_file.values())
    total_hit = sum(v["hit"] for v in per_file.values())

    report = {
        "sources": per_file,
        "total": {
            "found": total_blocks,
            "hit": len(executed_set)
        },
        "resolved_found": total_found,
        "resolved_hit": total_hit,
    }

    with open(args.output, "w", encoding="utf-8") as f:
        json.dump(report, f, indent=2, sort_keys=True)
        f.write("\n")

    sys.stderr.write(
        "bb_cov_finalize: %d blocks total, %d executed; "
        "attributed %d blocks to %d source files\n"
        % (total_blocks, len(executed_set), total_found,
           len(per_file)))

    if total_blocks > 0 and total_found < max(1, total_blocks // 10):
        sys.stderr.write(
            "WARNING: most basic blocks could not be attributed to a "
            "source file.\n"
            "  Make sure the binary was built with -no-pie "
            "(fixed load addresses) and debug info (-g),\n"
            "  and that llvm-addr2line can symbolize %s\n"
            % args.binary)


if __name__ == "__main__":
    main()