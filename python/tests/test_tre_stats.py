"""Blocking tests for the ported day-block bootstrap (LSR a6ad185 tests, rename only) and the BTB-3 helpers."""

import os
import sys
import unittest

sys.path.insert(0, os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")))

from tre_reference.stats import (day_block_bootstrap_means, day_block_bootstrap_upper, holm_bonferroni,  # noqa: E402
                                 p_value_from_means, upper_from_means)


def row(day, net):
    return {"entry_time": f"2026-01-{day:02d}T10:00:00.000", "net_r": str(net)}


class TestPortedBootstrap(unittest.TestCase):
    """Same assertions as LSR python/tests/test_event_study.py at a6ad185."""

    def test_bootstrap_deterministic_and_ordered(self):
        rows = [row(d, (-1.02 if d % 3 else 2.0)) for d in range(1, 29)]
        a = day_block_bootstrap_upper(rows, 2000, 7)
        b = day_block_bootstrap_upper(rows, 2000, 7)
        self.assertEqual(a, b)
        mean = sum(float(r["net_r"]) for r in rows) / len(rows)
        self.assertLess(a["lower"], mean)
        self.assertGreater(a["upper"], mean)

    def test_constant_sample(self):
        rows = [row(d, -1.0) for d in range(1, 25)]
        self.assertAlmostEqual(day_block_bootstrap_upper(rows, 500, 1)["upper"], -1.0)


class TestBtbHelpers(unittest.TestCase):
    def test_means_use_the_same_draws_as_the_ported_function(self):
        rows = [row(d, (-1.02 if d % 3 else 2.0)) for d in range(1, 29)] + [row(5, 0.7), row(5, -0.3)]
        for reps, seed in ((2000, 7), (10000, 20260929)):
            means = day_block_bootstrap_means(rows, reps, seed)
            self.assertEqual(means, day_block_bootstrap_means(rows, reps, seed))
            self.assertEqual(upper_from_means(means), day_block_bootstrap_upper(rows, reps, seed)["upper"])

    def test_p_value(self):
        self.assertEqual(p_value_from_means(day_block_bootstrap_means([row(d, 1.0) for d in range(1, 21)], 300, 1)), 0.0)
        self.assertEqual(p_value_from_means(day_block_bootstrap_means([row(d, -1.0) for d in range(1, 21)], 300, 1)), 1.0)
        self.assertEqual(p_value_from_means([-0.1, 0.0, 0.2, 0.3]), 0.5)      # mean <= 0 counts
        self.assertIsNone(p_value_from_means([]))
        self.assertIsNone(upper_from_means([]))

    def test_holm(self):
        p = {"a": 0.01, "b": 0.04, "c": 0.03, "d": 0.005}
        self.assertEqual(holm_bonferroni(p, 0.05), {"a": True, "b": False, "c": False, "d": True})
        # step-down stops at the first failure even if a later p would pass its own threshold
        self.assertEqual(holm_bonferroni({"x": 0.02, "y": 0.02}, 0.05), {"x": True, "y": True})
        self.assertEqual(holm_bonferroni({"x": 0.03, "y": 0.03}, 0.05), {"x": False, "y": False})
        self.assertEqual(holm_bonferroni({"x": None, "y": 0.0}, 0.05), {"x": False, "y": True})
        # 48 cells: the smallest p must be <= 0.05/48
        cells = {f"c{i:02d}": 0.5 for i in range(47)}
        cells["best"] = 0.05 / 48
        self.assertTrue(holm_bonferroni(cells)["best"])
        cells["best"] = 0.0011
        self.assertFalse(holm_bonferroni(cells)["best"])


if __name__ == "__main__":
    unittest.main()
