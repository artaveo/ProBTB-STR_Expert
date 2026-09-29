"""Day-block bootstrap statistics (roadmap 1.2 and 6).

`day_block_bootstrap_upper` is ported verbatim from LSR a6ad185
(python/lsr_reference/event_study.py); `tools/tre_port.py verify` checks that
its source text is identical. The helpers below it are new for BTB-3 and use
exactly the same resampling sequence, so the p-value and the upper bound of one
cell come from the same bootstrap draws.

A row is a dict with "entry_time" (ISO broker time; the first 10 characters are
the broker day) and "net_r".
"""

from __future__ import annotations

import math
import random
from collections import defaultdict
from typing import Dict, List, Sequence, Tuple

CONFIDENCE = 0.95         # one-sided confidence level (LSR EarlyStopConfidenceLevel)
DEFAULT_REPS = 10000
DEFAULT_SEED = 20260929


def day_block_bootstrap_upper(rows: List[dict], reps: int, seed: int, confidence: float = CONFIDENCE) -> dict:
    """One-sided upper bound of mean NetR by resampling broker days with replacement (0C.15)."""
    by_day: Dict[str, List[float]] = defaultdict(list)
    for r in rows:
        by_day[r["entry_time"][:10]].append(float(r["net_r"]))
    days = sorted(by_day)
    sums = [sum(by_day[d]) for d in days]
    counts = [len(by_day[d]) for d in days]
    if not days:
        return {"upper": None, "lower": None, "reps": reps, "seed": seed}
    rng = random.Random(seed)
    k = len(days)
    means = []
    for _ in range(reps):
        s = c = 0
        for _ in range(k):
            j = rng.randrange(k)
            s += sums[j]
            c += counts[j]
        means.append(s / c)
    means.sort()
    up_idx = min(reps - 1, int(math.ceil(confidence * reps)) - 1)
    lo_idx = max(0, int(math.floor((1.0 - confidence) * reps)))
    return {"upper": means[up_idx], "lower": means[lo_idx], "reps": reps, "seed": seed}


def _day_blocks(rows: List[dict]) -> Tuple[List[float], List[int]]:
    by_day: Dict[str, List[float]] = defaultdict(list)
    for r in rows:
        by_day[r["entry_time"][:10]].append(float(r["net_r"]))
    days = sorted(by_day)
    return [sum(by_day[d]) for d in days], [len(by_day[d]) for d in days]


def day_block_bootstrap_means(rows: List[dict], reps: int, seed: int) -> List[float]:
    """Sorted resample means; the draw sequence is identical to day_block_bootstrap_upper."""
    sums, counts = _day_blocks(rows)
    if not sums:
        return []
    rng = random.Random(seed)
    k = len(sums)
    means = []
    for _ in range(reps):
        s = c = 0
        for _ in range(k):
            j = rng.randrange(k)
            s += sums[j]
            c += counts[j]
        means.append(s / c)
    means.sort()
    return means


def upper_from_means(means: Sequence[float], confidence: float = CONFIDENCE):
    """Same index rule as day_block_bootstrap_upper."""
    if not means:
        return None
    reps = len(means)
    return means[min(reps - 1, int(math.ceil(confidence * reps)) - 1)]


def p_value_from_means(means: Sequence[float]):
    """Bootstrap p-value (roadmap 6): share of resample means <= 0."""
    if not means:
        return None
    return sum(1 for m in means if m <= 0.0) / len(means)


def holm_bonferroni(pvalues: Dict[str, float], alpha: float = 0.05) -> Dict[str, bool]:
    """Holm step-down over all hypotheses. None counts as p = 1.0. Ties keep key order.

    Returns {key: significant}. The i-th smallest p-value (0-based) is compared
    with alpha / (m - i); testing stops at the first failure.
    """
    m = len(pvalues)
    order = sorted(pvalues, key=lambda k: (1.0 if pvalues[k] is None else pvalues[k], k))
    out = {k: False for k in pvalues}
    for i, key in enumerate(order):
        p = 1.0 if pvalues[key] is None else pvalues[key]
        if p <= alpha / (m - i):
            out[key] = True
        else:
            break
    return out
