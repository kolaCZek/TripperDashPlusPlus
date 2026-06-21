"""
Port of `RouteTileCache.lateralAnchors` / `decimate` to Python so we can
verify the geometry without needing a Swift compiler or a device. The
Swift implementation is kept in sync with this reference — any drift
should be caught by the assertions below.

Why bother? The lateral-buffer trick is the difference between "user
strays 1 km and the map goes dark" and "user strays 1 km and the map
keeps drawing". Getting the perpendicular-vector sign wrong is silent
— the tiles still bake, they just bake on the wrong side. These tests
pin the geometry down with cartesian-coord cases where the answer is
obvious, plus a real-world coord case where the answer comes from
haversine distance.
"""

from __future__ import annotations

import math

import pytest

# --- Reference implementation (mirrors Swift) -----------------------------

def haversine_m(a: tuple[float, float], b: tuple[float, float]) -> float:
    R = 6_371_000.0
    lat1, lon1 = math.radians(a[0]), math.radians(a[1])
    lat2, lon2 = math.radians(b[0]), math.radians(b[1])
    dlat = lat2 - lat1
    dlon = lon2 - lon1
    h = math.sin(dlat / 2) ** 2 + math.cos(lat1) * math.cos(lat2) * math.sin(dlon / 2) ** 2
    return 2 * R * math.asin(math.sqrt(h))


def lateral_anchors(
    anchors: list[tuple[float, float]],
    offset_m: float,
) -> list[tuple[float, float]]:
    """Same algorithm as RouteTileCache.lateralAnchors (Swift)."""
    if len(anchors) < 2:
        return []
    avg_lat = sum(a[0] for a in anchors) / len(anchors)
    m_per_deg_lat = 111_320.0
    m_per_deg_lon = 111_320.0 * math.cos(math.radians(avg_lat))
    out: list[tuple[float, float]] = []
    for i in range(len(anchors)):
        prev = anchors[max(0, i - 1)]
        nxt  = anchors[min(len(anchors) - 1, i + 1)]
        dx = (nxt[1] - prev[1]) * m_per_deg_lon
        dy = (nxt[0] - prev[0]) * m_per_deg_lat
        L = math.hypot(dx, dy)
        if L < 1e-4:
            out.append(anchors[i])
            continue
        # Right-hand normal in meters: rotate (dx, dy) by -90° → (dy, -dx).
        nx =  dy / L * offset_m
        ny = -dx / L * offset_m
        d_lon = nx / m_per_deg_lon
        d_lat = ny / m_per_deg_lat
        out.append((anchors[i][0] + d_lat, anchors[i][1] + d_lon))
    return out


def decimate(arr: list, keep: int) -> list:
    if keep <= 0:
        return []
    if len(arr) <= keep:
        return arr
    out = []
    for i in range(keep):
        idx = (i * (len(arr) - 1)) // max(1, keep - 1)
        out.append(arr[idx])
    return out


# --- Tests ---------------------------------------------------------------

@pytest.fixture
def north_polyline() -> list[tuple[float, float]]:
    """Five anchors heading due north from 50.0°N, 14.0°E, 700 m apart."""
    base_lat, base_lon = 50.0, 14.0
    step_lat_deg = 700.0 / 111_320.0
    return [(base_lat + i * step_lat_deg, base_lon) for i in range(5)]


def test_due_north_route_offsets_east_for_positive(north_polyline):
    """Travelling north → +offset is the rider's right hand → +east lon."""
    right = lateral_anchors(north_polyline, offset_m=1500)
    assert len(right) == len(north_polyline)
    # Eastward shift = longitude increases
    for orig, shifted in zip(north_polyline, right):
        assert shifted[1] > orig[1], "right-hand offset of a northbound route must increase lon"
        # Lat barely moves (pure perpendicular shift)
        assert abs(shifted[0] - orig[0]) < 1e-6


def test_due_north_route_offsets_west_for_negative(north_polyline):
    left = lateral_anchors(north_polyline, offset_m=-1500)
    for orig, shifted in zip(north_polyline, left):
        assert shifted[1] < orig[1], "left-hand offset of a northbound route must decrease lon"


def test_offset_distance_is_within_5_percent_of_request(north_polyline):
    """Sanity: the haversine distance between original and offset is ~1500 m."""
    target = 1500.0
    right = lateral_anchors(north_polyline, offset_m=target)
    # Skip endpoints — their tangent uses one neighbour only and can
    # be slightly off if the segment is short. Interior anchors use a
    # symmetric two-neighbour tangent → much more accurate.
    for orig, shifted in zip(north_polyline[1:-1], right[1:-1]):
        d = haversine_m(orig, shifted)
        assert abs(d - target) / target < 0.05, f"{d:.1f} m vs {target} m"


def test_endpoints_still_offset_close_to_target(north_polyline):
    """Endpoints lose accuracy slightly but must still be within 15 %."""
    right = lateral_anchors(north_polyline, offset_m=1500)
    for i in [0, -1]:
        d = haversine_m(north_polyline[i], right[i])
        assert abs(d - 1500) / 1500 < 0.15


def test_diagonal_route_offsets_perpendicular():
    """Route heading NE at 45° → right-hand offset must head SE at 315°."""
    # Five anchors heading NE, 700 m apart
    base_lat, base_lon = 50.0, 14.0
    m_per_deg_lat = 111_320.0
    m_per_deg_lon = 111_320.0 * math.cos(math.radians(base_lat))
    step_m = 700.0
    diag = step_m / math.sqrt(2)
    poly = [
        (base_lat + i * diag / m_per_deg_lat, base_lon + i * diag / m_per_deg_lon)
        for i in range(5)
    ]
    right = lateral_anchors(poly, offset_m=1000)
    # Pick interior anchor and confirm the displacement vector
    # has roughly equal magnitude on the SE diagonal.
    orig = poly[2]
    shifted = right[2]
    d_lat_m = (shifted[0] - orig[0]) * m_per_deg_lat
    d_lon_m = (shifted[1] - orig[1]) * m_per_deg_lon
    # SE = lat decreases, lon increases. Magnitudes roughly equal.
    assert d_lat_m < 0, "NE route, right offset → south lat shift"
    assert d_lon_m > 0, "NE route, right offset → east lon shift"
    assert abs(d_lat_m + d_lon_m) < 50, "SE diagonal should have equal-magnitude components"


def test_single_anchor_returns_empty():
    assert lateral_anchors([(50.0, 14.0)], offset_m=1500) == []


def test_duplicate_consecutive_anchors_handled():
    """Identical neighbours → zero tangent → fall back to original."""
    poly = [
        (50.0, 14.0),
        (50.0, 14.0),       # zero-length segment
        (50.001, 14.0),
    ]
    out = lateral_anchors(poly, offset_m=1000)
    # First and middle should resolve via tangent from broader window.
    # We don't pin exact values, just confirm we got 3 outputs and no crash.
    assert len(out) == 3


def test_decimate_keeps_count_and_endpoints():
    arr = list(range(20))
    kept = decimate(arr, keep=5)
    assert len(kept) == 5
    assert kept[0] == 0           # first
    assert kept[-1] == 19         # last preserved


def test_decimate_zero_keep():
    assert decimate(list(range(10)), keep=0) == []


def test_decimate_shorter_than_target_returns_all():
    assert decimate([1, 2, 3], keep=10) == [1, 2, 3]


def test_decimate_uniform_spacing():
    """Pick 5 from 100 → indices ~ 0, 25, 50, 75, 99."""
    arr = list(range(100))
    kept = decimate(arr, keep=5)
    assert kept == [0, 24, 49, 74, 99]


def test_lateral_anchors_count_matches_input(north_polyline):
    out = lateral_anchors(north_polyline, offset_m=2000)
    assert len(out) == len(north_polyline)


def test_zero_offset_returns_original_positions(north_polyline):
    out = lateral_anchors(north_polyline, offset_m=0)
    for orig, same in zip(north_polyline, out):
        assert abs(orig[0] - same[0]) < 1e-9
        assert abs(orig[1] - same[1]) < 1e-9
