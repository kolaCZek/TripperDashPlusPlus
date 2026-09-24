"""
Tests for the alternative-route near-duplicate filter mirror.

Pins the phantom-ETA-bubble fix: a near-identical alt (the roundabout
retime) must be REJECTED, while a genuine fork onto a different road must
be KEPT.
"""

import unittest

from tests.alt_route_divergence_mirror import (
    ALT_MIN_DIVERGENCE_M,
    bubble_anchor_index,
    haversine,
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

    # --- field report 9/2026: bubble with no visible grey line -----------

    @staticmethod
    def _line(a, b, n):
        return [(a[0] + (b[0] - a[0]) * i / (n - 1), a[1] + (b[1] - a[1]) * i / (n - 1))
                for i in range(n)]

    def test_retime_of_sparse_motorway_is_rejected(self):
        # Active polyline has one vertex every ~2 km (straight motorway);
        # the "alternative" is the SAME road with dense vertices. A
        # vertex-to-vertex scan measured ~1 km apart and kept it → grey line
        # hidden under blue + a floating "similar" bubble.
        active = [(50.0, 14.0 + 0.028 * i) for i in range(11)]
        alt = [(50.0, 14.0 + 0.0014 * i) for i in range(201)]
        self.assertLess(max_divergence(alt, active), 1.0)
        self.assertFalse(is_distinct_fork(alt, active))

    def test_bubble_sits_on_the_visible_detour_not_the_shared_stretch(self):
        # Alt shares the first 12 km and the last few km with the active
        # route and detours ~800 m north in between. Its vertex midpoint lies
        # on the SHARED stretch (grey under blue, invisible); the bubble
        # must go where the lines are actually apart.
        a0, a1 = (50.0, 14.0), (50.0, 14.28)
        active = self._line(a0, a1, 400)
        alt = (self._line(a0, (50.0, 14.168), 240)
               + self._line((50.0072, 14.175), (50.0072, 14.225), 80)
               + self._line((50.0, 14.232), a1, 97))
        mid = alt[len(alt) // 2]
        self.assertLess(min(haversine(mid, q) for q in active), 25,
                        "precondition: the old midpoint anchor was on the blue line")
        anchor = alt[bubble_anchor_index(alt, active)]
        self.assertGreater(max_divergence([anchor, anchor], active), 700)
        self.assertTrue(14.175 <= anchor[1] <= 14.225)

    def test_no_reference_anchors_at_midpoint(self):
        alt = [(50.0, 14.0), (50.0, 14.01), (50.0, 14.02)]
        self.assertEqual(bubble_anchor_index(alt, []), 1)


class TestSwiftDriftGuard(unittest.TestCase):
    """The Swift must keep the two behaviours the mirror above pins."""

    @staticmethod
    def _body():
        import pathlib
        from tests.swift_source import decl_body, strip_comments
        root = pathlib.Path(__file__).resolve().parents[3]
        src = strip_comments((root / "TripperDashPP" / "UI" / "MapPickerView.swift").read_text("utf-8"))
        return src, decl_body(src, "private func pushAlternativeRenders")

    def test_divergence_is_measured_to_segments(self):
        src, _ = self._body()
        from tests.swift_source import decl_body
        md = decl_body(src, "static func maxDivergence(of coords: [CLLocationCoordinate2D],")
        self.assertIn("distance(from: p, toSegment: reference[j], reference[j + 1])", md)
        self.assertNotIn("p.distance(from: CLLocation(", md)

    def test_bubble_anchored_at_max_divergence_vertex(self):
        _, body = self._body()
        self.assertIn("let anchor = coords[divergence.index]", body)
        self.assertNotIn("let anchor = coords[coords.count / 2]", body)


if __name__ == "__main__":
    unittest.main()
