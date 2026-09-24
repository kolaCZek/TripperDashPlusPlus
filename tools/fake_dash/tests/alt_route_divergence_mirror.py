"""
Python mirror of the alternative-route near-duplicate filter.

Mirrors `MapPickerView.maxDivergence(of:from:)` + the
`altMinDivergenceMeters` threshold used in `pushAlternativeRenders` to
suppress the phantom ETA bubble bug (field report, roundabout
50.3559,14.4549, 8/2026): MapKit near a roundabout returns an
"alternative" geometrically almost identical to the active route, whose
grey line renders invisibly under the blue one but whose ETA bubble still
floats. The fix drops any alt whose farthest vertex is closer than
`ALT_MIN_DIVERGENCE_M` to the active polyline.

Keep in sync with MapPickerView.swift.
"""

from __future__ import annotations

import math

EARTH_R = 6_371_000.0

# Mirror of MapPickerView.altMinDivergenceMeters.
ALT_MIN_DIVERGENCE_M = 25.0


def haversine(a: tuple[float, float], b: tuple[float, float]) -> float:
    """Great-circle distance in metres between (lat, lon) pairs."""
    lat1, lon1 = math.radians(a[0]), math.radians(a[1])
    lat2, lon2 = math.radians(b[0]), math.radians(b[1])
    dlat, dlon = lat2 - lat1, lon2 - lon1
    h = math.sin(dlat / 2) ** 2 + math.cos(lat1) * math.cos(lat2) * math.sin(dlon / 2) ** 2
    return 2 * EARTH_R * math.asin(min(1.0, math.sqrt(h)))


def _dist_to_segment(p, a, b) -> float:
    """Metres from p to segment a–b on a local equirectangular plane
    centred at p. Mirrors `MapPickerView.distance(from:toSegment:_:)`."""
    m_lat = 111_320.0
    m_lon = 111_320.0 * math.cos(math.radians(p[0]))
    ax, ay = (a[1] - p[1]) * m_lon, (a[0] - p[0]) * m_lat
    bx, by = (b[1] - p[1]) * m_lon, (b[0] - p[0]) * m_lat
    dx, dy = bx - ax, by - ay
    len2 = dx * dx + dy * dy
    t = max(0.0, min(1.0, -(ax * dx + ay * dy) / len2)) if len2 > 0 else 0.0
    cx, cy = ax + t * dx, ay + t * dy
    return math.hypot(cx, cy)


def _dist_to_polyline(p, poly) -> float:
    return min(_dist_to_segment(p, poly[j], poly[j + 1]) for j in range(len(poly) - 1))


def max_divergence(coords: list[tuple[float, float]],
                   reference: list[tuple[float, float]]) -> float:
    """Largest distance from sampled vertices of `coords` to the SEGMENTS
    of `reference`. Mirrors the Swift up-to-~40-vertex sampled scan.
    Segment distance matters: MapKit polylines are sparse on straight
    roads, and a vertex-only scan made a retiming of the SAME road look
    ~1 km off (field report, 9/2026)."""
    if len(reference) < 2:
        return float("inf")
    stride = max(1, len(coords) // 40)
    return max(_dist_to_polyline(coords[i], reference) for i in range(0, len(coords), stride))


def fork_index(coords: list[tuple[float, float]],
               reference: list[tuple[float, float]]) -> int:
    """Mirror of `MapPickerView.forkIndex`: last vertex still on the active
    line before the first one ≥ ALT_MIN_DIVERGENCE_M off it."""
    if len(reference) < 2:
        return len(coords) // 2
    for i, p in enumerate(coords):
        if _dist_to_polyline(p, reference) >= ALT_MIN_DIVERGENCE_M:
            return max(0, i - 1)
    return len(coords) // 2


def bubble_anchor_index(coords: list[tuple[float, float]],
                        reference: list[tuple[float, float]]) -> int:
    """Where `pushAlternativeRenders` pins the ETA bubble: the fork
    (midpoint when there is no active line)."""
    return fork_index(coords, reference) if reference else len(coords) // 2


def is_distinct_fork(coords: list[tuple[float, float]],
                     reference: list[tuple[float, float]]) -> bool:
    """True if the alt should be drawn (line + ETA bubble). Mirrors the
    two guards: needs >1 point AND must diverge past the threshold."""
    if len(coords) <= 1:
        return False
    if not reference:
        return True  # no active line to compare → keep (matches Swift)
    return max_divergence(coords, reference) >= ALT_MIN_DIVERGENCE_M
