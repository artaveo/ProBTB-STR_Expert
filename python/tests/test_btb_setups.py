"""Blocking tests for BTB-v2 (roadmap PART 2, V6): ZigZag, fractals, the E2 setup machine on the
owner's chart and its variants, trend-line gating, short mirrors, and the E1 arming geometry."""

import calendar
import os
import sys
import time
import unittest

sys.path.insert(0, os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")))
sys.path.insert(0, os.path.normpath(os.path.dirname(os.path.abspath(__file__))))

import btb_v2_fixtures as fx  # noqa: E402
from btb_reference import setups as su  # noqa: E402
from btb_reference.entries import arm_price, simulate_e1, stop_price  # noqa: E402
from btb_reference.levels import Bar, DayTracker, Schedule  # noqa: E402
from btb_reference.swings import PIVOT_HIGH, PIVOT_LOW, Fractal, Fractals, ZigZag  # noqa: E402


def B(i, h, l, o=None, c=None):
    o = l if o is None else o
    c = h if c is None else c
    return Bar(fx.T0 + i * 300, 300, o, h, l, c, 1)


def run(ohlc, side=1, tm=None, ev=fx.EVENT_BAR, tracker=None):
    e2 = su.E2Setups("M5", 300, 2, tracker=tracker)
    st = None
    tm = tm or fx.times(len(ohlc))
    for i, (o, h, l, c) in enumerate(ohlc):
        k = e2.on_bar(Bar(tm[i], 300, o, h, l, c, 1))
        if k == ev:
            st = e2.add_event("0123456789abcdef", "L1", side, k)
    e2.finish()
    return e2, st


class TestZigZag(unittest.TestCase):
    def test_pivots_ties_and_confirmation(self):
        zz = ZigZag(1.0)
        rows = [(10.0, 9.0), (10.5, 9.8), (11.0, 10.2), (11.0, 10.4), (10.8, 9.9), (10.2, 9.5), (10.5, 9.6),
                (12.0, 9.0), (11.5, 10.9)]
        got = []
        for i, (h, l) in enumerate(rows):
            pv = zz.on_bar(i, B(i, h, l), True, 1.0)
            if pv:
                got.append((pv.kind, pv.price, pv.bar, pv.conf))
        self.assertEqual(got, [
            (PIVOT_LOW, 9.0, 0, 1),      # first pivot: bar 0's low, reversed first by bar 1 (10.5 >= 9 + 1)
            (PIVOT_HIGH, 11.0, 2, 4),    # tie at 11.0 (bars 2, 3): the first bar; confirmed by bar 4 (9.9 <= 10)
            (PIVOT_LOW, 9.5, 5, 6),      # 10.5 >= 9.5 + 1 (boundary included)
            (PIVOT_HIGH, 12.0, 7, 8),    # bar 7 makes the new high: never its own reversal (low 9.0)
        ])

    def test_first_pivot_high_and_atr_gate(self):
        zz = ZigZag(1.0)
        out = [zz.on_bar(0, B(0, 10.0, 9.5), True, 1.0), zz.on_bar(1, B(1, 9.9, 8.9), False, 1.0),
               zz.on_bar(2, B(2, 9.8, 8.95), True, 1.0), zz.on_bar(3, B(3, 9.7, 8.5), True, 1.0)]
        self.assertIsNone(out[1])                                # ATR not ready: no reversal
        self.assertEqual((out[2].kind, out[2].price, out[2].bar, out[2].conf), (PIVOT_HIGH, 10.0, 0, 2))
        self.assertIsNone(out[3])                                # new low: the down-swing continues
        self.assertEqual((zz.ext, zz.ext_bar), (8.5, 3))

    def test_threshold_uses_the_detecting_bars_atr(self):
        zz = ZigZag(1.0)
        zz.on_bar(0, B(0, 10.0, 9.0), True, 5.0)
        self.assertIsNone(zz.on_bar(1, B(1, 10.5, 9.8), True, 2.0))     # 10.5 < 9.0 + 2.0
        pv = zz.on_bar(2, B(2, 10.5, 9.8), True, 1.5)                    # 10.5 >= 9.0 + 1.5
        self.assertEqual((pv.kind, pv.bar, pv.conf), (PIVOT_LOW, 0, 2))


class TestFractals(unittest.TestCase):
    def test_2_2_fractals(self):
        fr = Fractals()
        rows = [(5, 3), (6, 2), (8, 4), (7, 1), (6, 2), (9, 3), (7, 2.5)]
        for i, (h, l) in enumerate(rows):
            fr.on_bar(i, B(i, h, l))
        self.assertEqual([(f.price, f.bar, f.conf) for f in fr.highs], [(8, 2, 4)])
        self.assertEqual([(f.price, f.bar, f.conf) for f in fr.lows], [(1, 3, 5)])


class TestTrendLine(unittest.TestCase):
    def test_line_values(self):
        p1, p2 = Fractal(1997.3, 31, 33), Fractal(1996.9, 37, 39)
        self.assertAlmostEqual(su.line_y(p1, p2, 37), 1996.9)
        self.assertAlmostEqual(su.line_y(p1, p2, 40), 1996.7)
        self.assertAlmostEqual(su.line_y(p1, p2, 31), 1997.3)

    def test_live_gating_boundaries(self):
        P, tol = 2000.0, 0.5
        self.assertEqual(su.line_state(1, 2000.5, P, tol), su.LINE_LIVE)        # upper boundary included
        self.assertEqual(su.line_state(1, 1999.5, P, tol), su.LINE_LIVE)        # lower boundary included
        self.assertEqual(su.line_state(1, 2000.5 + 1e-9, P, tol), su.LINE_WAIT)
        self.assertEqual(su.line_state(1, 1999.5 - 1e-9, P, tol), su.LINE_GONE)
        self.assertEqual(su.line_state(-1, 2000.5, P, tol), su.LINE_LIVE)
        self.assertEqual(su.line_state(-1, 1999.5 - 1e-9, P, tol), su.LINE_WAIT)
        self.assertEqual(su.line_state(-1, 2000.5 + 1e-9, P, tol), su.LINE_GONE)


class TestOwnerChart(unittest.TestCase):
    def check_owner(self, side):
        ohlc = fx.OWNER if side > 0 else fx.mirror(fx.OWNER)
        e2, st = run(ohlc, side)
        self.assertEqual(st.status, su.LIVE_TO_FILL)
        self.assertEqual((st.n_legs, st.n_pushes), (3, 2))
        piv = e2.feed.zz.pivots
        self.assertEqual([(piv[i].bar) for i in st.seq], [18, 22, 23, 26, 27, 30])      # L0 H1 L1 H2 L2 H3
        self.assertEqual((st.spike_bar, st.p1.bar, st.p2.bar), (31, 31, 37))
        self.assertEqual((st.first_live, st.last_live, st.end_bar), (40, 41, 41))
        return e2, st

    def test_long(self):
        e2, st = self.check_owner(1)
        self.assertEqual((st.P, st.zlo, st.zhi), (1996.6, 1995.7, 1996.7))
        self.assertEqual((st.p1.price, st.p2.price), (1997.3, 1996.9))
        lines = e2.ledger_lines(lambda a, b: False)
        self.assertEqual(lines[0], su.SETUPS_HEADER)
        self.assertEqual(lines[1],
                         "0123456789abcdef,M5,L1,LONG,DESIGN,2026-01-07T03:35:00,1996.60,1995.70,1996.70,"
                         "2026-01-07T03:30:00@1995.70;2026-01-07T03:50:00@1999.10;2026-01-07T03:55:00@1997.30;"
                         "2026-01-07T04:10:00@1999.90;2026-01-07T04:15:00@1998.10;2026-01-07T04:30:00@2000.70,3,"
                         "2026-01-07T04:35:00,1997.30,3.235219,2026-01-07T04:35:00,1997.30,2026-01-07T05:05:00,1996.90,"
                         "2,-0.06666667,2026-01-07T05:20:00,2026-01-07T05:25:00,2026-01-07T05:25:00,LIVE_TO_FILL,0")

    def test_short_mirror(self):
        e2, st = self.check_owner(-1)
        self.assertEqual((st.P, st.zlo, st.zhi), (2003.4, 2003.3, 2004.3))
        self.assertEqual((st.p1.price, st.p2.price), (2002.7, 2003.1))


class TestVariants(unittest.TestCase):
    def status(self, ohlc, side=1, tm=None, ev=fx.EVENT_BAR):
        return run(ohlc if side > 0 else fx.mirror(ohlc), side, tm, ev)[1]

    def test_structure_failed_when_a_low_touches_the_zone(self):
        for side in (1, -1):
            st = self.status(fx.ZONE_TOUCH, side)
            self.assertEqual((st.status, st.n_legs, st.end_bar), (su.STRUCTURE_FAILED, 1, 25))

    def test_no_spike(self):
        for side in (1, -1):
            st = self.status(fx.NO_SPIKE, side)
            self.assertEqual((st.status, st.n_legs, st.spike_bar, st.end_bar), (su.NO_SPIKE, 3, -1, 35))

    def test_line_passed(self):
        for side in (1, -1):
            st = self.status(fx.LINE_PASSED, side)
            self.assertEqual((st.status, st.first_live, st.last_live, st.end_bar), (su.LINE_PASSED, 40, 46, 47))

    def test_expired_3_days(self):
        for side in (1, -1):
            st = self.status(fx.EXPIRED, side, fx.times(44, fx.EXPIRED_DAYS))
            self.assertEqual((st.status, st.end_bar, st.last_live), (su.EXPIRED_3_DAYS, 43, 42))

    def test_invalidated_before_fill(self):
        for side in (1, -1):
            st = self.status(fx.INVALIDATED, side)
            self.assertEqual((st.status, st.first_live, st.end_bar), (su.INVALIDATED_BEFORE_FILL, -1, 40))

    def test_no_leg1(self):
        for side in (1, -1):
            st = self.status(fx.OWNER, side, ev=17)                # breakout inside the down-swing
            self.assertEqual((st.status, st.end_bar), (su.NO_LEG1, 19))

    def test_end_of_data(self):
        st = self.status(fx.OWNER[:36])
        self.assertEqual((st.status, st.end_bar, st.n_pushes), (su.END_OF_DATA, 35, 1))

    def test_window_gates_live_bars(self):
        # A tracker whose day has no reference spread yet (warm-up) has no FULL window: never live.
        tr = DayTracker(Schedule([(d, 4500, 86400) for d in range(1, 6)]))
        tr.on_m1(Bar(fx.T0, 60, 1, 1, 1, 1, 1, 30))
        e2, st = run(fx.LINE_PASSED, 1, tracker=tr)
        self.assertEqual((st.status, st.first_live), (su.LINE_PASSED, -1))

    def test_sample_split(self):
        self.assertEqual(su.sample_of(calendar.timegm((2026, 6, 30, 23, 55, 0))), "DESIGN")
        self.assertEqual(su.sample_of(calendar.timegm((2026, 7, 1, 0, 0, 0))), "HOLDOUT")
        self.assertEqual(su.HOLDOUT_START, calendar.timegm(time.strptime("2026-07-01", "%Y-%m-%d")))


class TestE1Arming(unittest.TestCase):
    """Long: breakout bar low 1999.00 / high 2001.00, close P = 2000.50, reference spread 0.30
    -> SL_ref 1998.70, |P - SL_ref| = 1.80, arm price P + 1.80 = 2002.30 (D = 1.0)."""

    DUE = fx.T0 * 1000
    WEND = fx.T0 + 3600

    def e1(self, side, ticks, d=1.0):
        return simulate_e1(side, 2000.50 if side > 0 else 1999.50, 1999.00, 2001.00, d, self.DUE, self.WEND, ticks)

    def t(self, sec, bid, ask):
        return ((fx.T0 + sec) * 1000, bid, ask)

    def test_geometry(self):
        self.assertEqual(stop_price(1, 1999.0, 2001.0, 0.30000000000018, 0.01, 2), 1998.70)
        self.assertEqual(arm_price(1, 2000.50, 1998.70, 1.0, 0.01, 2), 2002.30)
        self.assertEqual(arm_price(1, 2000.50, 1998.70, 1.5, 0.01, 2), 2003.20)
        self.assertEqual(arm_price(1, 2000.50, 1998.70, 2.0, 0.01, 2), 2004.10)
        self.assertEqual(arm_price(-1, 1999.50, 2001.30, 1.0, 0.01, 2), 1997.70)

    def test_arming_boundary(self):
        base = [self.t(0, 2000.60, 2000.90)]
        r = self.e1(1, base + [self.t(10, 2002.29, 2002.59)])
        self.assertEqual((r.state, r.arm_tick), ("NOT_ARMED_END_OF_DATA", -1))      # 1 point short of P + Dep
        r = self.e1(1, base + [self.t(10, 2002.30, 2002.60), self.t(20, 2000.20, 2000.50)])
        self.assertEqual((r.state, r.arm_tick, r.fill_tick, r.sl), ("FILLED", 1, 2, 1998.70))

    def test_invalidated_before_arm_and_fill(self):
        base = [self.t(0, 2000.60, 2000.90)]
        r = self.e1(1, base + [self.t(10, 1998.70, 1999.00)])
        self.assertEqual(r.state, "INVALIDATED_BEFORE_ARM")
        r = self.e1(1, base + [self.t(10, 2002.30, 2002.60), self.t(20, 1998.60, 2000.51)])
        self.assertEqual(r.state, "INVALIDATED_BEFORE_FILL")        # stop reached, Ask never <= P

    def test_no_12_bar_expiry_and_2130_cancel(self):
        base = [self.t(0, 2000.60, 2000.90), self.t(10, 2002.30, 2002.60)]
        r = self.e1(1, base + [self.t(3000, 2001.0, 2001.3), self.t(3500, 2000.2, 2000.5)])   # 58 min later: fills
        self.assertEqual(r.state, "FILLED")
        r = self.e1(1, base + [self.t(3600, 2000.2, 2000.5)])
        self.assertEqual(r.state, "CANCELLED_WINDOW_END")
        r = self.e1(1, [self.t(0, 2000.60, 2000.90), self.t(3600, 2002.5, 2002.8)])
        self.assertEqual(r.state, "NOT_ARMED_WINDOW_END")

    def test_short_mirror(self):
        base = [self.t(0, 1999.40, 1999.70)]                   # SL_ref = 2001.00 + 0.30 = 2001.30, arm 1997.70
        r = self.e1(-1, base + [self.t(10, 1997.71, 1998.01)])
        self.assertEqual(r.state, "NOT_ARMED_END_OF_DATA")
        r = self.e1(-1, base + [self.t(10, 1997.70, 1998.00), self.t(20, 1999.50, 1999.80)])
        self.assertEqual((r.state, r.arm_price, r.sl), ("FILLED", 1997.70, 2001.30))
        r = self.e1(-1, base + [self.t(10, 2001.00, 2001.30)])
        self.assertEqual(r.state, "INVALIDATED_BEFORE_ARM")


if __name__ == "__main__":
    unittest.main()


class TestFixtureSyncAndPipeline(unittest.TestCase):
    def test_mql5_fixture_block_is_generated_from_these_fixtures(self):
        root = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
        sys.path.insert(0, os.path.join(root, "tools"))
        import gen_e2_fixtures  # noqa: E402
        with open(os.path.join(root, "MQL5", "Scripts", "ProBTB", "BTB_Tests.mq5"), "r", encoding="utf-8") as f:
            src = f.read()
        i = src.index(gen_e2_fixtures.BEGIN)
        j = src.index(gen_e2_fixtures.END) + len(gen_e2_fixtures.END)
        self.assertEqual(src[i:j], gen_e2_fixtures.block())

    def test_run_reference_reconciles_the_setup_ledger(self):
        import json
        import shutil
        import tempfile
        import test_btb_levels as tl
        from btb_reference import run_reference as rr
        tmp = tempfile.mkdtemp(prefix="btb_e2_pkg_")
        try:
            tl.write_package(tmp, tl.synthetic_bars())
            path = os.path.join(tmp, "reference_config.json")
            with open(path, encoding="utf-8") as f:
                rc = json.load(f)
            rc["e2"] = {"zigzag_atr": 1.0, "spike_atr": 2.0, "spike_bars": 3, "line_tol_atr": 0.5, "max_days": 3}
            with open(path, "w", encoding="utf-8") as f:
                json.dump(rc, f)
            _, files = rr.build(tmp)
            self.assertIn("btb_setups_E2_M5.csv", files)
            ev = [r for r in files["btb_events_M5.csv"].splitlines()[1:] if r.endswith(",EVENT")]
            setups = files["btb_setups_E2_M5.csv"].splitlines()
            self.assertEqual(setups[0], su.SETUPS_HEADER)
            self.assertEqual(len(setups) - 1, len(ev))                       # one setup per EVENT
            for name, text in files.items():
                with open(os.path.join(tmp, name), "wb") as f:
                    f.write(text.encode("utf-8"))
            self.assertEqual(rr.main([tmp, "--out", os.path.join(tmp, "py")]), 0)
            with open(os.path.join(tmp, "btb_setups_E2_M15.csv"), "ab") as f:
                f.write(b"x")
            self.assertEqual(rr.main([tmp, "--out", os.path.join(tmp, "py")]), 1)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)


class TestRegressionTool(unittest.TestCase):
    def test_e0_design_rows_against_part1(self):
        import json
        import shutil
        import tempfile
        from btb_reference import regression
        tmp = tempfile.mkdtemp(prefix="btb_reg_")
        try:
            p1, v2 = os.path.join(tmp, "p1"), os.path.join(tmp, "v2")
            os.makedirs(p1)
            os.makedirs(v2)
            with open(os.path.join(p1, "reference_config.json"), "w", encoding="utf-8") as f:
                json.dump({"timeframes": ["M5"]}, f)
            days_hdr = "date,weekday,session_start,ref_date,ref_spread_pts,ref_samples,resume_time,ny_start,status,m1_bars"
            ev_hdr = "event_id,tf,break_bar_time,status"
            px_hdr = "event_id,state,net_r"
            files1 = {"btb_days.csv": [days_hdr, "2026-06-30,TUESDAY,a,b,1.0,2,c,d,NORMAL,5"],
                      "btb_events_M5.csv": [ev_hdr, "e1,M5,2026-06-30T10:00:00,EVENT"],
                      "btb_proxies_M5.csv": [px_hdr, "e1,FILLED,1.0"]}
            files2 = {"btb_days.csv": files1["btb_days.csv"] + ["2026-07-01,WEDNESDAY,a,b,1.0,2,c,d,NORMAL,5"],
                      "btb_events_M5.csv": files1["btb_events_M5.csv"] + ["e2,M5,2026-07-01T10:00:00,EVENT"],
                      "btb_proxies_M5.csv": [px_hdr + ",mode,sample", "e1,FILLED,1.0,E0,DESIGN", "e1,FILLED,2.0,E1,DESIGN",
                                             "e2,FILLED,1.0,E0,HOLDOUT"]}
            for d, files in ((p1, files1), (v2, files2)):
                for name, lines in files.items():
                    with open(os.path.join(d, name), "w", encoding="utf-8") as f:
                        f.write("\n".join(lines) + "\n")
            self.assertEqual(regression.main([v2, p1]), 0)
            with open(os.path.join(v2, "btb_proxies_M5.csv"), "w", encoding="utf-8") as f:
                f.write(px_hdr + ",mode,sample\ne1,FILLED,1.1,E0,DESIGN\n")
            self.assertEqual(regression.main([v2, p1]), 1)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)
