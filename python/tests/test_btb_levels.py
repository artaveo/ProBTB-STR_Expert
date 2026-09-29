"""Blocking tests for the BTB event layer reference (roadmap Sections 3, 4 and 7)."""

import calendar
import json
import os
import random
import shutil
import sys
import tempfile
import time
import unittest

sys.path.insert(0, os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")))

from btb_reference import levels as lv  # noqa: E402
from btb_reference import run_reference as rr  # noqa: E402
from btb_reference.levels import (Bar, DayTracker, LevelEngine, LevelSource, Reference, Schedule,  # noqa: E402
                                  event_id)


def T(s: str) -> int:
    return calendar.timegm(time.strptime(s, "%Y-%m-%d %H:%M"))


GOLD = [(d, 4500, 86400) for d in range(1, 6)]          # Mon-Fri 01:15-24:00 (FundedNext XAUUSD)


def m1(t, o, h, l, c, spread=30):
    return Bar(t, 60, o, h, l, c, 1, spread)


def flat_day(date: str, price: float = 2000.0, spread: int = 30, start="01:15", end="23:59", early_spread=None,
             early_until=None):
    """One M1 bar per minute, OHLC flat at `price` (+/-0.05)."""
    bars = []
    t = T(f"{date} {start}")
    stop = T(f"{date} {end}")
    while t <= stop:
        sp = spread
        if early_spread is not None and t < T(f"{date} {early_until}"):
            sp = early_spread
        bars.append(m1(t, price, price + 0.05, price - 0.05, price, sp))
        t += 60
    return bars


class TestSchedule(unittest.TestCase):
    def test_gold_schedule(self):
        s = Schedule(GOLD)
        self.assertTrue(s.is_in_session(T("2026-01-05 01:15")))
        self.assertFalse(s.is_in_session(T("2026-01-05 01:14")))
        self.assertFalse(s.is_in_session(T("2026-01-10 12:00")))
        self.assertEqual(s.next_session_start_after(T("2026-01-05 21:30")), T("2026-01-06 01:15"))
        self.assertEqual(s.next_session_start_after(T("2026-01-09 21:30")), T("2026-01-12 01:15"))
        self.assertEqual(s.next_session_start_after(T("2026-01-06 01:15")), T("2026-01-07 01:15"))

    def test_wrapped_interval(self):
        s = Schedule([(0, 23 * 3600, 22 * 3600)])        # Sunday 23:00 -> Monday 22:00
        self.assertTrue(s.is_in_session(T("2026-01-05 00:30")))
        self.assertFalse(s.is_in_session(T("2026-01-05 22:00")))
        # the Monday [00:00, 22:00) half is a continuation, never a session start
        self.assertEqual(s.next_session_start_after(T("2026-01-04 23:30")), T("2026-01-11 23:00"))

    def test_day_of_week(self):
        self.assertEqual(lv.day_of_week(T("2026-01-05 00:00")), 1)
        self.assertEqual(lv.day_of_week(T("2026-01-04 12:00")), 0)


class TestResumeRule(unittest.TestCase):
    def run_days(self, bars):
        tr = DayTracker(Schedule(GOLD))
        for b in bars:
            tr.on_m1(b)
        return tr

    def test_first_day_is_warmup(self):
        tr = self.run_days(flat_day("2026-01-05"))
        tr.finish()
        self.assertEqual(tr.status(T("2026-01-05 00:00")), lv.DAY_WARMUP)
        self.assertEqual(tr.window(T("2026-01-05 00:00"), T("2026-01-05 12:00")), (False, False))

    def test_reference_median_and_resume(self):
        day1 = flat_day("2026-01-05", spread=30)
        # day 2: 01:15-01:59 wide (100), then normal; resume after 5 normal bars from 02:00 -> close 02:05
        day2 = flat_day("2026-01-06", spread=40, early_spread=100, early_until="02:00")
        tr = self.run_days(day1 + day2)
        tr.finish()
        d2 = T("2026-01-06 00:00")
        rec = tr.days[d2]
        self.assertEqual(rec.ref, 30.0)
        self.assertEqual(rec.ref_n, 690)                  # M1 samples in [10:00, 21:30)
        self.assertEqual(rec.status, lv.DAY_NORMAL)       # 40 <= 1.5 * 30
        self.assertEqual(rec.resume, T("2026-01-06 02:05"))

    def test_threshold_is_inclusive_and_run_resets(self):
        day1 = flat_day("2026-01-05", spread=20)
        day2 = flat_day("2026-01-06", spread=30)          # 30 == 1.5 * 20 -> qualifies
        t0 = T("2026-01-06 01:17")
        for b in day2:
            if b.time == t0:
                b.spread = 31                             # breaks the first run
        tr = self.run_days(day1 + day2)
        rec = tr.days[T("2026-01-06 00:00")]
        # bars 01:15, 01:16 ok, 01:17 bad, then 01:18..01:22 -> close 01:23
        self.assertEqual(rec.resume, T("2026-01-06 01:23"))

    def test_abnormal_day(self):
        day1 = flat_day("2026-01-05", spread=20)
        day2 = flat_day("2026-01-06", spread=20, early_spread=90, early_until="16:26")
        tr = self.run_days(day1 + day2)
        rec = tr.days[T("2026-01-06 00:00")]
        # normal from 16:26: 16:26..16:30 -> close 16:31 > 16:30 -> abnormal, resume 16:30
        self.assertEqual(rec.status, lv.DAY_ABNORMAL)
        self.assertEqual(rec.resume, T("2026-01-06 16:30"))
        d = T("2026-01-06 00:00")
        self.assertEqual(tr.window(d, T("2026-01-06 16:25")), (False, False))
        self.assertEqual(tr.window(d, T("2026-01-06 16:30")), (True, True))

    def test_resume_exactly_at_1630_is_normal(self):
        day1 = flat_day("2026-01-05", spread=20)
        day2 = flat_day("2026-01-06", spread=20, early_spread=90, early_until="16:25")
        tr = self.run_days(day1 + day2)
        rec = tr.days[T("2026-01-06 00:00")]
        self.assertEqual((rec.status, rec.resume), (lv.DAY_NORMAL, T("2026-01-06 16:30")))

    def test_windows(self):
        tr = self.run_days(flat_day("2026-01-05", spread=20) + flat_day("2026-01-06", spread=20))
        d = T("2026-01-06 00:00")
        self.assertEqual(tr.days[d].resume, T("2026-01-06 01:20"))
        self.assertEqual(tr.window(d, T("2026-01-06 01:15")), (False, False))
        self.assertEqual(tr.window(d, T("2026-01-06 01:20")), (True, False))
        self.assertEqual(tr.window(d, T("2026-01-06 16:29")), (True, False))
        self.assertEqual(tr.window(d, T("2026-01-06 16:30")), (True, True))
        self.assertEqual(tr.window(d, T("2026-01-06 21:29")), (True, True))
        self.assertEqual(tr.window(d, T("2026-01-06 21:30")), (False, False))

    def test_reference_skips_days_without_samples(self):
        day1 = flat_day("2026-01-05", spread=20)
        day2 = flat_day("2026-01-06", spread=50, end="09:00")      # no sample in [10:00, 21:30)
        day3 = flat_day("2026-01-07", spread=25)
        tr = self.run_days(day1 + day2 + day3)
        self.assertEqual(tr.days[T("2026-01-07 00:00")].ref_date, T("2026-01-05 00:00"))
        self.assertEqual(tr.days[T("2026-01-07 00:00")].ref, 20.0)

    def test_even_median(self):
        self.assertEqual(lv.median([30, 20, 25, 26]), 25.5)
        self.assertEqual(lv.median([3]), 3.0)

    def test_no_session_start_day(self):
        tr = self.run_days(flat_day("2026-01-09", spread=20) + flat_day("2026-01-10", spread=20, start="10:00", end="11:00"))
        tr.finish()
        self.assertEqual(tr.status(T("2026-01-10 00:00")), lv.DAY_NO_SESSION)


class Harness:
    """Tracker + source + one engine (M5) fed with M1 bars."""

    def __init__(self, tf="M5"):
        self.ref = Reference(Schedule(GOLD), [tf], 2)
        self.eng = self.ref.engines[0]

    def feed(self, bars):
        for b in bars:
            self.ref.on_m1(b)

    def events(self, kind=None):
        return [e for e in self.eng.events if kind is None or e.level_type == kind]


def bar5(date_hm, o, h, l, c, spread=20):
    """One M5 bar made of five M1 bars: open, high, low, then close."""
    t = T(date_hm)
    return [m1(t, o, o, o, o, spread), m1(t + 60, o, h, o if o < h else h, h, spread),
            m1(t + 120, h, h, l, l, spread), m1(t + 180, l, l, l, l, spread), m1(t + 240, l, c if c > l else l, c, c, spread)]


class TestLevels(unittest.TestCase):
    def base(self):
        # Mon (source excluded: first data day), Tue (PDH/PDL source), Wed (trading day)
        return flat_day("2026-01-05", 2000.0, 20) + flat_day("2026-01-06", 2000.0, 20)

    def test_event_id_is_stable_sha256_prefix(self):
        self.assertEqual(event_id("M5", "L1", 1, T("2026-01-06 00:00"), T("2026-01-07 10:00")),
                         "6f9e405d28b397e2")

    def test_l1_breakout_and_consumption(self):
        h = Harness()
        wed = flat_day("2026-01-07", 2000.0, 20, end="09:59")
        h.feed(self.base() + wed)
        pdh = 2000.05
        h.feed(bar5("2026-01-07 10:00", 2000.00, 2000.40, 1999.90, 2000.30))    # breaks PDH
        h.feed(bar5("2026-01-07 10:05", 2000.30, 2000.10, 1999.00, 1999.10))    # back below
        h.feed(bar5("2026-01-07 10:10", 2000.00, 2000.50, 1999.90, 2000.40))    # would break again: consumed
        h.feed([m1(T("2026-01-07 10:15"), 2000.4, 2000.4, 2000.4, 2000.4, 20)])
        ev = h.events("L1")
        longs = [e for e in ev if e.side == 1]
        self.assertEqual(len(longs), 1)
        e = longs[0]
        self.assertEqual((e.level_price, e.status, e.bar.time), (pdh, lv.EVENT, T("2026-01-07 10:00")))
        self.assertEqual((e.in_full, e.in_ny), (True, False))
        self.assertEqual(e.source_time, T("2026-01-06 00:00"))
        shorts = [x for x in ev if x.side == -1]
        self.assertEqual([x.bar.time for x in shorts], [T("2026-01-07 10:05")])   # PDL 1999.95 broken down

    def test_l1_open_beyond_consumes(self):
        h = Harness()
        h.feed(self.base() + flat_day("2026-01-07", 2001.0, 20, end="09:59"))      # whole morning above PDH
        h.feed(bar5("2026-01-07 10:00", 2001.00, 2001.20, 2000.90, 2001.10))
        longs = [e for e in h.events("L1") if e.side == 1]
        self.assertEqual(len(longs), 1)
        self.assertEqual(longs[0].status, lv.OPEN_BEYOND_LEVEL)
        self.assertEqual(longs[0].bar.time, T("2026-01-07 01:15"))

    def test_open_equal_to_level_is_breakout(self):
        h = Harness()
        wed = flat_day("2026-01-07", 2000.0, 20, end="09:59")
        h.feed(self.base() + wed)
        h.feed(bar5("2026-01-07 10:00", 2000.05, 2000.40, 2000.00, 2000.30))
        h.feed([m1(T("2026-01-07 10:05"), 2000.3, 2000.3, 2000.3, 2000.3, 20)])
        longs = [e for e in h.events("L1") if e.side == 1]
        self.assertEqual([e.status for e in longs], [lv.EVENT])

    def test_wick_only_is_not_a_breakout(self):
        h = Harness()
        wed = flat_day("2026-01-07", 2000.0, 20, end="09:59")
        h.feed(self.base() + wed)
        h.feed(bar5("2026-01-07 10:00", 2000.00, 2000.60, 1999.99, 2000.05))    # close == PDH: not > level
        h.feed([m1(T("2026-01-07 10:05"), 2000.0, 2000.0, 2000.0, 2000.0, 20)])
        self.assertEqual([e for e in h.events("L1") if e.side == 1], [])

    def test_l2_asian_range(self):
        h = Harness()
        wed = flat_day("2026-01-07", 2000.0, 20, end="07:59")
        wed[100].high = 2003.00                     # inside [resume, 08:00)
        wed[0].high = 2009.00                       # 01:15, before resume (01:20): excluded
        h.feed(self.base() + wed)
        h.feed(flat_day("2026-01-07", 2000.0, 20, start="08:00", end="08:59"))
        h.feed(bar5("2026-01-07 09:00", 2000.00, 2003.50, 1999.90, 2003.20))
        h.feed([m1(T("2026-01-07 09:05"), 2003.2, 2003.2, 2003.2, 2003.2, 20)])
        l2 = [e for e in h.events("L2") if e.side == 1]
        self.assertEqual(len(l2), 1)
        self.assertEqual((l2[0].level_price, l2[0].source_time), (2003.00, T("2026-01-07 01:20")))

    def test_l2_not_usable_before_0800(self):
        h = Harness()
        wed = flat_day("2026-01-07", 2000.0, 20, end="07:54")
        h.feed(self.base() + wed)
        h.feed(bar5("2026-01-07 07:55", 2000.00, 2003.50, 1999.90, 2003.20))    # completes at 08:00
        h.feed([m1(T("2026-01-07 08:00"), 2003.2, 2003.2, 2003.2, 2003.2, 20)])
        self.assertEqual(h.events("L2"), [])

    def test_l3_swing_breakout_farthest_and_expiry(self):
        src = LevelSource(DayTracker(Schedule(GOLD)))
        hours = [(2000, 2001), (2000, 2003), (2000, 2005), (2000, 2002), (2000, 2001)]
        t = T("2026-01-06 02:00")
        for i, (lo, hi) in enumerate(hours + [(2000, 2001)]):
            src.tracker.on_m1(m1(t + i * 3600, lo, hi, lo, lo))
            src.on_m1(m1(t + i * 3600, lo, hi, lo, lo))
        l3 = [x for x in src.levels if x.type == "L3"]
        self.assertEqual(len(l3), 1)
        self.assertEqual((l3[0].side, l3[0].price, l3[0].source_time), (1, 2005, t + 2 * 3600))
        self.assertEqual(l3[0].avail, t + 5 * 3600)                   # close of the second right bar
        self.assertEqual(l3[0].expiry_h1, 4 + 120)

    def l4_run(self):
        h = Harness()
        h.feed(self.base() + flat_day("2026-01-07", 2000.0, 20, end="09:59"))
        self.assertEqual(h.events("L4"), [])                     # flat bars inside the box: no crossing
        h.feed(bar5("2026-01-07 10:00", 2000.00, 2000.12, 1999.98, 2000.10))    # breaks the box top 2000.05
        h.feed(bar5("2026-01-07 10:05", 2000.10, 2000.10, 1999.88, 1999.90))    # breaks the box bottom 1999.95
        h.feed(bar5("2026-01-07 10:10", 1999.90, 2000.25, 1999.90, 2000.20))    # crosses the top again (2000.12)
        h.feed([m1(T("2026-01-07 10:15"), 2000.2, 2000.2, 2000.2, 2000.2, 20)])
        return h.events("L4")

    def test_l4_box_and_cooldown(self):
        l4 = self.l4_run()
        self.assertEqual([(e.side, e.bar.time, e.status) for e in l4],
                         [(1, T("2026-01-07 10:00"), lv.EVENT), (-1, T("2026-01-07 10:05"), lv.EVENT)])
        self.assertEqual(l4[0].box_n, 96)
        self.assertEqual(l4[0].level_price, 2000.05)
        self.assertEqual(l4[0].source_time, T("2026-01-07 10:00") - 96 * 300)
        self.assertEqual((l4[1].level_price, l4[1].box_n), (1999.95, 96))

    def test_l4_cooldown_is_what_blocks_the_third_break(self):
        saved = lv.L4_COOLDOWN_BARS
        try:
            lv.L4_COOLDOWN_BARS = 0
            l4 = self.l4_run()
        finally:
            lv.L4_COOLDOWN_BARS = saved
        self.assertEqual([(e.side, e.bar.time) for e in l4],
                         [(1, T("2026-01-07 10:00")), (-1, T("2026-01-07 10:05")), (1, T("2026-01-07 10:10"))])
        self.assertEqual(l4[2].level_price, 2000.12)

    def test_l4_needs_compression(self):
        h = Harness()
        t = T("2026-01-07 01:15")
        bars = []
        for i in range(400):                         # steady trend: +0.20 per minute
            p = round(2000.0 + 0.2 * i, 2)
            bars.append(m1(t + i * 60, p, round(p + 0.05, 2), round(p - 0.05, 2), p, 20))
        h.feed(bars)
        self.assertEqual(h.events("L4"), [])

    def test_windows_on_events_and_warmup(self):
        h = Harness()
        mon = flat_day("2026-01-05", 2000.0, 20, end="09:59")
        h.feed(mon)
        h.feed(bar5("2026-01-05 10:00", 2000.00, 2000.80, 1999.98, 2000.70))
        h.feed([m1(T("2026-01-05 10:05"), 2000.7, 2000.7, 2000.7, 2000.7, 20)])
        l4 = h.events("L4")
        self.assertEqual([e.status for e in l4], [lv.WARMUP])
        self.assertEqual((l4[0].in_full, l4[0].in_ny), (False, False))


def synthetic_bars(seed=20260929, days=("2026-01-05", "2026-01-06", "2026-01-07", "2026-01-08", "2026-01-09", "2026-01-12")):
    """Random-walk Bid M1 bars with a realistic spread profile (wide at the open and after 21:30)."""
    rng = random.Random(seed)
    bars = []
    p = 2650.00
    for i, date in enumerate(days):
        t = T(f"{date} 01:15")
        end = T(f"{date} 23:59")
        while t <= end:
            if rng.random() < 0.02:              # missing minutes (no ticks)
                t += 60
                continue
            sod = t % 86400
            base = 28 if i != 3 else 70          # day 4: abnormal all day
            if sod < 2 * 3600 or sod >= 21 * 3600 + 30 * 60:
                base = 90
            spread = base + rng.randint(-4, 4)
            o = round(p, 2)
            moves = [rng.gauss(0, 0.35) for _ in range(3)]
            path = [o]
            for m in moves:
                path.append(round(path[-1] + m, 2))
            c = path[-1]
            bars.append(m1(t, o, max(path), min(path), c, spread))
            p = c
            t += 60
    return bars


def write_package(dirpath, bars, quarantine=""):
    with open(os.path.join(dirpath, "reference_config.json"), "w", encoding="utf-8") as f:
        json.dump({"contract_id": "TEST", "symbol": "XAUUSD", "digits": 2, "point": 0.01, "strategy_pip_size": 0.1,
                   "m1_bars_file": "bars_M1_BID.csv", "session_file": "session_schedule.csv", "timeframes": ["M5", "M15"],
                   "quarantine_file": "data_quarantine_windows.csv", "declared_quarantine_file": ""}, f)
    with open(os.path.join(dirpath, "session_schedule.csv"), "w", encoding="utf-8") as f:
        f.write("weekday,from_sec,to_sec\n" + "".join(f"{d},{a},{b}\n" for d, a, b in GOLD))
    with open(os.path.join(dirpath, "bars_M1_BID.csv"), "w", encoding="utf-8") as f:
        f.write(rr.M1_HEADER + "\n")
        for b in bars:
            f.write(f"{lv.iso_time(b.time)},{b.open:.2f},{b.high:.2f},{b.low:.2f},{b.close:.2f},{b.ticks},{b.spread}\n")
    with open(os.path.join(dirpath, "data_quarantine_windows.csv"), "w", encoding="utf-8") as f:
        f.write("# from,to_exclusive,reason (Broker Server Time)\n" + quarantine)


class TestPipeline(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="btb_pkg_")

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_synthetic_package_is_deterministic_and_reconciles(self):
        write_package(self.tmp, synthetic_bars(), "2026.01.08 00:00:00,2026.01.09 00:00:00,PFM_NO_TICKS_NO_BAR\n")
        rc, files = rr.build(self.tmp)
        rc2, files2 = rr.build(self.tmp)
        self.assertEqual(files, files2)
        self.assertEqual(sorted(files), ["btb_days.csv", "btb_events_M15.csv", "btb_events_M5.csv"])
        # the "MQL5" side is the reference itself here: reconciliation must pass...
        for name, text in files.items():
            with open(os.path.join(self.tmp, name), "wb") as f:
                f.write(text.encode("utf-8"))
        out = os.path.join(self.tmp, "py")
        self.assertEqual(rr.main([self.tmp, "--out", out]), 0)
        # ...and one changed byte must fail it
        with open(os.path.join(self.tmp, "btb_events_M5.csv"), "ab") as f:
            f.write(b"x")
        self.assertEqual(rr.main([self.tmp, "--out", out]), 1)

        days = files["btb_days.csv"].splitlines()
        self.assertEqual(days[0], lv.DAYS_HEADER)
        status = [r.split(",")[8] for r in days[1:]]
        self.assertEqual(status, ["WARMUP", "NORMAL", "NORMAL", "ABNORMAL_SPREAD_DAY", "NORMAL", "NORMAL"])
        resume = [r.split(",")[6] for r in days[1:]]
        self.assertTrue(all(x.endswith(("T02:04:00", "T02:05:00", "T02:06:00", "T02:07:00", "T02:08:00"))
                            for x in resume[1:3]), resume)
        self.assertEqual(resume[3], "2026-01-08T16:30:00")

        ev = [r.split(",") for r in files["btb_events_M5.csv"].splitlines()[1:]]
        hdr = lv.EVENTS_HEADER.split(",")
        col = {k: i for i, k in enumerate(hdr)}
        kinds = {r[col["level_type"]] for r in ev}
        self.assertEqual(kinds, {"L1", "L2", "L3", "L4"})
        statuses = {r[col["status"]] for r in ev}
        self.assertIn("EVENT", statuses)
        self.assertIn("IN_QUARANTINE", statuses)
        for r in ev:
            close = rr.parse_iso(r[col["break_close_time"]])
            sod = close % 86400
            if r[col["in_ny"]] == "1":
                self.assertEqual(r[col["in_full"]], "1")
                self.assertTrue(16 * 3600 + 1800 <= sod < 21 * 3600 + 1800)
            if r[col["in_full"]] == "1":
                self.assertLess(sod, 21 * 3600 + 1800)
            if r[col["status"]] == "IN_QUARANTINE":
                self.assertTrue(r[col["break_bar_time"]].startswith("2026-01-08"))
        ids = [r[0] for r in ev]
        self.assertEqual(len(ids), len(set(ids)))

    def test_m1_header_is_checked(self):
        write_package(self.tmp, synthetic_bars(days=("2026-01-05",)))
        with open(os.path.join(self.tmp, "bars_M1_BID.csv"), "w", encoding="utf-8") as f:
            f.write("time,open,high,low,close,ticks\n")
        with self.assertRaises(ValueError):
            rr.build(self.tmp)


if __name__ == "__main__":
    unittest.main()


class M1Builder:
    """Bid M1 bars from ticks (TRE_M1Builder semantics) for the tick-path test."""

    def __init__(self):
        self.cur = None

    def on_quote(self, t: int, bid: float):
        bt = t - t % 60
        done = None
        if self.cur is not None and bt != self.cur.time:
            done, self.cur = self.cur, None
        if self.cur is None:
            self.cur = Bar(bt, 60, bid, bid, bid, bid, 1)
        else:
            self.cur.high = max(self.cur.high, bid)
            self.cur.low = min(self.cur.low, bid)
            self.cur.close = bid
            self.cur.ticks += 1
        return done


def lcg_fixture():
    """Same walk as TestBtbTickPath in BTB_Tests.mq5: one tick per minute at :30."""
    x = 20260929
    price = 2650.00
    out = []
    for day in ("2026-01-05", "2026-01-06", "2026-01-07", "2026-01-08"):
        d = T(f"{day} 00:00")
        t = d + 4500
        while t <= d + 86340:
            x = (x * 1103515245 + 12345) % 2147483648
            if x % 50 == 0:
                t += 60
                continue
            price = round(price + ((x // 7) % 21 - 10) * 0.07, 2)
            sod = t - d
            sp = 90 if (sod < 2 * 3600 or sod >= lv.LATE_BLOCK_SEC) else 28 + x % 5
            out.append((t, price, sp))
            t += 60
    return out


class TestTickPath(unittest.TestCase):
    """The EA completes signal bars on the first tick at/after their close (OnTime); the
    replay and this reference complete them on the next M1 bar. The ledgers must be equal."""

    def test_tick_path_equals_m1_path(self):
        fx = lcg_fixture()
        a = Reference(Schedule(GOLD), ["M5", "M15"], 2)
        for t, p, sp in fx:
            a.on_m1(m1(t, p, p, p, p, sp))
        a.finish()

        b = Reference(Schedule(GOLD), ["M5", "M15"], 2)
        builder = M1Builder()
        last_spread = 0
        for t, p, sp in fx:
            tick_t = t + 30
            done = builder.on_quote(tick_t, p)
            if done is not None:
                done.spread = last_spread
                b.on_m1(done)
            last_spread = sp
            for e in b.engines:
                e.on_time(tick_t)
        done = builder.cur
        done.spread = last_spread
        b.on_m1(done)
        b.finish()

        none = (lambda x, y: False)
        self.assertGreater(len(a.engines[0].events), 10)
        self.assertEqual(a.tracker.rows(), b.tracker.rows())
        for ea, eb in zip(a.engines, b.engines):
            self.assertEqual(ea.ledger_lines(none), eb.ledger_lines(none))
