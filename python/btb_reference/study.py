"""BTB-3 report: 4 levels x 2 timeframes x 2 windows x 3 R = 48 cells (roadmap 6, 7).

Usage:
    python -m btb_reference.study <package_dir> [--reps 10000] [--seed 20260929]

Reads btb_events_<TF>.csv, btb_proxies_<TF>.csv and btb_days.csv written by
BTB_Expert and writes python_reference/report.md and report.json. It only
regroups the ledgers; changing the report never needs a new tester run.

Per cell the analysis set is the filled proxies with a real exit (not
END_OF_DATA; quarantined proxies already carry the state IN_QUARANTINE).
Classification (pre-registered, roadmap 6):
    INCONCLUSIVE_LOW_N  fewer than 100 analysed fills or fewer than 20 independent days
    NEGATIVE            one-sided upper 95% bound of mean net R < 0
    POSITIVE_EVIDENCE   Holm-Bonferroni over all 48 bootstrap p-values at alpha 0.05 still significant
    OPEN                otherwise
"""

from __future__ import annotations

import argparse
import csv
import json
import os
import statistics
import sys
from collections import Counter
from typing import Dict, List

from tre_reference.stats import (DEFAULT_REPS, DEFAULT_SEED, day_block_bootstrap_means, holm_bonferroni,
                                 p_value_from_means, upper_from_means)

CONTRACT_ID = "BTB-STUDY-2026-09-29"
LEVELS = ("L1", "L2", "L3", "L4")
LEVEL_NAMES = {"L1": "PDH/PDL", "L2": "Asian range", "L3": "H1 swing", "L4": "Consolidation box"}
WINDOWS = ("FULL", "NY")
R_TARGETS = (1, 2, 3)
MIN_FILLS = 100
MIN_DAYS = 20
ALPHA = 0.05
FILLED_STATES = ("FILLED", "FILLED_AT_PLACEMENT")

INCONCLUSIVE = "INCONCLUSIVE_LOW_N"
NEGATIVE = "NEGATIVE"
POSITIVE = "POSITIVE_EVIDENCE"
OPEN = "OPEN"


def read_rows(path: str) -> List[dict]:
    with open(path, "r", encoding="utf-8", newline="") as f:
        return list(csv.DictReader(f))


def cell_key(level: str, tf: str, window: str, r: int) -> str:
    return f"{level}|{tf}|{window}|R{r}"


def window_flag(window: str) -> str:
    return "in_full" if window == "FULL" else "in_ny"


def is_analysed(row: dict) -> bool:
    return row["state"] in FILLED_STATES and row["exit_reason"] != "END_OF_DATA"


def fmean(rows: List[dict], key: str):
    return statistics.fmean(float(r[key]) for r in rows) if rows else None


def cell_stats(events: List[dict], proxies: List[dict], reps: int, seed: int) -> dict:
    fills = [p for p in proxies if p["state"] in FILLED_STATES]
    use = [p for p in fills if is_analysed(p)]
    net = [float(p["net_r"]) for p in use]
    boot_rows = [{"entry_time": p["fill_time"], "net_r": p["net_r"]} for p in use]
    means = day_block_bootstrap_means(boot_rows, reps, seed)
    out = {
        "events": len(events),
        "orders": len(proxies),
        "fills": len(fills),
        "fill_rate": (len(fills) / len(events)) if events else None,
        "analysed": len(use),
        "independent_days": len({p["fill_time"][:10] for p in use}),
        "win_rate": (sum(1 for x in net if x > 0) / len(net)) if net else None,
        "mean_net_r": statistics.fmean(net) if net else None,
        "total_net_r": sum(net) if net else 0.0,
        "upper95_mean_net_r": upper_from_means(means),
        "p_value": p_value_from_means(means),
        "mean_s0_pips": fmean(use, "s0_pips"),
        "mean_commission_r": fmean(use, "commission_r"),
        "mean_s0_r": fmean(use, "s0_r"),
        "states": dict(sorted(Counter(p["state"] for p in proxies).items())),
        "exit_reasons": dict(sorted(Counter(p["exit_reason"] for p in use).items())),
        "by_side": {},
    }
    out["mean_cost_share_r"] = (out["mean_commission_r"] + out["mean_s0_r"]) if use else None
    for side in ("LONG", "SHORT"):
        s = [float(p["net_r"]) for p in use if p["side"] == side]
        out["by_side"][side] = {"analysed": len(s), "mean_net_r": statistics.fmean(s) if s else None,
                                "win_rate": (sum(1 for x in s if x > 0) / len(s)) if s else None}
    return out


def classify(stats: dict, holm_significant: bool) -> str:
    if stats["analysed"] < MIN_FILLS or stats["independent_days"] < MIN_DAYS:
        return INCONCLUSIVE
    if stats["upper95_mean_net_r"] is not None and stats["upper95_mean_net_r"] < 0:
        return NEGATIVE
    if holm_significant:
        return POSITIVE
    return OPEN


def analyse_rows(events_by_tf: Dict[str, List[dict]], proxies_by_tf: Dict[str, List[dict]],
                 reps: int = DEFAULT_REPS, seed: int = DEFAULT_SEED) -> dict:
    cells = {}
    for level in LEVELS:
        for tf in events_by_tf:
            for window in WINDOWS:
                flag = window_flag(window)
                ev = [e for e in events_by_tf[tf]
                      if e["level_type"] == level and e["status"] == "EVENT" and e[flag] == "1"]
                for r in R_TARGETS:
                    px = [p for p in proxies_by_tf[tf]
                          if p["level_type"] == level and p[flag] == "1" and int(p["r_target"]) == r]
                    s = cell_stats(ev, px, reps, seed)
                    s.update({"level": level, "tf": tf, "window": window, "r": r})
                    cells[cell_key(level, tf, window, r)] = s
    holm = holm_bonferroni({k: c["p_value"] for k, c in cells.items()}, ALPHA)
    for k, c in cells.items():
        c["holm_significant"] = holm[k]
        c["classification"] = classify(c, holm[k])
    return cells


def summary(events_by_tf, proxies_by_tf, days: List[dict]) -> dict:
    out = {"timeframes": {}, "days": dict(sorted(Counter(d["status"] for d in days).items()))}
    refs = [float(d["ref_spread_pts"]) for d in days if d["ref_spread_pts"] not in ("", "NA")]
    out["mean_reference_spread_pts"] = statistics.fmean(refs) if refs else None
    for tf in events_by_tf:
        px1 = [p for p in proxies_by_tf[tf] if p["r_target"] == "1"]
        placed = [p for p in px1 if p["s0_pips"] not in ("", "NA")]
        fills = [p for p in px1 if p["state"] in FILLED_STATES]
        ev = [e for e in events_by_tf[tf] if e["status"] == "EVENT" and e["in_full"] == "1"]
        out["timeframes"][tf] = {
            "event_rows": len(events_by_tf[tf]),
            "events_in_full": len(ev),
            "event_status": dict(sorted(Counter(e["status"] for e in events_by_tf[tf]).items())),
            "mean_entry_spread_s0_pips": statistics.fmean(float(p["s0_pips"]) for p in placed) if placed else None,
            "fill_rate_r1": (len(fills) / len(ev)) if ev else None,
        }
    return out


def analyse(pkg: str, reps: int = DEFAULT_REPS, seed: int = DEFAULT_SEED) -> dict:
    with open(os.path.join(pkg, "reference_config.json"), "r", encoding="utf-8") as f:
        rc = json.load(f)
    events_by_tf, proxies_by_tf = {}, {}
    for tf in rc["timeframes"]:
        events_by_tf[tf] = read_rows(os.path.join(pkg, f"btb_events_{tf}.csv"))
        proxies_by_tf[tf] = read_rows(os.path.join(pkg, f"btb_proxies_{tf}.csv"))
    days_path = os.path.join(pkg, "btb_days.csv")
    days = read_rows(days_path) if os.path.exists(days_path) else []
    report = {"contract_id": CONTRACT_ID, "package": os.path.abspath(pkg),
              "rules": {"min_fills": MIN_FILLS, "min_independent_days": MIN_DAYS, "alpha": ALPHA,
                        "multiple_testing": "Holm-Bonferroni over all 48 cells",
                        "bootstrap": {"method": "day-block (broker day of the fill)", "reps": reps, "seed": seed,
                                      "p_value": "share of resample means <= 0"},
                        "net_r": "RealizedNetPnL / PlannedRisk1R; 1 lot; exact limit fill at the breakout close; "
                                 "SL beyond the breakout extreme by the live spread; TP solved for k R net",
                        "analysis_set": "filled proxies with a real exit (not END_OF_DATA, not IN_QUARANTINE)"},
              "cells": analyse_rows(events_by_tf, proxies_by_tf, reps, seed),
              "summary": summary(events_by_tf, proxies_by_tf, days)}
    man = os.path.join(pkg, "manifest.json")
    if os.path.exists(man):
        with open(man, "r", encoding="utf-8") as f:
            m = json.load(f)
        report["experiment_id"] = m.get("experiment_id")
        report["data_gate"] = m.get("tick_source", {}).get("data_gate")
        report["non_default_inputs"] = m.get("inputs", {}).get("non_default_inputs")
    report["classification_counts"] = dict(sorted(Counter(c["classification"] for c in report["cells"].values()).items()))
    return report


def fmt(x, d=3):
    return "NA" if x is None else f"{x:.{d}f}"


def markdown(rep: dict) -> str:
    s = rep["summary"]
    lines = ["# Pro BTB — BTB-3 Report", "",
             f"Experiment `{rep.get('experiment_id')}` · data gate **{rep.get('data_gate')}** · "
             f"non-default inputs: {rep.get('non_default_inputs')}", "",
             "Net R = realized net P/L / PlannedRisk1R (1 lot, exact limit fill at the breakout close, SL beyond the "
             "breakout extreme by the live spread, TP solved for k R net). One-sided 95% upper bound and p-value from a "
             f"day-block bootstrap ({rep['rules']['bootstrap']['reps']} reps, seed {rep['rules']['bootstrap']['seed']}). "
             "POSITIVE_EVIDENCE needs Holm-Bonferroni significance over all 48 cells. No cell is selected as best.", "",
             f"Days: {s['days']} · mean reference spread {fmt(s['mean_reference_spread_pts'], 1)} points", ""]
    for tf, t in s["timeframes"].items():
        lines.append(f"- {tf}: events in FULL {t['events_in_full']}, mean entry spread s0 "
                     f"{fmt(t['mean_entry_spread_s0_pips'], 2)} pips, fill rate (R=1) {fmt(t['fill_rate_r1'])}")
    lines += ["", f"Classifications: {rep['classification_counts']}", "",
              "| Level | TF | Window | R | Events | Fills | TP | SL | 21:30 close | Gap | Fill rate | Days | Win rate | "
              "Mean net R | Total net R | Upper95 | p | Holm | s0 pips | Cost R | Long n / mean | Short n / mean | Class |",
              "|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|"]
    for c in rep["cells"].values():
        lo, sh = c["by_side"]["LONG"], c["by_side"]["SHORT"]
        ex = c["exit_reasons"]
        gaps = sum(n for k, n in ex.items() if k.startswith("GAP_"))
        lines.append(
            f"| {c['level']} {LEVEL_NAMES[c['level']]} | {c['tf']} | {c['window']} | {c['r']} | {c['events']} | "
            f"{c['analysed']} | {ex.get('TP', 0)} | {ex.get('SL', 0)} | {ex.get('SESSION_CLOSE', 0)} | {gaps} | "
            f"{fmt(c['fill_rate'])} | {c['independent_days']} | {fmt(c['win_rate'])} | "
            f"{fmt(c['mean_net_r'])} | {fmt(c['total_net_r'], 2)} | {fmt(c['upper95_mean_net_r'])} | "
            f"{fmt(c['p_value'], 4)} | {'yes' if c['holm_significant'] else 'no'} | {fmt(c['mean_s0_pips'], 2)} | "
            f"{fmt(c['mean_cost_share_r'])} | {lo['analysed']} / {fmt(lo['mean_net_r'])} | "
            f"{sh['analysed']} / {fmt(sh['mean_net_r'])} | {c['classification']} |")
    lines.append("")
    return "\n".join(lines)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("package_dir")
    ap.add_argument("--reps", type=int, default=DEFAULT_REPS)
    ap.add_argument("--seed", type=int, default=DEFAULT_SEED)
    args = ap.parse_args(argv)
    rep = analyse(args.package_dir, args.reps, args.seed)
    out = os.path.join(args.package_dir, "python_reference")
    os.makedirs(out, exist_ok=True)
    with open(os.path.join(out, "report.json"), "w", encoding="utf-8") as f:
        json.dump(rep, f, indent=2)
    with open(os.path.join(out, "report.md"), "w", encoding="utf-8") as f:
        f.write(markdown(rep))
    for c in rep["cells"].values():
        print(f"{c['level']} {c['tf']} {c['window']} R{c['r']}: fills={c['analysed']} days={c['independent_days']} "
              f"mean={fmt(c['mean_net_r'])} upper95={fmt(c['upper95_mean_net_r'])} p={fmt(c['p_value'], 4)} "
              f"-> {c['classification']}")
    print(f"CLASSIFICATIONS {rep['classification_counts']} -> {os.path.join(out, 'report.md')}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
