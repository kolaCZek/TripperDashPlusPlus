"""
Speed-limit map-match spatial grid (review B6).

`MapViewSource.recomputeSpeedLimit` runs at GPS cadence on the main actor.
It used to full-scan every segment of every tagged way AND every drivable
road in the route bbox + 300 m (downtown: tens of thousands per fix). It now
asks a `SegmentGrid` (SpeedLimitService.swift) built once in
`setSpeedLimits`, querying only the 3x3 cells around the fix, and falls back
to the old full scan only when the grid can't prove its answer.

This file mirrors `SegmentGrid` 1:1 and proves grid-then-fallback returns
exactly what the full scan returns (limit, distance, and the shadow guard's
nearest-road distance) on a dense randomized street grid — including points
on cell borders and far off the data — plus drift guards for the wiring.
"""

from __future__ import annotations

import math
import random

from tests.swift_source import decl_body, strip_comments
from tests.test_speed_limit_sign import (
    distance_point_to_segment,
    is_shadowed,
    mapsource_src,
    nearest_limit,
    nearest_road_distance,
    service_src,
)

CELL_M = 250.0


class SegmentGrid:
    """Mirror of SpeedLimitService.swift `SegmentGrid`."""

    def __init__(self, lines):
        pts = [c for line in lines if len(line) >= 2 for c in line]
        self.seg_count = sum(len(l) - 1 for l in lines if len(l) >= 2)
        if self.seg_count:
            min_lat = min(p[0] for p in pts)
            max_lat = max(p[0] for p in pts)
            min_lon = min(p[1] for p in pts)
        else:
            min_lat = max_lat = min_lon = 0.0
        ref_lat = max(abs(min_lat), abs(max_lat))
        self.lat_deg = CELL_M / 111_320.0
        self.lon_deg = CELL_M / (111_320.0 * max(0.01, math.cos(math.radians(ref_lat))))
        self.o_lat, self.o_lon = min_lat, min_lon
        self.lines = lines
        self.cells: dict[tuple[int, int], list[tuple[int, int]]] = {}
        for li, line in enumerate(lines):
            if len(line) < 2:
                continue
            for i in range(len(line) - 1):
                a, b = line[i], line[i + 1]
                r0 = self._idx(min(a[0], b[0]), self.o_lat, self.lat_deg)
                r1 = self._idx(max(a[0], b[0]), self.o_lat, self.lat_deg)
                c0 = self._idx(min(a[1], b[1]), self.o_lon, self.lon_deg)
                c1 = self._idx(max(a[1], b[1]), self.o_lon, self.lon_deg)
                for r in range(r0, r1 + 1):
                    for c in range(c0, c1 + 1):
                        self.cells.setdefault((r, c), []).append((li, i))

    @staticmethod
    def _idx(v, origin, cell):
        return math.floor((v - origin) / cell)

    def nearest_within_window(self, p, counter=None):
        """(line, distance) or None → caller must full-scan."""
        if not self.seg_count:
            return None
        r0 = self._idx(p[0], self.o_lat, self.lat_deg)
        c0 = self._idx(p[1], self.o_lon, self.lon_deg)
        best = None  # (d, li, i)
        for r in range(r0 - 1, r0 + 2):
            for c in range(c0 - 1, c0 + 2):
                for li, i in self.cells.get((r, c), ()):
                    line = self.lines[li]
                    d = distance_point_to_segment(p, line[i], line[i + 1])
                    if counter is not None:
                        counter[0] += 1
                    if best is None or d < best[0] or (d == best[0] and (li, i) < best[1:]):
                        best = (d, li, i)
        if best is None:
            return None
        m_lat = 111_320.0
        m_lon = 111_320.0 * math.cos(math.radians(p[0]))
        south = self.o_lat + (r0 - 1) * self.lat_deg
        north = self.o_lat + (r0 + 2) * self.lat_deg
        west = self.o_lon + (c0 - 1) * self.lon_deg
        east = self.o_lon + (c0 + 2) * self.lon_deg
        radius = min((p[0] - south) * m_lat, (north - p[0]) * m_lat,
                     (p[1] - west) * m_lon, (east - p[1]) * m_lon)
        return (best[1], best[0]) if best[0] < radius - 0.5 else None


def grid_limit(grid, ways, p):
    """Mirror of recomputeSpeedLimit's way lookup: grid, else full scan."""
    hit = grid.nearest_within_window(p)
    if hit is not None:
        return (ways[hit[0]][0], hit[1])
    return nearest_limit(p, ways)


def grid_road(grid, roads, p):
    hit = grid.nearest_within_window(p)
    return hit[1] if hit is not None else nearest_road_distance(p, roads)


def _city(seed=7, n_ways=2000):
    """Dense ~6x6 km downtown at 50°N: a jittered street lattice (blocks
    ~80-150 m) with multi-vertex ways, plus diagonals. ~35% tagged."""
    rng = random.Random(seed)
    lat0, lon0 = 50.08, 14.42
    dlat = 6000 / 111_320.0
    dlon = 6000 / (111_320.0 * math.cos(math.radians(lat0)))
    roads, ways = [], []
    for k in range(n_ways):
        kind = k % 3
        n = rng.randint(2, 8)
        if kind == 0:   # east-west street
            la = lat0 + rng.random() * dlat
            lo = lon0 + rng.random() * dlon * 0.7
            pts = [(la + rng.uniform(-2e-5, 2e-5), lo + j * rng.uniform(0.0008, 0.002))
                   for j in range(n)]
        elif kind == 1:  # north-south street
            la = lat0 + rng.random() * dlat * 0.7
            lo = lon0 + rng.random() * dlon
            pts = [(la + j * rng.uniform(0.0006, 0.0014), lo + rng.uniform(-3e-5, 3e-5))
                   for j in range(n)]
        else:            # wiggly diagonal
            la = lat0 + rng.random() * dlat
            lo = lon0 + rng.random() * dlon
            pts = [(la, lo)]
            for _ in range(n - 1):
                la += rng.uniform(-0.002, 0.002)
                lo += rng.uniform(-0.003, 0.003)
                pts.append((la, lo))
        roads.append(pts)
        if rng.random() < 0.35:
            ways.append((rng.choice([30, 50, 70]), pts))
    return (lat0, lon0, dlat, dlon), ways, roads


def _points(bounds, grid, rng, n):
    lat0, lon0, dlat, dlon = bounds
    pts = []
    for _ in range(n):
        pts.append((lat0 + rng.random() * dlat, lon0 + rng.random() * dlon))
    # Exactly on / hair-off cell borders.
    for _ in range(n // 4):
        r = rng.randint(0, int(dlat / grid.lat_deg))
        c = rng.randint(0, int(dlon / grid.lon_deg))
        eps = rng.choice([0.0, 1e-9, -1e-9])
        pts.append((grid.o_lat + r * grid.lat_deg + eps, grid.o_lon + c * grid.lon_deg - eps))
    # Far off the data (forces the full-scan fallback) and just outside it.
    for _ in range(40):
        pts.append((lat0 - rng.uniform(0.001, 0.2), lon0 - rng.uniform(0.001, 0.2)))
        pts.append((lat0 + dlat + rng.uniform(0.0, 0.01), lon0 + rng.uniform(0, dlon)))
    return pts


def test_grid_query_equals_full_scan_on_dense_city():
    bounds, ways, roads = _city()
    way_grid = SegmentGrid([c for _, c in ways])
    road_grid = SegmentGrid(roads)
    rng = random.Random(11)
    for p in _points(bounds, road_grid, rng, 600):
        full = nearest_limit(p, ways)
        fast = grid_limit(way_grid, ways, p)
        assert fast == full, p
        full_road = nearest_road_distance(p, roads)
        fast_road = grid_road(road_grid, roads, p)
        assert fast_road == full_road, p
        assert is_shadowed(fast[1], fast_road) == is_shadowed(full[1], full_road)


def test_grid_breaks_ties_like_full_scan():
    """Two tagged ways sharing the same geometry but different limits: the
    full scan keeps the FIRST (strictly-smaller rule); so must the grid."""
    seg = [(50.0, 14.0), (50.0, 14.01)]
    ways = [(50, seg), (90, list(seg))]
    grid = SegmentGrid([c for _, c in ways])
    p = (50.0003, 14.005)
    assert grid_limit(grid, ways, p) == nearest_limit(p, ways)
    assert grid_limit(grid, ways, p)[0] == 50


def test_grid_scans_far_fewer_segments_downtown():
    """Per-fix cost: the 3x3 window is a small, bbox-independent slice."""
    bounds, ways, roads = _city()
    road_grid = SegmentGrid(roads)
    rng = random.Random(3)
    lat0, lon0, dlat, dlon = bounds
    total, n = [0], 200
    for _ in range(n):
        road_grid.nearest_within_window(
            (lat0 + rng.random() * dlat, lon0 + rng.random() * dlon), total)
    per_fix = total[0] / n
    assert per_fix < road_grid.seg_count / 10, (per_fix, road_grid.seg_count)


# --- Swift drift guards ---------------------------------------------------

def test_swift_segment_grid_exists_and_is_nonisolated():
    src = strip_comments(service_src())
    assert "nonisolated struct SegmentGrid: Sendable" in src
    body = decl_body(src, "nonisolated struct SegmentGrid")
    assert "static let cellMeters: Double = 250" in body
    assert "func nearestWithinWindow(to p: CLLocationCoordinate2D) -> Hit?" in body
    assert "SpeedLimitService.distancePointToSegment(" in body
    # Full-scan fallbacks are still there.
    assert "nonisolated static func nearestLimit(" in src
    assert "nonisolated static func nearestRoadDistance(" in src


def test_swift_grid_built_on_install_not_per_fix():
    src = strip_comments(mapsource_src())
    install = decl_body(src, "func setSpeedLimits(")
    assert "SegmentGrid(lines: data.limits.map(\\.coords))" in install
    assert "SegmentGrid(lines: data.roads.map(\\.coords))" in install
    assert "Speed-limit grid:" in install
    fix = decl_body(src, "private func recomputeSpeedLimit(")
    assert "SegmentGrid(" not in fix
    assert "speedLimitWayGrid?.nearestWithinWindow(to: fix.coordinate)" in fix
    assert "speedLimitRoadGrid?.nearestWithinWindow(to: fix.coordinate)" in fix
    # Exact-semantics fallback for both lookups, and the shadow guard kept.
    assert "SpeedLimitService.nearestLimit(to: fix.coordinate" in fix
    assert "SpeedLimitService.nearestRoadDistance(to: fix.coordinate" in fix
    assert "Self.isShadowed(matchDistance: match.distanceMeters, nearestRoad: nearestRoad)" in fix
