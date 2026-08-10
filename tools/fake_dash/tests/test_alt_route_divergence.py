"""
Tests for the alternative-route near-duplicate filter mirror.

Pins the phantom-ETA-bubble fix: a near-identical alt (the roundabout
retime) must be REJECTED, while a genuine fork onto a different road must
be KEPT.
"""

import unittest

from alt_route_divergence_mirror import (
    ALT_MIN_DIVERGENCE_M,
    is_distinct_fork,
    max_divergence,
)


class TestAltRouteDivergence(unittest.TestCase):

    def test_single_point_alt_rejected(self):
        # Degenerate polyline (< 2 pts) → never drawn (existing guard).
        self.assertFalse(is_distinct_fork([(50.0, 14.0)], [(50.0, 14.0), (50.01, 14.0)]))

    def test_near_duplicate_alt_rejected(self):
        # Alt tracing the SAME road (offset only by GPS-scale jitter ~5 m)
        # → phantom bubble case → must be rejected.
        ref = [(50.3559, 14.4549), (50.3570, 14.4560), (50.3580, 14.4570)]
        # ~0.00005 deg lat ≈ 5.5 m sideways — under the 25 m threshold.
        alt = [(50.35595, 14.4549), (50.35705, 14.4560), (50.35805, 14.4570)]
        self.assertLess(max_divergence(alt, ref), ALT_MIN_DIVERGENCE_M)
        self.assertFalse(is_distinct_fork(alt, ref))

    def test_genuine_fork_kept(self):
        # Alt peels off onto a clearly different road (~150 m away).
        ref = [(50.3559, 14.4549), (50.3570, 14.4560), (50.3580, 14.4570)]
        alt = [(50.3559, 14.4549), (50.3575, 14.4610), (50.3590, 14.4660)]
        self.assertGreaterEqual(max_divergence(alt, ref), ALT_MIN_DIVERGENCE_M)
        self.assertTrue(is_distinct_fork(alt, ref))

    def test_exact_overlap_rejected(self):
        # Identical geometry → zero divergence → rejected.
        ref = [(50.10, 14.40), (50.11, 14.41), (50.12, 14.42)]
        self.assertEqual(max_divergence(ref, ref), 0.0)
        self.assertFalse(is_distinct_fork(ref, ref))

    def test_no_reference_keeps_drawable_alt(self):
        # No active line to compare against → keep (matches Swift guard).
        alt = [(50.10, 14.40), (50.11, 14.41)]
        self.assertTrue(is_distinct_fork(alt, []))

    def test_threshold_boundary(self):
        # A vertex just PAST the threshold distance is KEPT (>=).
        ref = [(50.0, 14.0), (50.0, 14.001)]
        # ~30 m north of the ref line — comfortably past the 25 m cutoff
        # without depending on sub-metre float precision.
        north = 30.0 / 111_320.0
        alt = [(50.0 + north, 14.0), (50.0 + north, 14.001)]
        div = max_divergence(alt, ref)
        self.assertGreater(div, ALT_MIN_DIVERGENCE_M)
        self.assertTrue(is_distinct_fork(alt, ref))


if __name__ == "__main__":
    unittest.main()
