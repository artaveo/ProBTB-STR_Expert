"""BTB-v2 structure tools (roadmap PART 2, V3.1), independent Python reference.

ZigZag pivots with a reversal threshold Z = mult x ATR14(k), where ATR14(k) is the
Wilder ATR of the signal timeframe after bar k is included (k = the detecting bar),
and 2/2 fractal highs/lows (the LSR swing definition). Completed bars only.

Standard library only.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import List, Optional

from .levels import ATR_PERIOD, Bar, WilderAtr

PIVOT_HIGH = 1
PIVOT_LOW = -1


@dataclass
class Pivot:
    kind: int          # PIVOT_HIGH / PIVOT_LOW
    price: float
    bar: int           # index of the extreme bar (first on ties)
    conf: int          # index of the detecting bar; confirmation time = its close


@dataclass
class Fractal:
    price: float
    bar: int           # the fractal bar c
    conf: int          # c + 2; confirmed at that bar's close


class ZigZag:
    """Strictly alternating pivots.

    Before the first pivot, the candidates are the first bar's low and high. The first bar k >= 1
    with high >= low0 + Z confirms a pivot LOW at bar 0; with low <= high0 - Z a pivot HIGH at bar 0
    (LOW is tested first if both happen on one bar). Afterwards, in an up-swing the highest high HH
    since the last pivot is tracked (strictly greater replaces, so ties keep the first bar). A bar that
    makes a new HH continues the swing; any other bar with low <= HH - Z confirms the pivot high at HH
    (a bar is never both the extreme and its own reversal). The down-swing tracking then restarts over
    the bars after the pivot bar up to the detecting bar. Lows are mirrored. No reversal is detected
    while ATR14 is not ready.
    """

    def __init__(self, mult: float):
        self.mult = mult
        self.pivots: List[Pivot] = []
        self.bars: List[Bar] = []
        self.dir = 0
        self.ext: Optional[float] = None
        self.ext_bar = -1

    def _restart(self, direction: int, after: int, k: int) -> None:
        """Tracking of the new swing over bars after..k (exclusive of the pivot bar)."""
        self.dir = direction
        self.ext, self.ext_bar = None, -1
        for j in range(after + 1, k + 1):
            v = self.bars[j].high if direction > 0 else self.bars[j].low
            if self.ext is None or (v > self.ext if direction > 0 else v < self.ext):
                self.ext, self.ext_bar = v, j

    def on_bar(self, k: int, b: Bar, atr_ready: bool, atr: float) -> Optional[Pivot]:
        self.bars.append(b)
        if k == 0:
            return None
        if self.dir == 0:
            if not atr_ready:
                return None
            z = self.mult * atr
            b0 = self.bars[0]
            if b.high >= b0.low + z:
                pv = Pivot(PIVOT_LOW, b0.low, 0, k)
                self.pivots.append(pv)
                self._restart(1, 0, k)
                return pv
            if b.low <= b0.high - z:
                pv = Pivot(PIVOT_HIGH, b0.high, 0, k)
                self.pivots.append(pv)
                self._restart(-1, 0, k)
                return pv
            return None
        if self.dir > 0:
            if self.ext is None or b.high > self.ext:
                self.ext, self.ext_bar = b.high, k           # new extreme: the swing continues
            elif atr_ready and b.low <= self.ext - self.mult * atr:
                pv = Pivot(PIVOT_HIGH, self.ext, self.ext_bar, k)
                self.pivots.append(pv)
                self._restart(-1, pv.bar, k)
                return pv
        else:
            if self.ext is None or b.low < self.ext:
                self.ext, self.ext_bar = b.low, k
            elif atr_ready and b.high >= self.ext + self.mult * atr:
                pv = Pivot(PIVOT_LOW, self.ext, self.ext_bar, k)
                self.pivots.append(pv)
                self._restart(1, pv.bar, k)
                return pv
        return None


class Fractals:
    """2/2 fractals: bar c is a high fractal if its high is strictly above the highs of the two bars
    on each side (lows mirrored); confirmed at the close of bar c + 2."""

    def __init__(self, side_bars: int = 2):
        self.n = side_bars
        self.bars: List[Bar] = []
        self.highs: List[Fractal] = []
        self.lows: List[Fractal] = []

    def on_bar(self, k: int, b: Bar) -> None:
        self.bars.append(b)
        c = k - self.n
        if c - self.n < 0:
            return
        bars = self.bars
        others = [j for j in range(c - self.n, c + self.n + 1) if j != c]
        if all(bars[c].high > bars[j].high for j in others):
            self.highs.append(Fractal(bars[c].high, c, k))
        if all(bars[c].low < bars[j].low for j in others):
            self.lows.append(Fractal(bars[c].low, c, k))


class StructureFeed:
    """Per signal timeframe: bars, ATR14 after each bar, ZigZag pivots and fractals."""

    def __init__(self, zigzag_mult: float):
        self.bars: List[Bar] = []
        self.atr_ready: List[bool] = []
        self.atr: List[float] = []
        self._atr = WilderAtr(ATR_PERIOD)
        self.zz = ZigZag(zigzag_mult)
        self.fr = Fractals()

    def on_bar(self, b: Bar) -> int:
        k = len(self.bars)
        self.bars.append(b)
        self._atr.update(b)
        self.atr_ready.append(self._atr.ready)
        self.atr.append(self._atr.atr)
        self.zz.on_bar(k, b, self._atr.ready, self._atr.atr)
        self.fr.on_bar(k, b)
        return k
