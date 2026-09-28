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


def unwrap_longitude(lon, ref):
    """Mirror of SpeedLimitService.unwrapLongitude."""
    if lon - ref > 180:
        return lon - 360
    if lon - ref < -180:
        return lon + 360
    return lon


class SegmentGrid:
    """Mirror of SpeedLimitService.swift `SegmentGrid`."""

    def __init__(self, lines):
        pts = [c for line in lines if len(line) >= 2 for c in line]
        self.seg_count = sum(len(l) - 1 for l in lines if len(l) >= 2)
        self.ref_lon = pts[0][1] if pts else 0.0
        if self.seg_count:
            min_lat = min(p[0] for p in pts)
            max_lat = max(p[0] for p in pts)
            min_lon = min(self._unwrap(p[1]) for p in pts)
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
                a_lon, b_lon = self._unwrap(a[1]), self._unwrap(b[1])
                c0 = self._idx(min(a_lon, b_lon), self.o_lon, self.lon_deg)
                c1 = self._idx(max(a_lon, b_lon), self.o_lon, self.lon_deg)
                for r in range(r0, r1 + 1):
                    for c in range(c0, c1 + 1):
                        self.cells.setdefault((r, c), []).append((li, i))

    def _unwrap(self, lon):
        return unwrap_longitude(lon, self.ref_lon)

    @staticmethod
    def _idx(v, origin, cell):
        return math.floor((v - origin) / cell)

    def nearest_within_window(self, p, counter=None):
        """(line, distance) or None → caller must full-scan."""
        if not self.seg_count:
            return None
        lon = self._unwrap(p[1])
        r0 = self._idx(p[0], self.o_lat, self.lat_deg)
        c0 = self._idx(lon, self.o_lon, self.lon_deg)
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
                     (lon - west) * m_lon, (east - lon) * m_lon)
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


# --- Antimeridian (review N1) ---------------------------------------------

def _taveuni():
    """Streets straddling 180° like Taveuni, Fiji (the road through Waiyevo
    crosses it): the same dense lattice shifted so it spans ±180°, with every
    longitude written the OSM way, in [-180, 180]."""
    bounds, ways, roads = _city(seed=5, n_ways=600)
    lat0, lon0, dlat, dlon = bounds
    shift_lat, shift_lon = -16.8 - lat0, 179.97 - lon0

    def w(c):
        return (c[0] + shift_lat, math.remainder(c[1] + shift_lon, 360))

    roads = [[w(c) for c in r] for r in roads]
    ways = [(k, [w(c) for c in cs]) for k, cs in ways]
    return (lat0 + shift_lat, 179.97, dlat, dlon), ways, roads


def test_distance_across_antimeridian_is_metres_not_planet():
    a, b = (-16.8, 179.9995), (-16.8, -179.9995)
    d = distance_point_to_segment((-16.8003, 180.0), a, b)
    assert abs(d - 0.0003 * 111_320) < 0.5
    d = distance_point_to_segment((-16.8, 179.999), a, b)
    assert d < 60


def test_grid_stays_small_and_exact_across_antimeridian():
    (lat0, lon0, dlat, dlon), ways, roads = _taveuni()
    assert any(min(c[1] for c in r) < 0 < max(c[1] for c in r) for r in roads)
    way_grid = SegmentGrid([c for _, c in ways])
    road_grid = SegmentGrid(roads)
    # ~6x6 km of data is a few hundred 250 m cells, not a band ~360° wide.
    assert len(road_grid.cells) < 2000, len(road_grid.cells)
    rng = random.Random(13)
    for _ in range(400):
        p = (lat0 + rng.random() * dlat, math.remainder(lon0 + rng.random() * dlon, 360))
        full = nearest_limit(p, ways)
        assert grid_limit(way_grid, ways, p) == full, p
        road = nearest_road_distance(p, roads)
        assert grid_road(road_grid, roads, p) == road, p
        # Inside a dense street lattice: metres, not the way round the globe.
        assert road < 1000 and full[1] < 5000, p


def bounding_box(coords, buffer_m):
    """Mirror of SpeedLimitService.boundingBox (south, west, north, east)."""
    ref = coords[0][1]
    lons = [unwrap_longitude(c[1], ref) for c in coords]
    lats = [c[0] for c in coords]
    lat_buf = buffer_m / 111_320.0
    mid = (min(lats) + max(lats)) / 2
    lon_buf = buffer_m / (111_320.0 * max(0.01, math.cos(math.radians(mid))))
    return (min(lats) - lat_buf, math.remainder(min(lons) - lon_buf, 360),
            max(lats) + lat_buf, math.remainder(max(lons) + lon_buf, 360))


def test_overpass_box_wraps_instead_of_spanning_the_planet():
    # Overpass reads west > east as the box through ±180° (checked live
    # against overpass-api.de on a box over Taveuni).
    s, w, n, e = bounding_box([(-16.80, 179.99), (-16.81, -179.99)], 300)
    assert w > e and 179.9 < w < 180 and -180 < e < -179.9
    # Everywhere else it is the plain min/max box, bit for bit (cache keys
    # of already-downloaded regions stay the same).
    coords = [(50.08, 14.42), (50.10, 14.47), (50.05, 14.40)]
    lat_buf = 300 / 111_320.0
    lon_buf = 300 / (111_320.0 * math.cos(math.radians((50.05 + 50.10) / 2)))
    assert bounding_box(coords, 300) == (50.05 - lat_buf, 14.40 - lon_buf,
                                        50.10 + lat_buf, 14.47 + lon_buf)


def test_swift_wraps_longitudes_like_the_mirror():
    src = strip_comments(service_src())
    dist = decl_body(src, "nonisolated static func distancePointToSegment(")
    assert "let ax = remainder(a.longitude - p.longitude, 360) * mPerDegLon" in dist
    assert "let bx = remainder(b.longitude - p.longitude, 360) * mPerDegLon" in dist
    grid = decl_body(src, "nonisolated struct SegmentGrid")
    unwrap = decl_body(src, "nonisolated static func unwrapLongitude(")
    assert "if lon - ref > 180 { return lon - 360 }" in unwrap
    assert "if lon - ref < -180 { return lon + 360 }" in unwrap
    assert "minLon = min(minLon, SpeedLimitService.unwrapLongitude(c.longitude, near: ref))" in grid
    assert "let aLon = SpeedLimitService.unwrapLongitude(a.longitude, near: ref)" in grid
    assert "let bLon = SpeedLimitService.unwrapLongitude(b.longitude, near: ref)" in grid
    assert "let lon = SpeedLimitService.unwrapLongitude(p.longitude, near: refLon)" in grid
    assert "(lon - west) * mPerDegLon" in grid and "(east - lon) * mPerDegLon" in grid
    box = decl_body(src, "nonisolated static func boundingBox(of")
    assert "let lon = unwrapLongitude(c.longitude, near: ref)" in box
    assert "west: remainder(minLon - lonBuf, 360)" in box
    assert "east: remainder(maxLon + lonBuf, 360)" in box
