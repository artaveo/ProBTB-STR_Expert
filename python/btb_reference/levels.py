"""Independent Python reference for the BTB event layer (roadmap Sections 3 and 4).

It is written from the roadmap text, not translated from MQL5. Input is the M1
export of BTB_Expert (Bid bars built from ticks, plus the per-M1 spread sample =
Ask - Bid in points of the last tick of the minute) and the broker session
schedule. Output is btb_days.csv and btb_events_<TF>.csv, which must match the
EA's files byte for byte.

Standard library only.
"""

from __future__ import annotations

import hashlib
import time
from dataclasses import dataclass, field
from typing import Callable, Dict, List, Optional, Tuple

SECONDS_PER_DAY = 86400
ATR_PERIOD = 14
ID_HEX_CHARS = 16

TF_SECONDS = {"M1": 60, "M5": 300, "M15": 900, "M30": 1800, "H1": 3600}

# Section 3 (frozen)
LATE_BLOCK_SEC = 21 * 3600 + 30 * 60      # 21:30 — pending cancelled, positions closed, block starts
NY_START_SEC = 16 * 3600 + 30 * 60        # 16:30 — NY window start and resume deadline
REF_FROM_SEC = 10 * 3600                  # reference spread window [10:00, 21:30)
REF_TO_SEC = LATE_BLOCK_SEC
RESUME_MULT = 1.5
RESUME_BARS = 5
ASIAN_END_SEC = 8 * 3600                  # L2 range [ResumeTime, 08:00)

# Section 4 (frozen)
SWING_SIDE_BARS = 2
L3_LIFE_H1_BARS = 120
L4_MIN_N = 20
L4_MAX_N = 96
L4_ATR_MULT = 2.5
L4_COOLDOWN_BARS = 20

LEVEL_TYPES = ("L1", "L2", "L3", "L4")
LONG, SHORT = 1, -1

DAY_WARMUP = "WARMUP"
DAY_NO_SESSION = "NO_SESSION_START"
DAY_PENDING = "PENDING"
DAY_NORMAL = "NORMAL"
DAY_ABNORMAL = "ABNORMAL_SPREAD_DAY"

EVENT = "EVENT"
OPEN_BEYOND_LEVEL = "OPEN_BEYOND_LEVEL"
WARMUP = "WARMUP"
IN_QUARANTINE = "IN_QUARANTINE"

WEEKDAYS = ("SUNDAY", "MONDAY", "TUESDAY", "WEDNESDAY", "THURSDAY", "FRIDAY", "SATURDAY")

DAYS_HEADER = "date,weekday,session_start,ref_date,ref_spread_pts,ref_samples,resume_time,ny_start,status,m1_bars"
EVENTS_HEADER = ("event_id,tf,level_type,side,level_price,level_source_time,box_n,break_bar_time,break_close_time,"
                 "break_open,break_high,break_low,break_close,atr14,in_full,in_ny,status")


def iso_time(t: int) -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(t))


def iso_date(t: int) -> str:
    return time.strftime("%Y-%m-%d", time.gmtime(t))


def day_start(t: int) -> int:
    return t - (t % SECONDS_PER_DAY)


def day_of_week(t: int) -> int:
    """0 = Sunday ... 6 = Saturday (1970-01-01 was a Thursday)."""
    return (t // SECONDS_PER_DAY + 4) % 7


def side_name(side: int) -> str:
    return "LONG" if side > 0 else "SHORT"


def event_id(tf: str, level_type: str, side: int, source_time: int, bar_time: int) -> str:
    canonical = f"BTB|{tf}|{level_type}|{side_name(side)}|{iso_time(source_time)}|{iso_time(bar_time)}"
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()[:ID_HEX_CHARS]


def median(values: List[int]) -> float:
    s = sorted(values)
    n = len(s)
    if n % 2 == 1:
        return float(s[n // 2])
    return (s[n // 2 - 1] + s[n // 2]) / 2.0


@dataclass
class Bar:
    time: int
    period: int
    open: float
    high: float
    low: float
    close: float
    ticks: int
    spread: int = 0        # M1 only: spread sample in points (last tick of the minute)

    @property
    def close_time(self) -> int:
        return self.time + self.period


# ---------------------------------------------------------------------------
# Broker trade-session schedule (SymbolInfoSessionTrade as declared by the broker)
# ---------------------------------------------------------------------------
class Schedule:
    """Broker weekly schedule. A declared interval with to <= from wraps midnight into
    [from, 24:00) and a next-weekday continuation [00:00, to) that is not a session start."""

    def __init__(self, raw: List[Tuple[int, int, int]]):
        self.iv: List[List[Tuple[int, int, bool]]] = [[] for _ in range(7)]
        for dow, a, b in raw:
            self.add(dow, a, b)

    def _insert(self, dow: int, a: int, b: int, cont: bool) -> None:
        lst = self.iv[dow]
        pos = len(lst)
        while pos > 0 and lst[pos - 1][0] > a:
            pos -= 1
        lst.insert(pos, (a, b, cont))

    def add(self, dow: int, a: int, b: int) -> None:
        if not (0 <= dow <= 6 and 0 <= a < SECONDS_PER_DAY and 0 <= b <= SECONDS_PER_DAY) or a == b:
            raise ValueError(f"invalid session interval {dow} {a} {b}")
        if a < b:
            self._insert(dow, a, b, False)
            return
        self._insert(dow, a, SECONDS_PER_DAY, False)
        if b > 0:
            self._insert((dow + 1) % 7, 0, b, True)

    def is_in_session(self, t: int) -> bool:
        sod = t % SECONDS_PER_DAY
        return any(a <= sod < b for a, b, _ in self.iv[day_of_week(t)])

    def next_session_start_after(self, t: int) -> Optional[int]:
        day0 = day_start(t)
        for k in range(8):
            day = day0 + k * SECONDS_PER_DAY
            best = None
            for a, _, cont in self.iv[day_of_week(day)]:
                if cont:
                    continue
                s = day + a
                if s > t and (best is None or s < best):
                    best = s
            if best is not None:
                return best
        return None


# ---------------------------------------------------------------------------
# Section 3: late-spread block, spread-normal resume rule, windows
# ---------------------------------------------------------------------------
@dataclass
class DayRec:
    date: int
    session_start: int
    ref_date: int
    ref: Optional[float]
    ref_n: int
    status: str
    resume: int = 0
    run: int = 0
    samples: List[int] = field(default_factory=list)
    m1_bars: int = 0


class DayTracker:
    def __init__(self, sched: Schedule):
        self.sched = sched
        self.cur: Optional[DayRec] = None
        self.days: Dict[int, DayRec] = {}
        self.order: List[int] = []
        self.last_ref: Optional[Tuple[int, float, int]] = None   # (date, median, samples)

    def _start(self, d: int) -> None:
        s = self.sched.next_session_start_after(d - SECONDS_PER_DAY + LATE_BLOCK_SEC)
        if s is None or s < d or s >= d + SECONDS_PER_DAY:
            s = 0
        ref_date, ref, ref_n = self.last_ref if self.last_ref is not None else (0, None, 0)
        status = DAY_NO_SESSION if s == 0 else (DAY_WARMUP if ref is None else DAY_PENDING)
        rec = DayRec(d, s, ref_date, ref, ref_n, status)
        self.cur = rec
        self.days[d] = rec
        self.order.append(d)

    def _finalize(self, rec: DayRec) -> None:
        if rec.status == DAY_PENDING:
            rec.status = DAY_ABNORMAL
            rec.resume = rec.date + NY_START_SEC
        if rec.samples:
            self.last_ref = (rec.date, median(rec.samples), len(rec.samples))

    def on_m1(self, b: Bar) -> None:
        d = day_start(b.time)
        if self.cur is None or d != self.cur.date:
            if self.cur is not None:
                self._finalize(self.cur)
            self._start(d)
        rec = self.cur
        rec.m1_bars += 1
        sod = b.time - d
        if REF_FROM_SEC <= sod < REF_TO_SEC:
            rec.samples.append(b.spread)
        if rec.status == DAY_PENDING and b.time >= rec.session_start:
            rec.run = rec.run + 1 if b.spread <= RESUME_MULT * rec.ref else 0
            close = b.time + 60
            if rec.run >= RESUME_BARS and close <= d + NY_START_SEC:
                rec.status = DAY_NORMAL
                rec.resume = close
            elif close >= d + NY_START_SEC:
                rec.status = DAY_ABNORMAL
                rec.resume = d + NY_START_SEC

    def finish(self) -> None:
        if self.cur is not None:
            self._finalize(self.cur)

    def status(self, d: int) -> Optional[str]:
        rec = self.days.get(d)
        return rec.status if rec else None

    def resume_of(self, d: int) -> int:
        """ResumeTime of day d if it is known; 0 otherwise."""
        rec = self.days.get(d)
        if rec is None or rec.status not in (DAY_NORMAL, DAY_ABNORMAL):
            return 0
        return rec.resume

    def window(self, d: int, close: int) -> Tuple[bool, bool]:
        """(in_full, in_ny) of a breakout candle of day d that closes at `close`."""
        rec = self.days.get(d)
        if rec is None or rec.status in (DAY_WARMUP, DAY_NO_SESSION):
            return False, False
        if rec.status == DAY_PENDING:
            r = d + NY_START_SEC if close >= d + NY_START_SEC else 0
        else:
            r = rec.resume
        if r == 0:
            return False, False
        full = r <= close < d + LATE_BLOCK_SEC and self.sched.is_in_session(close)
        ny = full and close >= d + NY_START_SEC
        return full, ny

    def rows(self) -> List[str]:
        out = [DAYS_HEADER]
        for d in self.order:
            r = self.days[d]
            known = r.status in (DAY_NORMAL, DAY_ABNORMAL)
            out.append(",".join([
                iso_date(d), WEEKDAYS[day_of_week(d)],
                iso_time(r.session_start) if r.session_start > 0 else "",
                iso_date(r.ref_date) if r.ref is not None else "",
                f"{r.ref:.1f}" if r.ref is not None else "NA",
                str(r.ref_n),
                iso_time(r.resume) if known else "",
                iso_time(max(r.resume, d + NY_START_SEC)) if known else "",
                r.status, str(r.m1_bars)]))
        return out


# ---------------------------------------------------------------------------
# Section 4: level sources L1-L3 (shared by every signal timeframe)
# ---------------------------------------------------------------------------
@dataclass
class Level:
    type: str
    side: int
    price: float
    source_time: int
    avail: int
    valid_to: int        # L1/L2: bars with time >= valid_to are past the level's life; 0 = none
    expiry_h1: int       # L3: index of the H1 bar whose close ends the life; -1 = none


class TfAggregator:
    def __init__(self, period: int):
        self.period = period
        self.cur: Optional[Bar] = None

    def on_m1(self, m1: Bar) -> Optional[Bar]:
        bt = m1.time - (m1.time % self.period)
        done = None
        if self.cur is not None and bt != self.cur.time:
            done = self.cur
            self.cur = None
        if self.cur is None:
            self.cur = Bar(bt, self.period, m1.open, m1.high, m1.low, m1.close, m1.ticks)
        else:
            c = self.cur
            if m1.high > c.high:
                c.high = m1.high
            if m1.low < c.low:
                c.low = m1.low
            c.close = m1.close
            c.ticks += m1.ticks
        return done

    def complete_if_past(self, t: int) -> Optional[Bar]:
        """Tick-time completion (EA path): the bar is complete once t reaches its period end."""
        if self.cur is None or t < self.cur.time + self.period:
            return None
        done, self.cur = self.cur, None
        return done

    def flush(self) -> Optional[Bar]:
        done, self.cur = self.cur, None
        return done


class WilderAtr:
    def __init__(self, n: int):
        self.n = n
        self.count = 0
        self.sum = 0.0
        self.atr = 0.0
        self.have_prev = False
        self.prev_close = 0.0

    def update(self, b: Bar) -> None:
        tr = b.high - b.low
        if self.have_prev:
            a = abs(b.high - self.prev_close)
            c = abs(b.low - self.prev_close)
            if a > tr:
                tr = a
            if c > tr:
                tr = c
        self.prev_close = b.close
        self.have_prev = True
        self.count += 1
        if self.count < self.n:
            self.sum += tr
        elif self.count == self.n:
            self.sum += tr
            self.atr = self.sum / self.n
        else:
            self.atr = (self.atr * (self.n - 1) + tr) / self.n

    @property
    def ready(self) -> bool:
        return self.count >= self.n


class LevelSource:
    """PDH/PDL (L1), Asian range (L2) and H1 2/2 fractal swings (L3). Feed every M1 bar
    after the DayTracker has seen it."""

    def __init__(self, tracker: DayTracker):
        self.tracker = tracker
        self.levels: List[Level] = []
        self.first_date: Optional[int] = None
        self.day = 0
        self.have_day = False
        self.hi = 0.0
        self.lo = 0.0
        self.prev: Optional[Tuple[int, float, float]] = None   # last complete trading day (date, hi, lo)
        self.asian_have = False
        self.asian_done = False
        self.asian_hi = 0.0
        self.asian_lo = 0.0
        self.h1 = TfAggregator(3600)
        self.h1_bars: List[Bar] = []

    def _finish_asian(self) -> None:
        if not self.asian_done and self.asian_have:
            r = self.tracker.resume_of(self.day)
            d = self.day
            self.levels.append(Level("L2", LONG, self.asian_hi, r, d + ASIAN_END_SEC, d + LATE_BLOCK_SEC, -1))
            self.levels.append(Level("L2", SHORT, self.asian_lo, r, d + ASIAN_END_SEC, d + LATE_BLOCK_SEC, -1))
        self.asian_done = True

    def _on_h1(self, h: Bar) -> None:
        self.h1_bars.append(h)
        k = len(self.h1_bars) - 1
        c = k - SWING_SIDE_BARS
        if c - SWING_SIDE_BARS < 0:
            return
        bars = self.h1_bars
        is_high = all(bars[c].high > bars[j].high for j in range(c - SWING_SIDE_BARS, c + SWING_SIDE_BARS + 1) if j != c)
        is_low = all(bars[c].low < bars[j].low for j in range(c - SWING_SIDE_BARS, c + SWING_SIDE_BARS + 1) if j != c)
        avail = bars[k].time + 3600
        if is_high:
            self.levels.append(Level("L3", LONG, bars[c].high, bars[c].time, avail, 0, k + L3_LIFE_H1_BARS))
        if is_low:
            self.levels.append(Level("L3", SHORT, bars[c].low, bars[c].time, avail, 0, k + L3_LIFE_H1_BARS))

    def h1_close(self, i: int) -> int:
        return self.h1_bars[i].time + 3600

    def on_m1(self, b: Bar) -> None:
        d = day_start(b.time)
        if self.first_date is None:
            self.first_date = d
        if self.have_day and d != self.day:
            self._finish_asian()
            if self.day != self.first_date:
                self.prev = (self.day, self.hi, self.lo)
            self.have_day = False
        if not self.have_day:
            if self.prev is not None:
                pd, phi, plo = self.prev
                self.levels.append(Level("L1", LONG, phi, pd, d, d + SECONDS_PER_DAY, -1))
                self.levels.append(Level("L1", SHORT, plo, pd, d, d + SECONDS_PER_DAY, -1))
            self.day = d
            self.have_day = True
            self.hi = b.high
            self.lo = b.low
            self.asian_have = False
            self.asian_done = False
        else:
            if b.high > self.hi:
                self.hi = b.high
            if b.low < self.lo:
                self.lo = b.low
        if not self.asian_done:
            if b.time >= d + ASIAN_END_SEC:
                self._finish_asian()
            else:
                r = self.tracker.resume_of(d)
                if r > 0 and self.tracker.status(d) == DAY_NORMAL and b.time >= r:
                    if not self.asian_have:
                        self.asian_hi, self.asian_lo, self.asian_have = b.high, b.low, True
                    else:
                        if b.high > self.asian_hi:
                            self.asian_hi = b.high
                        if b.low < self.asian_lo:
                            self.asian_lo = b.low
        h = self.h1.on_m1(b)
        if h is not None:
            self._on_h1(h)


# ---------------------------------------------------------------------------
# Section 4: breakout events per signal timeframe
# ---------------------------------------------------------------------------
@dataclass
class Event:
    id: str
    level_type: str
    side: int
    level_price: float
    source_time: int
    box_n: int
    bar: Bar
    atr_ready: bool
    atr: float
    in_full: bool
    in_ny: bool
    status: str


class LevelEngine:
    def __init__(self, tf: str, source: LevelSource, tracker: DayTracker, digits: int):
        self.tf = tf
        self.period = TF_SECONDS[tf]
        self.source = source
        self.tracker = tracker
        self.digits = digits
        self.agg = TfAggregator(self.period)
        self.atr = WilderAtr(ATR_PERIOD)
        self.bars: List[Bar] = []
        self.events: List[Event] = []
        self.cursor = 0
        self.active: Dict[str, List[int]] = {"L1": [], "L2": [], "L3": []}
        self.l4_last = {LONG: -1000000, SHORT: -1000000}

    def _eligible(self, lv: Level, b: Bar) -> bool:
        return lv.avail <= b.time

    def _expired(self, lv: Level, b: Bar) -> bool:
        if lv.valid_to > 0 and b.time >= lv.valid_to:
            return True
        if lv.expiry_h1 >= 0 and len(self.source.h1_bars) > lv.expiry_h1 and self.source.h1_close(lv.expiry_h1) <= b.time:
            return True
        return False

    @staticmethod
    def _crosses(side: int, price: float, b: Bar) -> bool:
        return (b.open > price or b.close > price) if side > 0 else (b.open < price or b.close < price)

    @staticmethod
    def _breaks(side: int, price: float, b: Bar) -> bool:
        return (b.open <= price and b.close > price) if side > 0 else (b.open >= price and b.close < price)

    def _emit(self, level_type: str, side: int, price: float, source_time: int, box_n: int, b: Bar, breakout: bool,
              atr_ready: bool, atr: float, in_full: bool, in_ny: bool, day_status: Optional[str]) -> None:
        if not breakout:
            status = OPEN_BEYOND_LEVEL
        elif day_status == DAY_WARMUP:
            status = WARMUP
        else:
            status = EVENT
        eid = event_id(self.tf, level_type, side, source_time, b.time)
        self.events.append(Event(eid, level_type, side, price, source_time, box_n, b, atr_ready, atr, in_full, in_ny, status))

    def _process(self, b: Bar) -> None:
        k = len(self.bars)
        levels = self.source.levels
        while self.cursor < len(levels):
            lv = levels[self.cursor]
            if lv.type in self.active:
                self.active[lv.type].append(self.cursor)
            self.cursor += 1
        atr_ready = self.atr.ready
        atr = self.atr.atr
        d = day_start(b.time)
        in_full, in_ny = self.tracker.window(d, b.close_time)
        day_status = self.tracker.status(d)

        for lt in ("L1", "L2", "L3"):
            keep = [i for i in self.active[lt] if not self._expired(levels[i], b)]
            consumed = set()
            for side in (LONG, SHORT):
                cross = [i for i in keep if levels[i].side == side and self._eligible(levels[i], b)
                         and self._crosses(side, levels[i].price, b)]
                if not cross:
                    continue
                brk = [i for i in cross if self._breaks(side, levels[i].price, b)]
                pool = brk if brk else cross
                best = pool[0]
                for i in pool[1:]:
                    if (levels[i].price > levels[best].price) if side > 0 else (levels[i].price < levels[best].price):
                        best = i
                lv = levels[best]
                self._emit(lt, side, lv.price, lv.source_time, 0, b, bool(brk), atr_ready, atr, in_full, in_ny, day_status)
                consumed.update(cross)
            self.active[lt] = [i for i in keep if i not in consumed]

        # L4 consolidation box over bars [k-N, k-1]
        if k >= L4_MIN_N and atr_ready and atr > 0.0:
            thr = L4_ATR_MULT * atr
            hi = lo = 0.0
            best_n = 0
            top = bottom = 0.0
            for n in range(1, min(L4_MAX_N, k) + 1):
                x = self.bars[k - n]
                if n == 1:
                    hi, lo = x.high, x.low
                else:
                    if x.high > hi:
                        hi = x.high
                    if x.low < lo:
                        lo = x.low
                if hi - lo <= thr:
                    if n >= L4_MIN_N:
                        best_n, top, bottom = n, hi, lo
                else:
                    break
            if best_n >= L4_MIN_N:
                src = self.bars[k - best_n].time
                for side in (LONG, SHORT):
                    if k - self.l4_last[side] <= L4_COOLDOWN_BARS:
                        continue
                    price = top if side > 0 else bottom
                    if not self._crosses(side, price, b):
                        continue
                    brk = self._breaks(side, price, b)
                    self._emit("L4", side, price, src, best_n, b, brk, atr_ready, atr, in_full, in_ny, day_status)
                    if brk:
                        self.l4_last[side] = k

        self.atr.update(b)
        self.bars.append(b)

    def on_m1(self, m1: Bar) -> None:
        done = self.agg.on_m1(m1)
        if done is not None:
            self._process(done)

    def on_time(self, t: int) -> None:
        """EA tick path: completes the signal bar on the first tick at/after its close."""
        done = self.agg.complete_if_past(t)
        if done is not None:
            self._process(done)

    def flush(self) -> None:
        done = self.agg.flush()
        if done is not None:
            self._process(done)

    def ledger_lines(self, in_quarantine: Callable[[int, int], bool]) -> List[str]:
        dg = self.digits
        out = [EVENTS_HEADER]
        for e in self.events:
            b = e.bar
            status = e.status
            if status == EVENT and in_quarantine(b.time, b.close_time):
                status = IN_QUARANTINE
            atr_ok = e.atr_ready and e.atr > 0.0
            out.append(",".join([
                e.id, self.tf, e.level_type, side_name(e.side), f"{e.level_price:.{dg}f}", iso_time(e.source_time),
                str(e.box_n) if e.level_type == "L4" else "NA",
                iso_time(b.time), iso_time(b.close_time),
                f"{b.open:.{dg}f}", f"{b.high:.{dg}f}", f"{b.low:.{dg}f}", f"{b.close:.{dg}f}",
                f"{e.atr:.8f}" if atr_ok else "NA",
                "1" if e.in_full else "0", "1" if e.in_ny else "0", status]))
        return out


class Reference:
    """Whole event layer: one DayTracker, one LevelSource, one LevelEngine per signal timeframe."""

    def __init__(self, sched: Schedule, timeframes: List[str], digits: int):
        self.tracker = DayTracker(sched)
        self.source = LevelSource(self.tracker)
        self.engines = [LevelEngine(tf, self.source, self.tracker, digits) for tf in timeframes]

    def on_m1(self, b: Bar) -> None:
        self.tracker.on_m1(b)
        self.source.on_m1(b)
        for e in self.engines:
            e.on_m1(b)

    def finish(self) -> None:
        for e in self.engines:
            e.flush()
        self.tracker.finish()

    def run(self, bars: List[Bar]) -> "Reference":
        for b in bars:
            self.on_m1(b)
        self.finish()
        return self
