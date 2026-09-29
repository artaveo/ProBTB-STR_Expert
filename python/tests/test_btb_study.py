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
