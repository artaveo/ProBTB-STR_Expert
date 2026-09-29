"""BTB-v2 E1 order before the fill (roadmap PART 2, V2) — a compact Python mirror of the MQL5
tick logic, used by the blocking tests to check the arming geometry independently.

E1 ("move away first, then come back"): after the breakout close the order is not placed until
the Bid has moved Dep = D x |P - SL_ref| away from P (P + Dep for a long, P - Dep for a short).
SL_ref is the Part 1 stop computed with the spread of the first tick at/after the breakout close
(the reference tick). The arming tick is the placement tick; the stop is recomputed there with
its own spread (5.2). Before arming a stop trigger ends the setup (INVALIDATED_BEFORE_ARM). Once
armed the limit lives until filled, until the stop trigger (INVALIDATED_BEFORE_FILL) or until
21:30 (CANCELLED_WINDOW_END). No 12-bar expiry, no MISSED_TP_FIRST.

Standard library only.
"""

from __future__ import annotations

import math
from dataclasses import dataclass
from typing import List, Optional, Tuple

WAIT_REF, WAIT_ARM, PENDING, DONE = range(4)


def align_down(x: float, tick: float, digits: int) -> float:
    return round(math.floor(x / tick + 1e-9) * tick, digits)


def align_up(x: float, tick: float, digits: int) -> float:
    return round(math.ceil(x / tick - 1e-9) * tick, digits)


def stop_price(side: int, bar_low: float, bar_high: float, s0: float, tick: float, digits: int) -> float:
    """Part 1 stop (5.2): beyond the breakout extreme by the live spread, aligned outward."""
    return align_down(bar_low - s0, tick, digits) if side > 0 else align_up(bar_high + s0, tick, digits)


def arm_price(side: int, P: float, sl_ref: float, d: float, tick: float, digits: int) -> float:
    """P +/- D x |P - SL_ref|, aligned away from P (the move is never shorter than Dep)."""
    dep = d * abs(P - sl_ref)
    return align_up(P + dep, tick, digits) if side > 0 else align_down(P - dep, tick, digits)


@dataclass
class E1Result:
    state: str
    sl_ref: Optional[float] = None
    arm_price: Optional[float] = None
    arm_tick: int = -1
    sl: Optional[float] = None
    fill_tick: int = -1
    end_tick: int = -1


def simulate_e1(side: int, P: float, bar_low: float, bar_high: float, d: float, due_msc: int, window_end: int,
                ticks: List[Tuple[int, float, float]], tick: float = 0.01, digits: int = 2) -> E1Result:
    """ticks: (time_msc, bid, ask). Returns the order's state up to the fill (exits are Part 1)."""
    res = E1Result("NOT_PLACED_END_OF_DATA")
    phase = WAIT_REF
    for i, (msc, bid, ask) in enumerate(ticks):
        t = msc // 1000
        if phase == WAIT_REF:
            if msc < due_msc:
                continue
            res.sl_ref = stop_price(side, bar_low, bar_high, ask - bid, tick, digits)
            res.arm_price = arm_price(side, P, res.sl_ref, d, tick, digits)
            res.state = "NOT_ARMED_END_OF_DATA"
            phase = WAIT_ARM
        if phase == WAIT_ARM:
            if t >= window_end:
                return E1Result("NOT_ARMED_WINDOW_END", res.sl_ref, res.arm_price, end_tick=i)
            if (bid <= res.sl_ref) if side > 0 else (ask >= res.sl_ref):
                return E1Result("INVALIDATED_BEFORE_ARM", res.sl_ref, res.arm_price, end_tick=i)
            if (bid >= res.arm_price) if side > 0 else (bid <= res.arm_price):
                res.arm_tick = i
                res.sl = stop_price(side, bar_low, bar_high, ask - bid, tick, digits)
                res.state = "NOT_FILLED_END_OF_DATA"
                phase = PENDING
            else:
                continue
        if phase == PENDING:
            if t >= window_end:
                res.state, res.end_tick = "CANCELLED_WINDOW_END", i
                return res
            if (ask <= P) if side > 0 else (bid >= P):
                res.state, res.fill_tick = "FILLED", i
                return res
            if (bid <= res.sl) if side > 0 else (ask >= res.sl):
                res.state, res.end_tick = "INVALIDATED_BEFORE_FILL", i
                return res
    return res
