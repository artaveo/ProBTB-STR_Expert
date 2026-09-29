"""Blocking tests for the BTB-3 study report (roadmap 6, 7)."""

import json
import os
import random
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")))

from btb_reference import study  # noqa: E402

PROXY_COLS = ["event_id", "tf", "level_type", "side", "box_n", "box_bucket", "break_close_time", "in_full", "in_ny",
              "r_target", "placement_time", "s0", "s0_pips", "limit_price", "sl", "tp", "planned_risk_1r", "commission",
              "state", "fill_time", "fill_delay_s", "exit_time", "exit_price", "exit_reason", "spread_at_exit",
              "gross_pnl", "net_pnl", "net_r", "commission_r", "s0_r", "mae_r", "mfe_r", "ambiguous", "close_hour",
              "hour_bucket", "spread_bucket"]
EVENT_COLS = ["event_id", "tf", "level_type", "side", "level_price", "level_source_time", "box_n", "break_bar_time",
              "break_close_time", "break_open", "break_high", "break_low", "break_close", "atr14", "in_full", "in_ny",
              "status"]


def proxy(level="L1", tf="M5", r=1, day=5, net=1.0, state="FILLED", exit_reason="TP", side="LONG", ny="0", eid="e"):
    p = {k: "" for k in PROXY_COLS}
    p.update({"event_id": eid, "tf": tf, "level_type": level, "side": side, "in_full": "1", "in_ny": ny,
              "r_target": str(r), "state": state, "fill_time": f"2026-02-{day:02d}T10:00:00.000", "exit_reason": exit_reason,
              "net_r": str(net), "s0_pips": "3.0", "commission_r": "0.02", "s0_r": "0.10"})
    return p


def event(level="L1", tf="M5", status="EVENT", full="1", ny="0"):
    e = {k: "" for k in EVENT_COLS}
    e.update({"tf": tf, "level_type": level, "status": status, "in_full": full, "in_ny": ny})
    return e


class TestClassification(unittest.TestCase):
    def s(self, analysed=150, days=40, upper=0.1):
        return {"analysed": analysed, "independent_days": days, "upper95_mean_net_r": upper}

    def test_rules(self):
        self.assertEqual(study.classify(self.s(analysed=99), True), study.INCONCLUSIVE)
        self.assertEqual(study.classify(self.s(days=19), True), study.INCONCLUSIVE)
        self.assertEqual(study.classify(self.s(upper=-0.01), False), study.NEGATIVE)
        self.assertEqual(study.classify(self.s(upper=0.3), True), study.POSITIVE)
        self.assertEqual(study.classify(self.s(upper=0.3), False), study.OPEN)
        self.assertEqual(study.classify(self.s(upper=0.0), False), study.OPEN)       # not < 0
        self.assertEqual(study.classify(self.s(analysed=100, days=20, upper=-1.0), False), study.NEGATIVE)


class TestCells(unittest.TestCase):
    def test_analysis_set_and_fill_rate(self):
        ev = [event() for _ in range(4)]
        px = [proxy(net=2.0), proxy(state="FILLED_AT_PLACEMENT", net=-1.0, exit_reason="SL", day=6),
              proxy(state="FILLED", exit_reason="END_OF_DATA", net=5.0), proxy(state="EXPIRED_12_BARS"),
              proxy(state="IN_QUARANTINE", net=9.0)]
        s = study.cell_stats(ev, px, 200, 1)
        self.assertEqual((s["events"], s["orders"], s["fills"], s["analysed"]), (4, 5, 3, 2))
        self.assertAlmostEqual(s["fill_rate"], 0.75)
        self.assertEqual(s["independent_days"], 2)
        self.assertAlmostEqual(s["mean_net_r"], 0.5)
        self.assertAlmostEqual(s["total_net_r"], 1.0)
        self.assertAlmostEqual(s["win_rate"], 0.5)
        self.assertAlmostEqual(s["mean_cost_share_r"], 0.12)
        self.assertEqual(s["by_side"]["LONG"]["analysed"], 2)
        self.assertEqual(s["exit_reasons"], {"SL": 1, "TP": 1})

    def test_drawdown_and_losing_streak(self):
        def row(exit_time, net):
            return {"exit_time": exit_time, "fill_time": exit_time, "net_r": str(net)}
        # given out of order; exit order is +2, -1, -1, +0.5, -3, +1 -> equity 2, 1, 0, 0.5, -2.5, -1.5
        rows = [row("2026-02-05T10:00:00", -3), row("2026-02-01T10:00:00", 2), row("2026-02-06T10:00:00", 1),
                row("2026-02-02T10:00:00", -1), row("2026-02-04T10:00:00", 0.5), row("2026-02-03T10:00:00", -1)]
        d = study.drawdown_stats(rows)
        self.assertAlmostEqual(d["max_drawdown_r"], 4.5)        # peak 2 -> trough -2.5
        self.assertEqual(d["max_losing_streak"], 2)
        # losses from the start count from the 0 start line
        d = study.drawdown_stats([row("2026-02-01T10:00:00", -1), row("2026-02-02T10:00:00", -1)])
        self.assertAlmostEqual(d["max_drawdown_r"], 2.0)
        self.assertEqual(d["max_losing_streak"], 2)
        self.assertEqual(study.drawdown_stats([]), {"max_drawdown_r": None, "max_losing_streak": 0})

    def test_48_cells_holm_and_determinism(self):
        rng = random.Random(11)
        events, proxies = {"M5": [], "M15": []}, {"M5": [], "M15": []}
        for tf in ("M5", "M15"):
            for level in study.LEVELS:
                for i in range(160):
                    ny = "1" if i % 2 else "0"
                    events[tf].append(event(level, tf, ny=ny))
                    for r in study.R_TARGETS:
                        if level == "L2" and tf == "M5":                 # a clear edge: +0.8R every trade
                            net = 0.8
                        elif level == "L4":                              # clearly negative
                            net = -0.6 + rng.gauss(0, 0.2)
                        else:
                            net = rng.choice([-1.0, float(r)]) - 0.05 * r
                        proxies[tf].append(proxy(level, tf, r, day=1 + i % 28, net=net, ny=ny,
                                                 side="LONG" if i % 3 else "SHORT"))
        a = study.analyse_rows(events, proxies, 500, 20260929)
        b = study.analyse_rows(events, proxies, 500, 20260929)
        self.assertEqual(a, b)
        self.assertEqual(len(a), 48)
        self.assertEqual(a["L2|M5|FULL|R1"]["classification"], study.POSITIVE)
        self.assertEqual(a["L2|M5|NY|R3"]["classification"], study.INCONCLUSIVE)   # 80 fills < 100
        self.assertEqual(a["L4|M15|FULL|R2"]["classification"], study.NEGATIVE)
        self.assertIn(a["L1|M5|FULL|R2"]["classification"], (study.OPEN, study.NEGATIVE))
        self.assertEqual(a["L1|M5|FULL|R1"]["events"], 160)
        self.assertEqual(a["L1|M5|NY|R1"]["events"], 80)


class TestStudyMain(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="btb_study_")

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def write(self, name, cols, rows):
        with open(os.path.join(self.tmp, name), "w", encoding="utf-8") as f:
            f.write(",".join(cols) + "\n")
            for r in rows:
                f.write(",".join(r[c] for c in cols) + "\n")

    def test_writes_report(self):
        with open(os.path.join(self.tmp, "reference_config.json"), "w", encoding="utf-8") as f:
            json.dump({"timeframes": ["M5", "M15"]}, f)
        for tf in ("M5", "M15"):
            self.write(f"btb_events_{tf}.csv", EVENT_COLS, [event("L1", tf), event("L3", tf, ny="1")])
            self.write(f"btb_proxies_{tf}.csv", PROXY_COLS, [proxy("L1", tf, r, net=r) for r in (1, 2, 3)])
        with open(os.path.join(self.tmp, "btb_days.csv"), "w", encoding="utf-8") as f:
            f.write("date,weekday,session_start,ref_date,ref_spread_pts,ref_samples,resume_time,ny_start,status,m1_bars\n"
                    "2026-02-02,MONDAY,,,NA,0,,,WARMUP,10\n2026-02-03,TUESDAY,,,57.0,600,,,NORMAL,10\n")
        self.assertEqual(study.main([self.tmp, "--reps", "200"]), 0)
        with open(os.path.join(self.tmp, "python_reference", "report.json"), encoding="utf-8") as f:
            rep = json.load(f)
        self.assertEqual(len(rep["cells"]), 48)
        self.assertEqual(rep["summary"]["days"], {"NORMAL": 1, "WARMUP": 1})
        self.assertEqual(rep["summary"]["mean_reference_spread_pts"], 57.0)
        self.assertEqual(rep["classification_counts"], {study.INCONCLUSIVE: 48})
        with open(os.path.join(self.tmp, "python_reference", "report.md"), encoding="utf-8") as f:
            md = f.read()
        self.assertEqual(sum(1 for line in md.splitlines() if line[:4] in ("| L1", "| L2", "| L3", "| L4")), 48)


if __name__ == "__main__":
    unittest.main()


# ---------------------------------------------------------------------------------------------
# BTB-v2 (roadmap V4): Holm over 36 / 24 cells, holdout verdict, sample split
# ---------------------------------------------------------------------------------------------
V2_COLS = PROXY_COLS + ["mode", "dep_d", "sample", "arm_time", "n_legs", "n_pushes"]
SETUP_COLS = ["event_id", "tf", "level_type", "side", "sample", "break_bar_time", "limit_price", "zone_low", "zone_high",
              "pivots", "n_legs", "spike_time", "spike_price", "spike_depth_atr", "p1_time", "p1_price", "p2_time",
              "p2_price", "n_pushes", "slope", "first_live_bar", "last_live_bar", "end_bar_time", "status", "in_quarantine"]


def v2proxy(mode, tf="M5", r=1, sample="DESIGN", day=5, net=1.0, dep="NA", ny="0", state="FILLED", full="1",
            legs="NA", level="L1", side="LONG"):
    p = proxy(level, tf, r, day=day, net=net, state=state, side=side, ny=ny)
    month = "02" if sample == "DESIGN" else "08"
    p.update({"mode": mode, "dep_d": dep, "sample": sample, "arm_time": "2026-02-01T10:00:00.000" if mode != "E0" else "",
              "placement_time": "2026-02-01T10:00:00.000", "n_legs": legs, "n_pushes": "NA", "in_full": full,
              "fill_time": f"2026-{month}-{day:02d}T10:00:00.000", "spread_bucket": "5_8"})
    return p


def v2event(tf="M5", sample="DESIGN", ny="0", level="L1"):
    e = event(level, tf, ny=ny)
    e["break_bar_time"] = "2026-02-02T10:00:00" if sample == "DESIGN" else "2026-08-03T10:00:00"
    return e


def v2setup(tf="M5", sample="DESIGN", legs="3", status="LIVE_TO_FILL"):
    x = {k: "" for k in SETUP_COLS}
    x.update({"tf": tf, "level_type": "L1", "side": "LONG", "sample": sample, "n_legs": legs, "status": status,
              "in_quarantine": "0", "spike_time": "t", "p2_time": "t", "first_live_bar": "t"})
    return x


class TestStudyV2(unittest.TestCase):
    def test_sample_split_and_rows(self):
        self.assertEqual(study.sample_of_time("2026-06-30T23:55:00"), "DESIGN")
        self.assertEqual(study.sample_of_time("2026-07-01T00:00:00"), "HOLDOUT")
        ev = [v2event(), v2event(sample="HOLDOUT"), v2event(ny="1")]
        px = [v2proxy("E1", dep="1.0"), v2proxy("E1", dep="1.5"), v2proxy("E1", dep="1.0", sample="HOLDOUT", day=6),
              v2proxy("E0"), v2proxy("E2", full="1", ny="1"), v2proxy("E2", full="0", state="NO_SPIKE")]
        st = [v2setup(), v2setup(sample="HOLDOUT"), v2setup(legs="4")]
        e, p, a = study.v2_rows(ev, st, px, "E1", "FULL", 1, "DESIGN")
        self.assertEqual((len(e), len(p)), (2, 1))
        e, p, a = study.v2_rows(ev, st, px, "E1", "FULL", 1, "ALL")
        self.assertEqual((len(e), len(p)), (3, 2))
        e, p, a = study.v2_rows(ev, st, px, "E2", "NY", 1, "DESIGN")      # E2: events = setups, window by fill
        self.assertEqual((len(e), len(p), len(a)), (2, 1, 2))
        e, p, a = study.v2_rows(ev, st, px, "E2", "FULL", 1, "ALL", legs="4+")
        self.assertEqual(len(e), 1)
        e, p, a = study.v2_rows(ev, st, px, "E2", "FULL", 1, "ALL")
        self.assertEqual(study.funnel("E2", e, a, p), {"events": 3, "armed_or_live": 2, "filled": 1})

    def test_holdout_verdict_rules(self):
        d_pos = {"mean_net_r": 0.2}
        d_neg = {"mean_net_r": -0.1}
        h_ok = {"analysed": 30, "independent_days": 10}
        self.assertEqual(study.holdout_verdict(d_pos, h_ok, True), study.CONFIRMED)
        self.assertEqual(study.holdout_verdict(d_neg, h_ok, True), study.NOT_CONFIRMED)    # DESIGN mean must be > 0
        self.assertEqual(study.holdout_verdict(d_pos, h_ok, False), study.NOT_CONFIRMED)
        self.assertEqual(study.holdout_verdict(d_pos, {"analysed": 29, "independent_days": 40}, True), study.INCONCLUSIVE)
        self.assertEqual(study.holdout_verdict(d_pos, {"analysed": 90, "independent_days": 9}, True), study.INCONCLUSIVE)

    def build(self, e1_edge=0.8):
        rng = random.Random(5)
        events, setups, proxies = {"M5": [], "M15": []}, {"M5": [], "M15": []}, {"M5": [], "M15": []}
        for tf in ("M5", "M15"):
            for smp, n in (("DESIGN", 150), ("HOLDOUT", 60)):
                for i in range(n):
                    ny = "1" if i % 2 else "0"
                    events[tf].append(v2event(tf, smp, ny))
                    setups[tf].append(v2setup(tf, smp))
                    day = 1 + i % 25
                    for r in (1, 2, 3):
                        proxies[tf].append(v2proxy("E0", tf, r, smp, day, rng.choice([-1.0, float(r)]) - 0.3, ny=ny))
                        proxies[tf].append(v2proxy("E1", tf, r, smp, day, e1_edge, dep="1.0", ny=ny))
                        proxies[tf].append(v2proxy("E1", tf, r, smp, day, -0.5, dep="1.5", ny=ny))
                        proxies[tf].append(v2proxy("E2", tf, r, smp, day, rng.choice([-1.0, 1.0]), ny=ny, legs="3"))
        return events, setups, proxies

    def test_holm_families_and_verdicts(self):
        events, setups, proxies = self.build()
        a = study.analyse_v2_rows(events, setups, proxies, 300, 20260929)
        self.assertEqual(len(a), 36)
        self.assertEqual(sum(1 for c in a.values() if c["mode"] != "E0"), 24)
        c = a["E1|M5|FULL|R1"]
        self.assertEqual((c["design_classification"], c["holdout_verdict"]), (study.POSITIVE, study.CONFIRMED))
        self.assertEqual(c["samples"]["HOLDOUT"]["funnel"], {"events": 60, "armed_or_live": 60, "filled": 60})
        self.assertEqual(a["E1|M5|NY|R1"]["holdout_verdict"], study.CONFIRMED)          # 30 fills, 15 days
        self.assertTrue(all(x["holdout_verdict"] == study.BASELINE for x in a.values() if x["mode"] == "E0"))
        self.assertIn(a["E2|M5|FULL|R1"]["holdout_verdict"], (study.NOT_CONFIRMED, study.INCONCLUSIVE))
        # the same HOLDOUT data with a negative DESIGN mean is never confirmed
        for tf in ("M5", "M15"):
            for p in proxies[tf]:
                if p["mode"] == "E1" and p["dep_d"] == "1.0" and p["sample"] == "DESIGN":
                    p["net_r"] = "-0.2"
        b = study.analyse_v2_rows(events, setups, proxies, 300, 20260929)
        self.assertEqual(b["E1|M5|FULL|R1"]["holdout_verdict"], study.NOT_CONFIRMED)
        self.assertEqual(b["E1|M5|FULL|R1"]["design_classification"], study.NEGATIVE)

    def test_holm_over_24_not_36(self):
        # 23 E1/E2 cells with p = 0.5 and one with p = 0.05/24: significant in the 24-family,
        # although 0.05/24 > 0.05/36 would fail a 36-family first step.
        p = {f"c{i}": 0.5 for i in range(23)}
        p["x"] = 0.05 / 24
        self.assertTrue(study.holm_bonferroni(p)["x"])
        p36 = dict(p, **{f"e0_{i}": 0.5 for i in range(12)})
        self.assertFalse(study.holm_bonferroni(p36)["x"])

    def test_funnel_counts_armed_inside_the_window(self):
        full_only = {"arm_time": "2026-07-02T10:00:00", "placement_time": "2026-07-02T10:00:00", "state": "FILLED"}
        in_ny = dict(full_only)
        unarmed = {"arm_time": "", "placement_time": "", "state": "NOT_ARMED_WINDOW_END"}
        # NY cell: px_all holds every row of the mode, px only the NY rows
        for mode in ("E0", "E1"):
            f = study.funnel(mode, [1, 2], [full_only, in_ny, unarmed], [in_ny, unarmed])
            self.assertEqual((f["events"], f["armed_or_live"], f["filled"]), (2, 1, 1))
        # E2: an unfilled row has no window, so live rows are counted over all windows
        live_unfilled = {"arm_time": "2026-07-02T10:00:00", "state": "LINE_PASSED"}
        f = study.funnel("E2", [1], [live_unfilled], [])
        self.assertEqual((f["armed_or_live"], f["filled"]), (1, 0))

    def test_main_writes_v2_report(self):
        tmp = tempfile.mkdtemp(prefix="btb_v2_")
        try:
            events, setups, proxies = self.build()
            with open(os.path.join(tmp, "reference_config.json"), "w", encoding="utf-8") as f:
                json.dump({"timeframes": ["M5", "M15"]}, f)
            for tf in ("M5", "M15"):
                for name, cols, rows in ((f"btb_events_{tf}.csv", EVENT_COLS, events[tf]),
                                         (f"btb_proxies_{tf}.csv", V2_COLS, proxies[tf]),
                                         (f"btb_setups_E2_{tf}.csv", SETUP_COLS, setups[tf])):
                    with open(os.path.join(tmp, name), "w", encoding="utf-8") as f:
                        f.write(",".join(cols) + "\n" + "".join(",".join(r[c] for c in cols) + "\n" for r in rows))
            self.assertEqual(study.main([tmp, "--reps", "200"]), 0)
            with open(os.path.join(tmp, "python_reference", "report.json"), encoding="utf-8") as f:
                rep = json.load(f)
            self.assertEqual(len(rep["primary"]), 36)
            self.assertEqual(rep["e2_funnel"]["M5|HOLDOUT"]["setups"], 60)
            self.assertIn("E1|D1.5|M5|FULL|R1", rep["diagnostics"]["e1_dep"])
            with open(os.path.join(tmp, "python_reference", "report.md"), encoding="utf-8") as f:
                md = f.read()
            # 36 rows in the primary table + 36 rows in the exits-and-risk table
            self.assertEqual(sum(1 for line in md.splitlines() if line[:5] in ("| E0 ", "| E1 ", "| E2 ")), 72)
            self.assertIn("## Exits and risk per primary cell (DESIGN | HOLDOUT)", md)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)
