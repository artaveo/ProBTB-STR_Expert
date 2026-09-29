"""E0 regression for BTB-4 (roadmap V5, V7 step B.4): the Part 1 results must be unchanged.

Usage:
    python -m btb_reference.regression <v2_package_dir> <part1_package_dir>

Compares, for every timeframe of the Part 1 package:
  - btb_days.csv rows with date < 2026-07-01 (the DESIGN range),
  - btb_events_<TF>.csv rows with break_bar_time < 2026-07-01,
  - btb_proxies_<TF>.csv rows with mode = E0 and sample = DESIGN, cut to the 36 Part 1 columns,
with the Part 1 files, line by line. Writes <v2_package>/python_reference/regression_report.json.
Exit code 0 = identical.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from typing import List

from .run_reference import compare

HOLDOUT_START_ISO = "2026-07-01"


def read_lines(path: str) -> List[str]:
    with open(path, "rb") as f:
        return f.read().decode("utf-8").splitlines()


def design_days(lines: List[str]) -> List[str]:
    return [lines[0]] + [x for x in lines[1:] if x[:10] < HOLDOUT_START_ISO]


def design_events(lines: List[str]) -> List[str]:
    col = lines[0].split(",").index("break_bar_time")
    return [lines[0]] + [x for x in lines[1:] if x.split(",")[col][:10] < HOLDOUT_START_ISO]


def design_e0_proxies(lines: List[str], ncols: int) -> List[str]:
    hdr = lines[0].split(",")
    mi, si = hdr.index("mode"), hdr.index("sample")
    out = [",".join(hdr[:ncols])]
    for x in lines[1:]:
        f = x.split(",")
        if f[mi] == "E0" and f[si] == "DESIGN":
            out.append(",".join(f[:ncols]))
    return out


def run(v2: str, p1: str) -> dict:
    with open(os.path.join(p1, "reference_config.json"), "r", encoding="utf-8") as f:
        rc = json.load(f)
    rep = {"v2_package": os.path.abspath(v2), "part1_package": os.path.abspath(p1), "files": {}, "result": "PASS"}
    pairs = [("btb_days.csv", design_days(read_lines(os.path.join(v2, "btb_days.csv"))),
              read_lines(os.path.join(p1, "btb_days.csv")))]
    for tf in rc["timeframes"]:
        pairs.append((f"btb_events_{tf}.csv", design_events(read_lines(os.path.join(v2, f"btb_events_{tf}.csv"))),
                      read_lines(os.path.join(p1, f"btb_events_{tf}.csv"))))
        p1_px = read_lines(os.path.join(p1, f"btb_proxies_{tf}.csv"))
        ncols = len(p1_px[0].split(","))
        pairs.append((f"btb_proxies_{tf}.csv (E0, DESIGN, first {ncols} columns)",
                      design_e0_proxies(read_lines(os.path.join(v2, f"btb_proxies_{tf}.csv")), ncols), p1_px))
    for name, new, old in pairs:
        cmp = compare(old, new)          # "mql5" = Part 1 file, "python" = BTB-4 rows
        rep["files"][name] = cmp
        if not cmp["identical"]:
            rep["result"] = "FAIL"
    return rep


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("v2_package_dir")
    ap.add_argument("part1_package_dir")
    args = ap.parse_args(argv)
    rep = run(args.v2_package_dir, args.part1_package_dir)
    out = os.path.join(args.v2_package_dir, "python_reference")
    os.makedirs(out, exist_ok=True)
    with open(os.path.join(out, "regression_report.json"), "w", encoding="utf-8") as f:
        json.dump(rep, f, indent=2)
    for name, c in rep["files"].items():
        print(f"{name}: {'IDENTICAL' if c['identical'] else 'DIFF'} part1_rows={c['mql5_rows']} btb4_rows={c['python_rows']}")
    print(f"E0 REGRESSION {rep['result']} -> {os.path.join(out, 'regression_report.json')}")
    return 0 if rep["result"] == "PASS" else 1


if __name__ == "__main__":
    sys.exit(main())
