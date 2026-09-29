"""BTB-v2 E2 setups (roadmap PART 2, V3), independent Python reference.

Three legs away from the breakout (ZigZag pivots), a spike against the last leg, pushes along a
trend line (2/2 fractals), and the order live only on bars where the line is at the breakeven.
Everything here is bar-derived (Bid bars of the signal timeframe, completed bars only), so
btb_setups_E2_<TF>.csv is reproduced byte for byte. The tick-level order is simulated in MQL5 only.

Per completed signal bar k, each setup is advanced in this order:
  0. 3-trading-day life: a bar on the 4th broker date after the breakout date ends the setup
     (EXPIRED_3_DAYS) before anything else.
  1. LINE phase: the bar is live if |y(k) - P| <= tol x ATR14(k-1) and the bar lies inside the FULL
     window; y(k) past the zone ends the setup (LINE_PASSED). At the close: a live bar that reached P
     ends the setup as LIVE_TO_FILL; a bar that reached the far side of the zone ends it as
     INVALIDATED_BEFORE_FILL.
  2. ZigZag pivots confirmed at bar k (leg 1, legs 2..n).
  3. Spike check over the first 3 bars after the last leg's extreme bar.
  4. Fractals confirmed at bar k (pushes p1, p2, rolls).
New setups are created after bar k from the EVENT rows of bar k and run steps 2-4 at once.

Standard library only. Shorts mirror longs exactly (sign s = -1).
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Callable, List, Optional

from .levels import (DAY_NO_SESSION, DAY_WARMUP, LATE_BLOCK_SEC, SECONDS_PER_DAY, Bar, DayTracker, day_start,
                     iso_time, side_name)
from .swings import PIVOT_HIGH, PIVOT_LOW, Fractal, Pivot, StructureFeed

HOLDOUT_START = 1782864000        # 2026-07-01T00:00:00 broker time (roadmap V1)

# V5 frozen parameters (EA inputs with these defaults)
E2_ZIGZAG_ATR = 1.0
E2_SPIKE_ATR = 2.0
E2_SPIKE_BARS = 3
E2_LINE_TOL_ATR = 0.5
E2_MAX_DAYS = 3
E2_MIN_LEGS = 3

PH_WAIT_LEG1, PH_LEGS, PH_PUSH1, PH_PUSH2, PH_LINE, PH_DONE = range(6)

LIVE_TO_FILL = "LIVE_TO_FILL"
STRUCTURE_FAILED = "STRUCTURE_FAILED"
NO_SPIKE = "NO_SPIKE"
LINE_PASSED = "LINE_PASSED"
EXPIRED_3_DAYS = "EXPIRED_3_DAYS"
INVALIDATED_BEFORE_FILL = "INVALIDATED_BEFORE_FILL"
NO_LEG1 = "NO_LEG1"
END_OF_DATA = "END_OF_DATA"

SPIKE_NONE, SPIKE_PENDING, SPIKE_FOUND, SPIKE_NOT_FOUND = range(4)

SETUPS_HEADER = ("event_id,tf,level_type,side,sample,break_bar_time,limit_price,zone_low,zone_high,pivots,n_legs,"
                 "spike_time,spike_price,spike_depth_atr,p1_time,p1_price,p2_time,p2_price,n_pushes,slope,"
                 "first_live_bar,last_live_bar,end_bar_time,status,in_quarantine")


def sample_of(bar_time: int) -> str:
    return "DESIGN" if bar_time < HOLDOUT_START else "HOLDOUT"


LINE_GONE, LINE_WAIT, LINE_LIVE = -1, 0, 1


def line_y(p1: Fractal, p2: Fractal, k: int) -> float:
    """Trend line through (bar(p1), p1) and (bar(p2), p2) at bar index k."""
    slope = (p2.price - p1.price) / (p2.bar - p1.bar)
    return p2.price + slope * (k - p2.bar)


def line_state(side: int, y: float, P: float, tol: float) -> int:
    """LINE_LIVE when |y - P| <= tol (both boundaries included); LINE_GONE when the line is past the
    zone (y < P - tol for a long, y > P + tol for a short); otherwise LINE_WAIT."""
    if (y < P - tol) if side > 0 else (y > P + tol):
        return LINE_GONE
    return LINE_LIVE if abs(y - P) <= tol else LINE_WAIT


@dataclass
class E2Config:
    zigzag_atr: float = E2_ZIGZAG_ATR
    spike_atr: float = E2_SPIKE_ATR
    spike_bars: int = E2_SPIKE_BARS
    line_tol_atr: float = E2_LINE_TOL_ATR
    max_days: int = E2_MAX_DAYS


@dataclass
class Setup:
    event_id: str
    level_type: str
    side: int
    b: int
    P: float
    zlo: float
    zhi: float
    phase: int = PH_WAIT_LEG1
    status: str = ""
    pc: int = 0                        # pivot cursor
    prev_pivot: int = -1               # WAIT_LEG1: previous pivot index
    seq: List[int] = field(default_factory=list)       # consumed pivots L0, H1, L1, H2, ...
    n_legs: int = 0
    last_leg: int = -1
    last_pull: int = -1                # last pull pivot after L0 (the higher-low reference)
    pull_after: int = -1               # pull pivot after the last leg once n_legs >= 3
    spike_state: int = SPIKE_NONE
    spike_next: int = 0
    spike_bar: int = -1
    spike_price: float = 0.0
    spike_depth: float = 0.0
    fc: int = 0                        # fractal cursor (pull fractals)
    p1: Optional[Fractal] = None
    p2: Optional[Fractal] = None
    n_pushes: int = 0
    first_live: int = -1
    last_live: int = -1
    end_bar: int = -1
    last_date: int = 0
    days_seen: int = 0


class E2Setups:
    def __init__(self, tf: str, period: int, digits: int, cfg: E2Config = None,
                 tracker: Optional[DayTracker] = None):
        self.tf = tf
        self.period = period
        self.digits = digits
        self.cfg = cfg or E2Config()
        self.tracker = tracker
        self.feed = StructureFeed(self.cfg.zigzag_atr)
        self.setups: List[Setup] = []

    # --- helpers ---------------------------------------------------------------------------
    def _beyond(self, s: int, a: float, b: float) -> bool:
        """a is strictly beyond b in the setup direction (above for long)."""
        return a > b if s > 0 else a < b

    def _zone_edge(self, st: Setup) -> float:
        """Near edge of the zone seen from the move away (zone top for long)."""
        return st.zhi if st.side > 0 else st.zlo

    def _end(self, st: Setup, status: str, k: int) -> None:
        st.status = status
        st.phase = PH_DONE
        st.end_bar = k

    def window_ok(self, k: int, open_time: int) -> bool:
        if self.tracker is None:
            return True
        d = day_start(open_time)
        full, _ = self.tracker.window(d, open_time)
        return full and open_time + self.period <= d + LATE_BLOCK_SEC

    def expired_at(self, st: Setup, open_time: int) -> bool:
        d = day_start(open_time)
        seen = st.days_seen + (1 if d != st.last_date else 0)
        return seen > self.cfg.max_days

    def live_at(self, st: Setup, k: int, open_time: int) -> int:
        """Line test for bar k, decided at its open from known values (line, ATR14(k-1), window).
        Returns LINE_LIVE, LINE_WAIT or LINE_GONE (the line has passed the zone)."""
        if k < 1 or not self.feed.atr_ready[k - 1]:
            return LINE_WAIT
        state = line_state(st.side, line_y(st.p1, st.p2, k), st.P, self.cfg.line_tol_atr * self.feed.atr[k - 1])
        if state == LINE_LIVE and not self.window_ok(k, open_time):
            return LINE_WAIT
        return state

    # --- steps -----------------------------------------------------------------------------
    def _step_line(self, st: Setup, k: int) -> None:
        b = self.feed.bars[k]
        live = self.live_at(st, k, b.time)
        if live == LINE_GONE:
            self._end(st, LINE_PASSED, k)
            return
        if live == LINE_LIVE:
            if st.first_live < 0:
                st.first_live = k
            st.last_live = k
            if (b.low <= st.P) if st.side > 0 else (b.high >= st.P):
                self._end(st, LIVE_TO_FILL, k)
                return
        if (b.low <= st.zlo) if st.side > 0 else (b.high >= st.zhi):
            self._end(st, INVALIDATED_BEFORE_FILL, k)

    def _pivot_valid_pull(self, st: Setup, pv: Pivot) -> bool:
        if not self._beyond(st.side, pv.price, self._zone_edge(st)):
            return False
        if st.last_pull >= 0 and not self._beyond(st.side, pv.price, self.feed.zz.pivots[st.last_pull].price):
            return False
        return True

    def _start_spike(self, st: Setup) -> None:
        st.spike_state = SPIKE_PENDING
        st.spike_next = self.feed.zz.pivots[st.last_leg].bar + 1
        st.pull_after = -1

    def _consume_pivot(self, st: Setup, idx: int, k: int) -> None:
        pivots = self.feed.zz.pivots
        pv = pivots[idx]
        s = st.side
        leg_kind = PIVOT_HIGH if s > 0 else PIVOT_LOW
        if st.phase == PH_WAIT_LEG1:
            prev = pivots[st.prev_pivot] if st.prev_pivot >= 0 else None
            if prev is not None and prev.kind == -leg_kind and pv.kind == leg_kind and prev.bar <= st.b <= pv.bar:
                st.seq = [st.prev_pivot, idx]
                st.n_legs = 1
                st.last_leg = idx
                st.phase = PH_LEGS
                return
            if pv.bar > st.b:
                self._end(st, NO_LEG1, k)
                return
            st.prev_pivot = idx
            return
        # PH_LEGS
        if pv.kind != leg_kind:                     # pull pivot
            st.seq.append(idx)
            if st.n_legs < E2_MIN_LEGS:
                if not self._pivot_valid_pull(st, pv):
                    self._end(st, STRUCTURE_FAILED, k)
                    return
                st.last_pull = idx
            else:
                st.pull_after = idx
                if st.spike_state == SPIKE_NOT_FOUND and not self._pivot_valid_pull(st, pv):
                    self._end(st, NO_SPIKE, k)
            return
        # leg pivot
        higher = self._beyond(s, pv.price, pivots[st.last_leg].price)
        if st.n_legs < E2_MIN_LEGS:
            st.seq.append(idx)
            if not higher:
                self._end(st, STRUCTURE_FAILED, k)
                return
            st.n_legs += 1
            st.last_leg = idx
            if st.n_legs >= E2_MIN_LEGS:
                self._start_spike(st)
            return
        # n_legs >= 3: a new higher leg continues the legs, otherwise no spike
        pull_ok = st.pull_after >= 0 and self._pivot_valid_pull(st, pivots[st.pull_after])
        st.seq.append(idx)
        if higher and pull_ok:
            st.last_pull = st.pull_after
            st.n_legs += 1
            st.last_leg = idx
            self._start_spike(st)
        else:
            self._end(st, NO_SPIKE, k)

    def _step_spike(self, st: Setup, k: int) -> None:
        if st.phase != PH_LEGS or st.spike_state != SPIKE_PENDING:
            return
        feed = self.feed
        hn = feed.zz.pivots[st.last_leg]
        last = hn.bar + self.cfg.spike_bars
        if not feed.atr_ready[hn.bar]:
            st.spike_state = SPIKE_NOT_FOUND
        else:
            thr = self.cfg.spike_atr * feed.atr[hn.bar]
            j = st.spike_next
            while j <= min(k, last):
                x = feed.bars[j]
                hit = (x.low <= hn.price - thr) if st.side > 0 else (x.high >= hn.price + thr)
                if hit:
                    st.spike_state = SPIKE_FOUND
                    st.spike_bar = j
                    st.spike_price = x.low if st.side > 0 else x.high
                    st.spike_depth = abs(hn.price - st.spike_price) / feed.atr[hn.bar]
                    break
                j += 1
            st.spike_next = j
            if st.spike_state == SPIKE_PENDING and j > last:
                st.spike_state = SPIKE_NOT_FOUND
        if st.spike_state == SPIKE_FOUND:
            st.phase = PH_PUSH1
            st.fc = 0
        elif st.spike_state == SPIKE_NOT_FOUND and st.pull_after >= 0 and \
                not self._pivot_valid_pull(st, feed.zz.pivots[st.pull_after]):
            self._end(st, NO_SPIKE, k)

    def _between(self, st: Setup, a: int, b: int) -> bool:
        """A confirmed opposite fractal strictly between bars a and b."""
        opp = self.feed.fr.highs if st.side > 0 else self.feed.fr.lows
        return any(a < f.bar < b for f in opp)

    def _step_fractals(self, st: Setup, k: int) -> None:
        if st.phase not in (PH_PUSH1, PH_PUSH2, PH_LINE):
            return
        pull = self.feed.fr.lows if st.side > 0 else self.feed.fr.highs
        hn_bar = self.feed.zz.pivots[st.last_leg].bar
        s = st.side
        while st.fc < len(pull) and st.phase != PH_DONE:
            f = pull[st.fc]
            st.fc += 1
            if f.bar <= hn_bar:
                continue
            in_zone = not self._beyond(s, f.price, self._zone_edge(st))
            if st.phase == PH_PUSH1:
                if in_zone:
                    self._end(st, STRUCTURE_FAILED, k)
                    return
                st.p1, st.n_pushes, st.phase = f, 1, PH_PUSH2
            elif st.phase == PH_PUSH2:
                if in_zone:
                    self._end(st, STRUCTURE_FAILED, k)
                    return
                if self._beyond(s, st.p1.price, f.price):          # f lower than p1 (long)
                    if self._between(st, st.p1.bar, f.bar):
                        st.p2, st.n_pushes, st.phase = f, 2, PH_LINE
                    else:
                        st.p1 = f                                   # push 1 extends
                else:
                    st.p1 = f                                       # higher low: push 1 restarts
            else:                                                   # PH_LINE
                if in_zone or not self._beyond(s, st.p2.price, f.price):
                    continue
                if self._between(st, st.p2.bar, f.bar):
                    st.p1, st.p2 = st.p2, f
                    st.n_pushes += 1
                else:
                    st.p2 = f

    def _step_expiry(self, st: Setup, k: int) -> None:
        d = day_start(self.feed.bars[k].time)
        if d != st.last_date:
            st.days_seen += 1
            st.last_date = d
        if st.days_seen > self.cfg.max_days:
            self._end(st, EXPIRED_3_DAYS, k)

    def _advance_structure(self, st: Setup, k: int) -> None:
        pivots = self.feed.zz.pivots
        while st.phase in (PH_WAIT_LEG1, PH_LEGS) and st.pc < len(pivots):
            idx = st.pc
            st.pc += 1
            self._consume_pivot(st, idx, k)
        if st.phase == PH_DONE:
            return
        self._step_spike(st, k)
        if st.phase == PH_DONE:
            return
        self._step_fractals(st, k)

    # --- driving ---------------------------------------------------------------------------
    def on_bar(self, b: Bar) -> int:
        k = self.feed.on_bar(b)
        for st in self.setups:
            if st.phase == PH_DONE:
                continue
            self._step_expiry(st, k)
            if st.phase == PH_DONE:
                continue
            if st.phase == PH_LINE:
                self._step_line(st, k)
                if st.phase == PH_DONE:
                    continue
            self._advance_structure(st, k)
        return k

    def add_event(self, event_id: str, level_type: str, side: int, k: int) -> Setup:
        """A Part 1 EVENT on bar k (the last bar fed): the setup starts at once."""
        b = self.feed.bars[k]
        st = Setup(event_id, level_type, side, k, b.close, b.low, b.high)
        st.last_date = day_start(b.time)
        self.setups.append(st)
        self._advance_structure(st, k)
        return st

    def finish(self) -> None:
        last = len(self.feed.bars) - 1
        for st in self.setups:
            if st.phase != PH_DONE:
                self._end(st, END_OF_DATA, last)

    # --- ledger ----------------------------------------------------------------------------
    def ledger_lines(self, in_quarantine: Callable[[int, int], bool]) -> List[str]:
        dg = self.digits
        bars = self.feed.bars
        piv = self.feed.zz.pivots
        out = [SETUPS_HEADER]

        def t(k: int) -> str:
            return iso_time(bars[k].time) if k >= 0 else ""

        for st in self.setups:
            bt = bars[st.b].time
            seq = ";".join(f"{iso_time(bars[piv[i].bar].time)}@{piv[i].price:.{dg}f}" for i in st.seq)
            spike = st.spike_bar >= 0
            slope = ((st.p2.price - st.p1.price) / (st.p2.bar - st.p1.bar)) if st.p2 is not None else None
            out.append(",".join([
                st.event_id, self.tf, st.level_type, side_name(st.side), sample_of(bt), iso_time(bt),
                f"{st.P:.{dg}f}", f"{st.zlo:.{dg}f}", f"{st.zhi:.{dg}f}", seq, str(st.n_legs),
                t(st.spike_bar) if spike else "", f"{st.spike_price:.{dg}f}" if spike else "NA",
                f"{st.spike_depth:.6f}" if spike else "NA",
                t(st.p1.bar) if st.p1 else "", f"{st.p1.price:.{dg}f}" if st.p1 else "NA",
                t(st.p2.bar) if st.p2 else "", f"{st.p2.price:.{dg}f}" if st.p2 else "NA",
                str(st.n_pushes), f"{slope:.8f}" if slope is not None else "NA",
                t(st.first_live), t(st.last_live), t(st.end_bar), st.status,
                "1" if in_quarantine(bt, bt + self.period) else "0"]))
        return out


def build_e2(engine, tracker: Optional[DayTracker], cfg: E2Config = None) -> E2Setups:
    """Replays a finished levels.LevelEngine: its bars in order, and after bar k the EVENT rows of bar k."""
    e2 = E2Setups(engine.tf, engine.period, engine.digits, cfg, tracker)
    by_bar = {}
    for ev in engine.events:
        if ev.status == "EVENT":
            by_bar.setdefault(ev.bar.time, []).append(ev)
    for b in engine.bars:
        k = e2.on_bar(b)
        for ev in by_bar.get(b.time, []):
            e2.add_event(ev.id, ev.level_type, ev.side, k)
    e2.finish()
    return e2
