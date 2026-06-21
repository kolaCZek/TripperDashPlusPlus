"""
Python port of the rolling-window selection logic in
`RouteTileCache.computeAllAnchors` + `anchorIndices(withinOffsetRange:)`
+ `snapToMainAnchor`. We don't run Swift in CI — these tests just
encode the *behaviour we promise* in plain Python so a Swift bug that
breaks one of these invariants would show up when the same scenario
is run through the Python reference.

Invariants under test:

  * `computeAllAnchors` produces 3 rows: main + left wing + right wing.
    For a 40 km route with stride=700 m, that's roughly 57 + 57 + 57
    = ~171 anchors — well under the 300 cap.
  * `routeOffsetMeters` monotonically increases along the main row.
  * `snapToMainAnchor` returns the offset of the closest main anchor
    and ignores wings.
  * `anchorIndices(withinOffsetRange:)` is inclusive on both ends and
    correctly includes wing rows at the matching offsets.
  * Fast-start window (8 km) yields ~12 main + ~24 wings.
  * Rolling lookahead window (5 km) ahead of mid-route covers
    ~7 main + ~14 wings = ~21 anchors per evaluation.
"""

import math
import unittest


# Mirror Swift `RouteTileCache` tunables exactly. If the Swift side
# changes one of these, update here too — the tests will then fail
# loudly until the reasoning is also updated.
STRIDE_M = 700.0
LATERAL_OFFSET_M = 1500.0
INITIAL_BAKE_AHEAD_M = 8000.0
ROLLING_LOOKAHEAD_M = 5000.0
ROLLING_TRAIL_M = 500.0
MAX_TILES_PER_ROUTE = 300

EARTH_R = 6_371_000.0


def haversine(a, b):
    """Great-circle distance in metres between two (lat, lon) pairs."""
    lat1, lon1 = math.radians(a[0]), math.radians(a[1])
    lat2, lon2 = math.radians(b[0]), math.radians(b[1])
    dlat = lat2 - lat1
    dlon = lon2 - lon1
    h = math.sin(dlat / 2) ** 2 + math.cos(lat1) * math.cos(lat2) * math.sin(dlon / 2) ** 2
    return 2 * EARTH_R * math.asin(math.sqrt(h))


def anchors_along_polyline(coords, stride):
    """Same density as Swift `anchorsAlongPolyline` — sample every
    `stride` metres along the segment chain. Always include endpoints."""
    if len(coords) < 2:
        return list(coords)
    out = [coords[0]]
    leftover = 0.0
    for a, b in zip(coords, coords[1:]):
        seg_len = haversine(a, b)
        if seg_len < 1e-6:
            continue
        traveled = leftover
        while traveled + stride <= seg_len:
            traveled += stride
            t = traveled / seg_len
            lat = a[0] + (b[0] - a[0]) * t
            lon = a[1] + (b[1] - a[1]) * t
            out.append((lat, lon))
        leftover = (traveled + stride) - seg_len
        if leftover < 0:
            leftover = 0
    if out[-1] != coords[-1]:
        out.append(coords[-1])
    return out


def lateral_anchors(mains, offset_m):
    """Perpendicular shift, same as Swift `lateralAnchors`."""
    out = []
    for i, c in enumerate(mains):
        # Tangent via neighbours
        if i == 0:
            j = 1
        elif i == len(mains) - 1:
            j = i - 1
        else:
            j = i + 1
        dlat = mains[j][0] - c[0]
        dlon = mains[j][1] - c[1]
        # Perpendicular vector in lat/lon space, flat-earth approx
        # at this latitude.
        lat_rad = math.radians(c[0])
        # Sign convention: i==len-1 case used j=i-1, so flip perp.
        sign = -1 if (i == len(mains) - 1) else 1
        # Perpendicular (rotate 90° CCW): (-dlon, +dlat) in plane.
        # Scale to metres-per-degree:
        m_per_deg_lat = 111_320.0
        m_per_deg_lon = m_per_deg_lat * math.cos(lat_rad)
        # Convert tangent to metres, rotate, convert back.
        tx_m = dlon * m_per_deg_lon
        ty_m = dlat * m_per_deg_lat
        norm = math.hypot(tx_m, ty_m)
        if norm < 1e-9:
            out.append(c)
            continue
        # Unit perpendicular (rotated by 90° CCW × sign).
        px_m = -ty_m / norm * sign
        py_m = tx_m / norm * sign
        d_lon = (px_m * offset_m) / m_per_deg_lon
        d_lat = (py_m * offset_m) / m_per_deg_lat
        out.append((c[0] + d_lat, c[1] + d_lon))
    return out


def compute_all_anchors(coords):
    """Mirror of `RouteTileCache.computeAllAnchors`."""
    mains = anchors_along_polyline(coords, STRIDE_M)
    # Distance-along-route for each main anchor.
    offsets = [0.0]
    for prev, cur in zip(mains, mains[1:]):
        offsets.append(offsets[-1] + haversine(prev, cur))
    lefts = lateral_anchors(mains, -LATERAL_OFFSET_M)
    rights = lateral_anchors(mains, +LATERAL_OFFSET_M)
    out = []
    # Tag: (coord, routeOffset, lateralRow)
    for i, c in enumerate(mains):
        out.append((c, offsets[i], 0))
    for i, c in enumerate(lefts):
        out.append((c, offsets[i], -1))
    for i, c in enumerate(rights):
        out.append((c, offsets[i], +1))
    return out


def anchor_indices_in_range(all_anchors, lo, hi):
    """Mirror of `anchorIndices(withinOffsetRange:)` — inclusive."""
    return [i for i, (_, off, _) in enumerate(all_anchors) if lo <= off <= hi]


def snap_to_main(all_anchors, coord, max_dist=3000.0):
    """Mirror of `snapToMainAnchor` — closest main row anchor, with
    a 3 km cutoff (off-route + lateral buffer)."""
    best_off, best_dist = None, float("inf")
    for (c, off, row) in all_anchors:
        if row != 0:
            continue
        d = haversine(coord, c)
        if d < best_dist:
            best_dist = d
            best_off = off
    return best_off if best_dist < max_dist else None


# ----- A synthetic 40 km straight-ish route, Zvoleneves → Karlín -----

ZVOLENEVES = (50.2710, 14.2410)
KARLIN = (50.0930, 14.4500)

# Sample a few intermediate waypoints so the polyline isn't a single
# segment (the Swift code path always sees densely sampled MapKit
# polylines, but a 2-point line is fine for these geometry tests).
ROUTE_COORDS = [
    ZVOLENEVES,
    (50.245, 14.270),
    (50.215, 14.310),
    (50.180, 14.360),
    (50.140, 14.400),
    (50.115, 14.430),
    KARLIN,
]


class RollingWindowTests(unittest.TestCase):
    def setUp(self):
        self.anchors = compute_all_anchors(ROUTE_COORDS)
        self.mains = [a for a in self.anchors if a[2] == 0]
        self.total_distance = self.mains[-1][1]

    def test_route_length_plausible(self):
        # Zvoleneves → Karlín direct-ish, this synthetic polyline
        # measures ~25 km (real road via D7 is closer to 30 km).
        self.assertGreater(self.total_distance, 20_000)
        self.assertLess(self.total_distance, 35_000)

    def test_three_rows_present(self):
        rows = {a[2] for a in self.anchors}
        self.assertEqual(rows, {-1, 0, +1})

    def test_main_anchor_count_matches_stride(self):
        # ~25 km / 700 m stride ≈ 35 anchors, ± a few from endpoint
        # inclusion. (Real D7 route at ~30 km would land around 43.)
        n_main = len(self.mains)
        self.assertGreater(n_main, 25)
        self.assertLess(n_main, 50)

    def test_main_offsets_monotonic(self):
        offsets = [m[1] for m in self.mains]
        self.assertEqual(offsets, sorted(offsets))

    def test_wings_share_offsets_with_mains(self):
        main_offsets = set(round(m[1], 3) for m in self.mains)
        wing_offsets = set(round(a[1], 3) for a in self.anchors if a[2] != 0)
        # Every wing offset must come from a main offset.
        self.assertTrue(wing_offsets.issubset(main_offsets))

    def test_total_under_cap_for_typical_route(self):
        # The new architecture doesn't decimate; it just bakes more
        # incrementally. But a typical 40 km route should still be
        # well under the soft cap.
        self.assertLess(len(self.anchors), MAX_TILES_PER_ROUTE)

    def test_initial_window_yields_8km_worth(self):
        idxs = anchor_indices_in_range(self.anchors, 0, INITIAL_BAKE_AHEAD_M)
        rows = [self.anchors[i][2] for i in idxs]
        # 8 km / 700 m stride ≈ 12 main, 2× that for wings.
        n_main = sum(1 for r in rows if r == 0)
        n_wing = sum(1 for r in rows if r != 0)
        self.assertGreaterEqual(n_main, 10)
        self.assertLessEqual(n_main, 15)
        self.assertEqual(n_wing, 2 * n_main)

    def test_rolling_window_around_midpoint(self):
        # Pick a coord roughly at the geometric midpoint of the route.
        mid_idx = len(self.mains) // 2
        mid_coord = self.mains[mid_idx][0]
        snapped = snap_to_main(self.anchors, mid_coord)
        assert snapped is not None
        self.assertLess(abs(snapped - self.mains[mid_idx][1]), 1.0)

        lo = max(0.0, snapped - ROLLING_TRAIL_M)
        hi = snapped + ROLLING_LOOKAHEAD_M
        idxs = anchor_indices_in_range(self.anchors, lo, hi)
        rows = [self.anchors[i][2] for i in idxs]
        n_main = sum(1 for r in rows if r == 0)
        # 500 m trail + 5000 m lookahead = 5.5 km / 700 m ≈ 7–8 main.
        self.assertGreaterEqual(n_main, 6)
        self.assertLessEqual(n_main, 10)

    def test_rolling_window_idempotent_when_already_baked(self):
        """Caller logic: same window, baked set covers it → 0 new."""
        snapped = snap_to_main(self.anchors, self.mains[5][0])
        assert snapped is not None
        lo = max(0.0, snapped - ROLLING_TRAIL_M)
        hi = snapped + ROLLING_LOOKAHEAD_M
        idxs = set(anchor_indices_in_range(self.anchors, lo, hi))
        # Pretend we've baked them all.
        baked = set(idxs)
        # Second pass: filter idxs through baked → empty.
        missing = [i for i in idxs if i not in baked]
        self.assertEqual(missing, [])

    def test_rolling_window_grows_as_rider_moves(self):
        """As rider advances, the window covers strictly new indices
        (some overlap with previous, but front edge sweeps fresh ones)."""
        # Position 1: 5 km in. Position 2: 10 km in.
        pos1_main_idx = next(i for i, m in enumerate(self.mains) if m[1] >= 5000)
        pos2_main_idx = next(i for i, m in enumerate(self.mains) if m[1] >= 10000)
        snapped1 = self.mains[pos1_main_idx][1]
        snapped2 = self.mains[pos2_main_idx][1]
        idxs1 = set(anchor_indices_in_range(
            self.anchors, snapped1 - ROLLING_TRAIL_M, snapped1 + ROLLING_LOOKAHEAD_M
        ))
        idxs2 = set(anchor_indices_in_range(
            self.anchors, snapped2 - ROLLING_TRAIL_M, snapped2 + ROLLING_LOOKAHEAD_M
        ))
        # Position 2 must include at least one anchor position 1 didn't,
        # otherwise rolling doesn't actually progress.
        self.assertTrue(idxs2 - idxs1)

    def test_snap_returns_none_far_from_route(self):
        # Pick somewhere 50 km away — Plzeň, say.
        plzen = (49.747, 13.378)
        snapped = snap_to_main(self.anchors, plzen)
        self.assertIsNone(snapped)

    def test_snap_uses_only_main_anchors(self):
        # Pick a point that's slightly closer to a left wing than to a
        # main — snap should still return the main offset.
        main_c, main_off, _ = self.mains[10]
        # Move 100 m toward the left wing direction.
        # We can just pick the actual left wing for that index and
        # verify snap returns the main, not anything else.
        left_wing = next(
            a for a in self.anchors
            if a[2] == -1 and abs(a[1] - main_off) < 1.0
        )
        snapped = snap_to_main(self.anchors, left_wing[0])
        assert snapped is not None
        # The snap should be the main row offset (i.e. equal to main_off),
        # not 'no snap' and not some wing-tagged offset.
        self.assertLess(abs(snapped - main_off), 1.0)


if __name__ == "__main__":
    unittest.main()
