"""BTB-3 report (48 cells, roadmap 6, 7) and the BTB-4 / PART 2 report (roadmap V4).

A package whose btb_proxies_<TF>.csv has the "mode" column (BTB-v2) gets the V4 report: 36 primary
cells (E0, E1 with D = 1.0, E2; pooled over L1-L4; TF x window x R) per sample DESIGN / HOLDOUT / ALL,
the DESIGN classification (Holm over 36), the HOLDOUT verdict (Holm over the 24 E1 + E2 cells and
DESIGN mean > 0), the arming / setup funnel and the diagnostic cells. Otherwise the Part 1 report:

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


def drawdown_stats(rows: List[dict]) -> dict:
    """Descriptive only (not part of the classification): the closed proxies of one cell in exit order
    (exit_time, then fill_time), equity = cumulative net R starting at 0. Max drawdown = largest
    peak-to-trough fall of that equity in R; max losing streak = most consecutive trades with net R < 0."""
    seq = sorted(rows, key=lambda p: (p["exit_time"], p["fill_time"]))
    equity = peak = max_dd = 0.0
    streak = max_streak = 0
    for p in seq:
        x = float(p["net_r"])
        equity += x
        peak = max(peak, equity)
        max_dd = max(max_dd, peak - equity)
        streak = streak + 1 if x < 0 else 0
        max_streak = max(max_streak, streak)
    return {"max_drawdown_r": max_dd if seq else None, "max_losing_streak": max_streak}


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
    out.update(drawdown_stats(use))
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
              "Max DD R = largest peak-to-trough fall of the cumulative net R of the cell's closed proxies in exit "
              "order; Max L streak = most consecutive losing trades. Both are descriptive and do not enter the "
              "classification.", "",
              "| Level | TF | Window | R | Events | Fills | TP | SL | 21:30 close | Gap | Fill rate | Days | Win rate | "
              "Mean net R | Total net R | Max DD R | Max L streak | Upper95 | p | Holm | s0 pips | Cost R | "
              "Long n / mean | Short n / mean | Class |",
              "|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|"]
    for c in rep["cells"].values():
        lo, sh = c["by_side"]["LONG"], c["by_side"]["SHORT"]
        ex = c["exit_reasons"]
        gaps = sum(n for k, n in ex.items() if k.startswith("GAP_"))
        lines.append(
            f"| {c['level']} {LEVEL_NAMES[c['level']]} | {c['tf']} | {c['window']} | {c['r']} | {c['events']} | "
            f"{c['analysed']} | {ex.get('TP', 0)} | {ex.get('SL', 0)} | {ex.get('SESSION_CLOSE', 0)} | {gaps} | "
            f"{fmt(c['fill_rate'])} | {c['independent_days']} | {fmt(c['win_rate'])} | "
            f"{fmt(c['mean_net_r'])} | {fmt(c['total_net_r'], 2)} | {fmt(c['max_drawdown_r'], 2)} | "
            f"{c['max_losing_streak']} | {fmt(c['upper95_mean_net_r'])} | "
            f"{fmt(c['p_value'], 4)} | {'yes' if c['holm_significant'] else 'no'} | {fmt(c['mean_s0_pips'], 2)} | "
            f"{fmt(c['mean_cost_share_r'])} | {lo['analysed']} / {fmt(lo['mean_net_r'])} | "
            f"{sh['analysed']} / {fmt(sh['mean_net_r'])} | {c['classification']} |")
    lines.append("")
    return "\n".join(lines)


# ======================================================================================
# BTB-v2 (roadmap PART 2, V4): modes E0 / E1 / E2, samples DESIGN / HOLDOUT / ALL
# ======================================================================================
CONTRACT_ID_V2 = "BTB-V2-STUDY-2026-09-30"
MODES = ("E0", "E1", "E2")
SAMPLES = ("DESIGN", "HOLDOUT", "ALL")
PRIMARY_DEP = "1.0"
SECONDARY_DEPS = ("1.5", "2.0")
HOLDOUT_MIN_FILLS = 30
HOLDOUT_MIN_DAYS = 10
HOLDOUT_START_ISO = "2026-07-01"
CONFIRMED = "CONFIRMED"
NOT_CONFIRMED = "NOT_CONFIRMED"
BASELINE = "BASELINE"
SPREAD_BUCKETS = ("LT3", "3_5", "5_8", "GE8")


def is_v2(proxies_by_tf: Dict[str, List[dict]]) -> bool:
    return any(rows and "mode" in rows[0] for rows in proxies_by_tf.values())


def sample_of_time(iso: str) -> str:
    return "DESIGN" if iso[:10] < HOLDOUT_START_ISO else "HOLDOUT"


def in_sample(row_sample: str, sample: str) -> bool:
    return sample == "ALL" or row_sample == sample


def primary_key(mode: str, tf: str, window: str, r: int) -> str:
    return f"{mode}|{tf}|{window}|R{r}"


def v2_rows(events: List[dict], setups: List[dict], proxies: List[dict], mode: str, window: str, r: int, sample: str,
            dep: str = PRIMARY_DEP, level: str = None, legs: str = None, side: str = None, bucket: str = None):
    """(events, window-filtered proxies, all-window proxies of the cell) for one v2 cell.

    E0/E1: events = EVENT rows with the window flag (window of the breakout close, as Part 1).
    E2: events = the E2 setups (one per EVENT); the window of a proxy is decided by its fill time.
    """
    flag = window_flag(window)

    def keep_px(p):
        if p["mode"] != mode or int(p["r_target"]) != r or not in_sample(p["sample"], sample):
            return False
        if mode == "E1" and p["dep_d"] != dep:
            return False
        if level and p["level_type"] != level:
            return False
        if side and p["side"] != side:
            return False
        if bucket and p["spread_bucket"] != bucket:
            return False
        if legs and not (p["n_legs"] == "3" if legs == "3" else (p["n_legs"] not in ("NA", "") and int(p["n_legs"]) >= 4)):
            return False
        return True

    px_all = [p for p in proxies if keep_px(p)]
    px = [p for p in px_all if p[flag] == "1"]
    if mode == "E2":
        ev = [x for x in setups if in_sample(x["sample"], sample) and x["in_quarantine"] == "0"
              and (not level or x["level_type"] == level) and (not side or x["side"] == side)
              and (not legs or (x["n_legs"] == "3" if legs == "3" else int(x["n_legs"]) >= 4))]
    else:
        ev = [e for e in events if e["status"] == "EVENT" and e[flag] == "1"
              and in_sample(sample_of_time(e["break_bar_time"]), sample)
              and (not level or e["level_type"] == level) and (not side or e["side"] == side)]
    return ev, px, px_all


def funnel(mode: str, ev: List[dict], px_all: List[dict], px: List[dict]) -> dict:
    # E0/E1 rows carry the window of the breakout close, so armed orders are counted inside the cell's window;
    # an unfilled E2 row has no window (closure 54), so E2 counts its live rows over all windows.
    armed_col = "placement_time" if mode == "E0" else "arm_time"
    armed_rows = px_all if mode == "E2" else px
    return {"events": len(ev), "armed_or_live": sum(1 for p in armed_rows if p[armed_col] not in ("", "NA")),
            "filled": sum(1 for p in px if p["state"] in FILLED_STATES)}


def v2_cell(events, setups, proxies, mode, window, r, sample, reps, seed, **kw) -> dict:
    ev, px, px_all = v2_rows(events, setups, proxies, mode, window, r, sample, **kw)
    s = cell_stats(ev, px, reps, seed)
    s["funnel"] = funnel(mode, ev, px_all, px)
    return s


def holdout_verdict(design: dict, holdout: dict, holm_sig: bool) -> str:
    if holdout["analysed"] < HOLDOUT_MIN_FILLS or holdout["independent_days"] < HOLDOUT_MIN_DAYS:
        return INCONCLUSIVE
    if holm_sig and design["mean_net_r"] is not None and design["mean_net_r"] > 0:
        return CONFIRMED
    return NOT_CONFIRMED


def analyse_v2_rows(events_by_tf, setups_by_tf, proxies_by_tf, reps: int = DEFAULT_REPS, seed: int = DEFAULT_SEED) -> dict:
    primary = {}
    for mode in MODES:
        for tf in proxies_by_tf:
            for window in WINDOWS:
                for r in R_TARGETS:
                    key = primary_key(mode, tf, window, r)
                    primary[key] = {"mode": mode, "tf": tf, "window": window, "r": r, "samples": {
                        smp: v2_cell(events_by_tf[tf], setups_by_tf.get(tf, []), proxies_by_tf[tf], mode, window, r, smp,
                                     reps, seed) for smp in SAMPLES}}
    # DESIGN: Part 1 classification with Holm over the 36 primary cells
    hd = holm_bonferroni({k: c["samples"]["DESIGN"]["p_value"] for k, c in primary.items()}, ALPHA)
    # HOLDOUT (decisive): Holm over the 24 E1 + E2 primary cells
    hh = holm_bonferroni({k: c["samples"]["HOLDOUT"]["p_value"] for k, c in primary.items() if c["mode"] != "E0"}, ALPHA)
    for k, c in primary.items():
        d, h = c["samples"]["DESIGN"], c["samples"]["HOLDOUT"]
        c["design_holm_significant"] = hd[k]
        c["design_classification"] = classify(d, hd[k])
        if c["mode"] == "E0":
            c["holdout_holm_significant"] = None
            c["holdout_verdict"] = BASELINE
        else:
            c["holdout_holm_significant"] = hh[k]
            c["holdout_verdict"] = holdout_verdict(d, h, hh[k])
    return primary


def diagnostics_v2(events_by_tf, setups_by_tf, proxies_by_tf) -> dict:
    """Descriptive cells (no bootstrap, not decision-making)."""
    out = {"per_level": {}, "e1_dep": {}, "e2_legs": {}, "side": {}, "spread_bucket": {}}

    def put(group, key, **kw):
        out[group][key] = {smp: v2_cell(events_by_tf[kw["tf"]], setups_by_tf.get(kw["tf"], []), proxies_by_tf[kw["tf"]],
                                        kw["mode"], kw["window"], kw["r"], smp, 0, 0,
                                        **{a: b for a, b in kw.items() if a in ("dep", "level", "legs", "side", "bucket")})
                           for smp in SAMPLES}

    for tf in proxies_by_tf:
        for window in WINDOWS:
            for r in R_TARGETS:
                for mode in MODES:
                    for level in LEVELS:
                        put("per_level", f"{mode}|{tf}|{window}|R{r}|{level}", mode=mode, tf=tf, window=window, r=r, level=level)
                    for side in ("LONG", "SHORT"):
                        put("side", f"{mode}|{tf}|{window}|R{r}|{side}", mode=mode, tf=tf, window=window, r=r, side=side)
                for dep in SECONDARY_DEPS:
                    put("e1_dep", f"E1|D{dep}|{tf}|{window}|R{r}", mode="E1", tf=tf, window=window, r=r, dep=dep)
                for legs in ("3", "4+"):
                    put("e2_legs", f"E2|legs{legs}|{tf}|{window}|R{r}", mode="E2", tf=tf, window=window, r=r, legs=legs)
            for r in R_TARGETS:
                for mode in MODES:
                    for bucket in SPREAD_BUCKETS:
                        put("spread_bucket", f"{mode}|{tf}|FULL|R{r}|{bucket}", mode=mode, tf=tf, window="FULL", r=r,
                            bucket=bucket)
    return out


def e2_funnel(setups_by_tf, proxies_by_tf) -> dict:
    out = {}
    for tf, rows in setups_by_tf.items():
        for smp in SAMPLES:
            st = [x for x in rows if in_sample(x["sample"], smp)]
            px = [p for p in proxies_by_tf[tf] if p["mode"] == "E2" and p["r_target"] == "1" and in_sample(p["sample"], smp)]
            out[f"{tf}|{smp}"] = {
                "setups": len(st),
                "status": dict(sorted(Counter(x["status"] for x in st).items())),
                "three_legs": sum(1 for x in st if int(x["n_legs"]) >= 3),
                "spike": sum(1 for x in st if x["spike_time"]),
                "trend_line": sum(1 for x in st if x["p2_time"]),
                "live": sum(1 for x in st if x["first_live_bar"]),
                "live_to_fill": sum(1 for x in st if x["status"] == "LIVE_TO_FILL"),
                "filled_r1": sum(1 for p in px if p["state"] in FILLED_STATES),
            }
    return out


def analyse_v2(pkg: str, reps: int = DEFAULT_REPS, seed: int = DEFAULT_SEED) -> dict:
    with open(os.path.join(pkg, "reference_config.json"), "r", encoding="utf-8") as f:
        rc = json.load(f)
    events_by_tf, setups_by_tf, proxies_by_tf = {}, {}, {}
    for tf in rc["timeframes"]:
        events_by_tf[tf] = read_rows(os.path.join(pkg, f"btb_events_{tf}.csv"))
        proxies_by_tf[tf] = read_rows(os.path.join(pkg, f"btb_proxies_{tf}.csv"))
        sp = os.path.join(pkg, f"btb_setups_E2_{tf}.csv")
        setups_by_tf[tf] = read_rows(sp) if os.path.exists(sp) else []
    days_path = os.path.join(pkg, "btb_days.csv")
    days = read_rows(days_path) if os.path.exists(days_path) else []
    report = {"contract_id": CONTRACT_ID_V2, "package": os.path.abspath(pkg),
              "rules": {"primary_cells": "E0, E1 (D = 1.0), E2 pooled over L1-L4, per TF x window x R (36)",
                        "design": "Part 1 classification (min 100 fills, 20 days), Holm over the 36 primary cells",
                        "holdout": "CONFIRMED = HOLDOUT p passes Holm over the 24 E1 + E2 primary cells at alpha 0.05 "
                                   "and DESIGN mean net R > 0; INCONCLUSIVE_LOW_N below 30 fills or 10 days; "
                                   "E0 is the BASELINE and never confirmed",
                        "samples": f"by the event's break-candle date; HOLDOUT from {HOLDOUT_START_ISO}",
                        "bootstrap": {"method": "day-block (broker day of the fill)", "reps": reps, "seed": seed},
                        "e2_window": "decided by the fill time; E0/E1 by the breakout close"},
              "primary": analyse_v2_rows(events_by_tf, setups_by_tf, proxies_by_tf, reps, seed),
              "diagnostics": diagnostics_v2(events_by_tf, setups_by_tf, proxies_by_tf),
              "e2_funnel": e2_funnel(setups_by_tf, proxies_by_tf),
              "summary": summary(events_by_tf, {tf: [p for p in rows if p["mode"] == "E0"] for tf, rows in proxies_by_tf.items()},
                                 days)}
    man = os.path.join(pkg, "manifest.json")
    if os.path.exists(man):
        with open(man, "r", encoding="utf-8") as f:
            m = json.load(f)
        report["experiment_id"] = m.get("experiment_id")
        report["data_gate"] = m.get("tick_source", {}).get("data_gate")
        report["non_default_inputs"] = m.get("inputs", {}).get("non_default_inputs")
    report["design_classification_counts"] = dict(sorted(Counter(
        c["design_classification"] for c in report["primary"].values()).items()))
    report["holdout_verdict_counts"] = dict(sorted(Counter(
        c["holdout_verdict"] for c in report["primary"].values()).items()))
    return report


def markdown_v2(rep: dict) -> str:
    lines = ["# Pro BTB — BTB-4 Report (PART 2: E0 / E1 / E2)", "",
             f"Experiment `{rep.get('experiment_id')}` · data gate **{rep.get('data_gate')}** · "
             f"non-default inputs: {rep.get('non_default_inputs')}", "",
             "Primary cells are pooled over L1–L4. DESIGN = 2026-01-01..06-30 (E1 was suggested by it, so its DESIGN "
             "numbers are optimistic); HOLDOUT = 2026-07-01..09-25 decides. No cell is selected as best.", "",
             f"DESIGN classifications: {rep['design_classification_counts']} · HOLDOUT verdicts: {rep['holdout_verdict_counts']}",
             "", "## Primary cells", "",
             "| Mode | TF | Window | R | DESIGN events → armed/live → fills | DESIGN mean net R | DESIGN win | DESIGN p | "
             "DESIGN class | HOLDOUT events → armed/live → fills | HOLDOUT days | HOLDOUT mean net R | HOLDOUT win | "
             "HOLDOUT p | Holm (24) | HOLDOUT verdict | ALL fills / mean |",
             "|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|"]
    for c in rep["primary"].values():
        d, h, a = c["samples"]["DESIGN"], c["samples"]["HOLDOUT"], c["samples"]["ALL"]
        fd, fh = d["funnel"], h["funnel"]
        hs = c["holdout_holm_significant"]
        lines.append(
            f"| {c['mode']} | {c['tf']} | {c['window']} | {c['r']} | {fd['events']} → {fd['armed_or_live']} → {d['analysed']} | "
            f"{fmt(d['mean_net_r'])} | {fmt(d['win_rate'])} | {fmt(d['p_value'], 4)} | {c['design_classification']} | "
            f"{fh['events']} → {fh['armed_or_live']} → {h['analysed']} | {h['independent_days']} | {fmt(h['mean_net_r'])} | "
            f"{fmt(h['win_rate'])} | {fmt(h['p_value'], 4)} | {'—' if hs is None else ('yes' if hs else 'no')} | "
            f"{c['holdout_verdict']} | {a['analysed']} / {fmt(a['mean_net_r'])} |")
    lines += ["", "## Exits and risk per primary cell (DESIGN | HOLDOUT)", "",
              "Fills = TP + SL + 21:30 close + gap exits. Max DD R = largest peak-to-trough fall of the cumulative net R "
              "in exit order; Max L = most consecutive losing trades. Descriptive only (closure 34).", "",
              "| Mode | TF | Window | R | D fills | D TP | D SL | D 21:30 | D win | D total R | D Max DD R | D Max L | "
              "H fills | H TP | H SL | H 21:30 | H win | H total R | H Max DD R | H Max L |",
              "|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|"]

    def exits(s):
        ex = s["exit_reasons"]
        closes = ex.get("SESSION_CLOSE", 0) + ex.get("GAP_SESSION_CLOSE", 0)
        return (f"{s['analysed']} | {ex.get('TP', 0) + ex.get('GAP_TP', 0)} | {ex.get('SL', 0) + ex.get('GAP_SL', 0)} | "
                f"{closes} | {fmt(s['win_rate'])} | {fmt(s['total_net_r'], 2)} | {fmt(s['max_drawdown_r'], 2)} | "
                f"{s['max_losing_streak']}")

    for c in rep["primary"].values():
        lines.append(f"| {c['mode']} | {c['tf']} | {c['window']} | {c['r']} | {exits(c['samples']['DESIGN'])} | "
                     f"{exits(c['samples']['HOLDOUT'])} |")
    lines += ["", "## E2 funnel (setups → three legs → spike → trend line → live → LIVE_TO_FILL → filled, R = 1)", "",
              "| TF | Sample | Setups | ≥3 legs | Spike | Line | Live | Live to fill | Filled | Statuses |",
              "|---|---|---|---|---|---|---|---|---|---|"]
    for key, f in rep["e2_funnel"].items():
        tf, smp = key.split("|")
        lines.append(f"| {tf} | {smp} | {f['setups']} | {f['three_legs']} | {f['spike']} | {f['trend_line']} | {f['live']} | "
                     f"{f['live_to_fill']} | {f['filled_r1']} | {f['status']} |")
    lines += ["", "## Diagnostics (descriptive, not decision-making): fills / mean net R", ""]
    for group, title in (("e1_dep", "E1 secondary departures"), ("e2_legs", "E2 legs 3 vs ≥ 4"),
                         ("per_level", "Per level"), ("side", "Long vs short"), ("spread_bucket", "Spread buckets (FULL)")):
        lines += [f"### {title}", "", "| Cell | DESIGN | HOLDOUT | ALL |", "|---|---|---|---|"]
        for key, smp in rep["diagnostics"][group].items():
            if all(smp[x]["analysed"] == 0 for x in SAMPLES):
                continue
            lines.append(f"| {key} | " + " | ".join(f"{smp[x]['analysed']} / {fmt(smp[x]['mean_net_r'])}" for x in SAMPLES) + " |")
        lines.append("")
    return "\n".join(lines)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("package_dir")
    ap.add_argument("--reps", type=int, default=DEFAULT_REPS)
    ap.add_argument("--seed", type=int, default=DEFAULT_SEED)
    args = ap.parse_args(argv)
    out = os.path.join(args.package_dir, "python_reference")
    os.makedirs(out, exist_ok=True)
    first_tf = json.load(open(os.path.join(args.package_dir, "reference_config.json"), encoding="utf-8"))["timeframes"][0]
    if is_v2({first_tf: read_rows(os.path.join(args.package_dir, f"btb_proxies_{first_tf}.csv"))[:1]}):
        rep = analyse_v2(args.package_dir, args.reps, args.seed)
        with open(os.path.join(out, "report.json"), "w", encoding="utf-8") as f:
            json.dump(rep, f, indent=2)
        with open(os.path.join(out, "report.md"), "w", encoding="utf-8") as f:
            f.write(markdown_v2(rep))
        for c in rep["primary"].values():
            d, h = c["samples"]["DESIGN"], c["samples"]["HOLDOUT"]
            print(f"{c['mode']} {c['tf']} {c['window']} R{c['r']}: DESIGN fills={d['analysed']} mean={fmt(d['mean_net_r'])} "
                  f"{c['design_classification']} | HOLDOUT fills={h['analysed']} mean={fmt(h['mean_net_r'])} "
                  f"p={fmt(h['p_value'], 4)} -> {c['holdout_verdict']}")
        print(f"DESIGN {rep['design_classification_counts']} HOLDOUT {rep['holdout_verdict_counts']} -> "
              f"{os.path.join(out, 'report.md')}")
        return 0
    rep = analyse(args.package_dir, args.reps, args.seed)
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
