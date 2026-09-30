#!/usr/bin/env python3
"""Summarise Verilator coverage per module.

Reads build/<module>/cov_*.dat (one file per seed), merges the counters and
reports:
  * line, branch and toggle coverage of the RTL (files under modules/<m>/rtl/);
  * functional coverage: every `cover property` in RTL and testbench plus the
    testbench bins from build/<module>/fcov_*.txt (see common/tb_pkg.sv).

Usage: coverage_report.py <build_dir> <module>... [--md out.md] [--info out.info]
"""
import argparse
import glob
import os
import re
import subprocess
import sys
from collections import defaultdict

CATS = ("line", "branch", "toggle", "func")
KEY_RE = re.compile(r"^C '(.*)' (\d+)$")


def parse_dat(path, acc):
    with open(path) as f:
        for line in f:
            m = KEY_RE.match(line.rstrip("\n"))
            if not m:
                continue
            fields = {}
            for item in m.group(1).split("\x01")[1:]:
                k, _, v = item.partition("\x02")
                fields[k] = v
            key = (fields.get("f"), fields.get("l"), fields.get("n"),
                   fields.get("page"), fields.get("o"), fields.get("h"))
            acc[key] += int(m.group(2))


def parse_bins(path, acc):
    with open(path) as f:
        for line in f:
            name, _, cnt = line.strip().rpartition(" ")
            if name:
                acc[name] += int(cnt)


def pct(hit, total):
    return 100.0 * hit / total if total else 100.0


def summarise(mod, points):
    stat = {c: [0, 0] for c in CATS}
    missed = {c: [] for c in CATS}
    for (f, l, _n, page, o, h), cnt in points.items():
        kind = page.split("/")[0]
        in_rtl = f"/{mod}/rtl/" in f"/{f}" or f.startswith(f"modules/{mod}/rtl/")
        if kind == "v_user":
            cat = "func"
        elif kind == "v_line" and in_rtl:
            cat = "line"
        elif kind == "v_branch" and in_rtl:
            cat = "branch"
        elif kind == "v_toggle" and in_rtl:
            cat = "toggle"
        else:
            continue
        stat[cat][1] += 1
        if cnt > 0:
            stat[cat][0] += 1
        else:
            where = f"{os.path.basename(f)}:{l}"
            missed[cat].append(where if cat == "line" else f"{where} {o} ({h})")
    return stat, missed


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("build")
    ap.add_argument("modules", nargs="+")
    ap.add_argument("--md")
    ap.add_argument("--info")
    args = ap.parse_args()

    rows, details, all_dat = [], [], []
    for mod in args.modules:
        dats = sorted(glob.glob(os.path.join(args.build, mod, "cov_*.dat")))
        if not dats:
            print(f"warning: no coverage data for {mod}", file=sys.stderr)
            continue
        all_dat += dats
        points = defaultdict(int)
        for d in dats:
            parse_dat(d, points)
        stat, missed = summarise(mod, points)
        bins = defaultdict(int)
        for b in sorted(glob.glob(os.path.join(args.build, mod, "fcov_*.txt"))):
            parse_bins(b, bins)
        for name, cnt in sorted(bins.items()):
            stat["func"][1] += 1
            if cnt > 0:
                stat["func"][0] += 1
            else:
                missed["func"].append(f"bin {name}")
        rows.append((mod, len(dats), stat))
        details.append((mod, missed))

    hdr = "| Module | Seeds | Line | Branch | Toggle | Functional (cover property + bins) |"
    sep = "|---|---|---|---|---|---|"
    lines = [hdr, sep]
    for mod, n, s in rows:
        cells = [f"{pct(*s[c]):.1f}% ({s[c][0]}/{s[c][1]})" for c in CATS]
        lines.append(f"| `{mod}` | {n} | " + " | ".join(cells) + " |")
    table = "\n".join(lines)
    print(table)

    report = ["# Coverage report", "", table, ""]
    for mod, missed in details:
        items = [(c, x) for c in ("func", "line", "branch", "toggle") for x in missed[c]]
        if not items:
            continue
        report += [f"## {mod}: uncovered points", ""]
        report += [f"- {c}: `{x}`" for c, x in items[:40]]
        if len(items) > 40:
            report.append(f"- ... and {len(items) - 40} more")
        report.append("")
        print(f"\n{mod}: {len(items)} uncovered point(s)")
        for c, x in items[:10]:
            print(f"  {c:6s} {x}")

    if args.md:
        with open(args.md, "w") as f:
            f.write("\n".join(report))
    if args.info and all_dat:
        subprocess.run(["verilator_coverage", "--write-info", args.info] + all_dat,
                       check=True, stdout=subprocess.DEVNULL)


if __name__ == "__main__":
    main()
