"""Rebuild the BTB event ledgers from an EA run package and reconcile them byte for byte.

Usage:
    python -m btb_reference.run_reference <package_dir> [--out DIR] [--quarantine CSV] [--mql5-dir DIR]

<package_dir> is Common/Files/BTB/<ExperimentId>/ from a BTB_Expert run. It must
contain reference_config.json, session_schedule.csv, the M1 export
(bars_M1_BID.csv) and, for tester runs, data_quarantine_windows.csv. The
reference recomputes btb_days.csv and btb_events_<TF>.csv from the M1 bars only
and compares them byte for byte with the MQL5 files (roadmap 4.3, 7).
Exit code 0 = every ledger identical.
"""

from __future__ import annotations

import argparse
import calendar
import hashlib
import json
import os
import sys
import time
from typing import List, Tuple

from .levels import Bar, Reference, Schedule

M1_HEADER = "time,open,high,low,close,ticks,spread_pts"


def parse_iso(s: str) -> int:
    return calendar.timegm(time.strptime(s, "%Y-%m-%dT%H:%M:%S"))


def read_m1(path: str) -> List[Bar]:
    bars = []
    with open(path, "r", encoding="utf-8") as f:
        header = f.readline().strip()
        if header != M1_HEADER:
            raise ValueError(f"unexpected M1 header: {header}")
        for line in f:
            line = line.strip()
            if not line:
                continue
            t, o, h, l, c, n, sp = line.split(",")
            bars.append(Bar(parse_iso(t), 60, float(o), float(h), float(l), float(c), int(n), int(sp)))
    return bars


def read_schedule(path: str) -> Schedule:
    raw = []
    with open(path, "r", encoding="utf-8") as f:
        header = f.readline().strip()
        if header != "weekday,from_sec,to_sec":
            raise ValueError(f"unexpected session header: {header}")
        for line in f:
            line = line.strip()
            if line:
                d, a, b = line.split(",")
                raw.append((int(d), int(a), int(b)))
    return Schedule(raw)


def read_quarantine(path: str) -> List[Tuple[int, int]]:
    """Same CSV as TRE DataQuarantine: from,to_exclusive[,reason] as 'YYYY.MM.DD HH:MM:SS'."""
    out = []
    if not path or not os.path.exists(path):
        return out
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            parts = line.split(",")
            a = calendar.timegm(time.strptime(parts[0].strip(), "%Y.%m.%d %H:%M:%S"))
            b = calendar.timegm(time.strptime(parts[1].strip(), "%Y.%m.%d %H:%M:%S"))
            out.append((a, b))
    return out


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def compare(ea_lines: List[str], ref_lines: List[str], limit: int = 20) -> dict:
    mismatches = []
    header = ea_lines[0].split(",") if ea_lines else []
    for i in range(max(len(ea_lines), len(ref_lines))):
        a = ea_lines[i] if i < len(ea_lines) else None
        b = ref_lines[i] if i < len(ref_lines) else None
        if a == b:
            continue
        cols = []
        if a is not None and b is not None:
            fa, fb = a.split(","), b.split(",")
            for k in range(max(len(fa), len(fb))):
                va = fa[k] if k < len(fa) else None
                vb = fb[k] if k < len(fb) else None
                if va != vb:
                    cols.append({"column": header[k] if k < len(header) else str(k), "mql5": va, "python": vb})
        mismatches.append({"line": i + 1, "mql5_missing": a is None, "python_missing": b is None, "columns": cols[:10]})
        if len(mismatches) >= limit:
            break
    return {"mql5_rows": max(0, len(ea_lines) - 1), "python_rows": max(0, len(ref_lines) - 1),
            "identical": ea_lines == ref_lines, "first_mismatches": mismatches}


def build(pkg: str, extra_quarantine: str = None) -> Tuple[dict, dict]:
    """Returns (reference_config, {file name: text}) of the Python ledgers."""
    with open(os.path.join(pkg, "reference_config.json"), "r", encoding="utf-8") as f:
        rc = json.load(f)
    sched = read_schedule(os.path.join(pkg, rc["session_file"]))
    bars = read_m1(os.path.join(pkg, rc["m1_bars_file"]))
    windows = []
    if rc.get("quarantine_file"):
        windows += read_quarantine(os.path.join(pkg, rc["quarantine_file"]))
    if rc.get("declared_quarantine_file"):
        if not extra_quarantine:
            print(f"warning: run declared DataQuarantineFile={rc['declared_quarantine_file']}; pass --quarantine", file=sys.stderr)
        else:
            windows += read_quarantine(extra_quarantine)

    def in_quarantine(a: int, b: int) -> bool:
        return any(qa < b and a < qb for qa, qb in windows)

    ref = Reference(sched, list(rc["timeframes"]), int(rc["digits"])).run(bars)
    files = {"btb_days.csv": "\n".join(ref.tracker.rows()) + "\n"}
    for e in ref.engines:
        files[f"btb_events_{e.tf}.csv"] = "\n".join(e.ledger_lines(in_quarantine)) + "\n"
    rc["_m1_bars"] = len(bars)
    return rc, files


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("package_dir")
    ap.add_argument("--out", default=None, help="output directory (default: <package_dir>/python_reference)")
    ap.add_argument("--quarantine", default=None, help="declared DataQuarantineFile, if the run used one")
    ap.add_argument("--mql5-dir", default=None,
                    help="folder with the MQL5 ledgers (default: <package_dir>; BTB_EventReplay writes to <package_dir>/replay)")
    args = ap.parse_args(argv)

    pkg = args.package_dir
    out = args.out or os.path.join(pkg, "python_reference")
    os.makedirs(out, exist_ok=True)
    t0 = time.time()
    rc, files = build(pkg, args.quarantine)

    report = {"contract_id": rc.get("contract_id"), "package": os.path.abspath(pkg), "m1_bars": rc["_m1_bars"],
              "python_version": sys.version.split()[0], "ledgers": {}, "result": "PASS"}
    combined = ""
    for name, text in files.items():
        data = text.encode("utf-8")
        with open(os.path.join(out, name), "wb") as f:
            f.write(data)
        ea_path = os.path.join(args.mql5_dir or pkg, name)
        if os.path.exists(ea_path):
            with open(ea_path, "rb") as f:
                ea_data = f.read()
            cmp = compare(ea_data.decode("utf-8").splitlines(), text.splitlines())
            cmp["identical"] = cmp["identical"] and ea_data == data
            cmp["mql5_sha256"] = sha256_bytes(ea_data)
        else:
            cmp = {"identical": False, "error": "MQL5 ledger missing"}
        cmp["python_sha256"] = sha256_bytes(data)
        report["ledgers"][name] = cmp
        if not cmp.get("identical"):
            report["result"] = "FAIL"
        if name.startswith("btb_events_"):
            combined += f"{name[len('btb_events_'):-4]}:{sha256_bytes(data)};"
    report["python_ledger_checksum"] = hashlib.sha256(combined.encode("utf-8")).hexdigest()
    report["elapsed_seconds"] = round(time.time() - t0, 1)
    with open(os.path.join(out, "reconciliation_report.json"), "w", encoding="utf-8") as f:
        json.dump(report, f, indent=2)

    for name, r in report["ledgers"].items():
        print(f"{name}: {'IDENTICAL' if r.get('identical') else 'DIFF'} rows={r.get('python_rows', '?')}")
    print(f"RECONCILIATION {report['result']}  ledger_checksum={report['python_ledger_checksum']}  "
          f"({report['elapsed_seconds']}s) -> {os.path.join(out, 'reconciliation_report.json')}")
    return 0 if report["result"] == "PASS" else 1


if __name__ == "__main__":
    sys.exit(main())
