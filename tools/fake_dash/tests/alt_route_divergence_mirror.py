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


def max_divergence(coords: list[tuple[float, float]],
                   reference: list[tuple[float, float]]) -> float:
    """Largest distance from any sampled vertex of `coords` to the
    nearest vertex of `reference`. Mirrors the Swift vertex-sampled
    (up to ~40) nearest-vertex scan."""
    if len(reference) < 2:
        return float("inf")
    worst = 0.0
    stride = max(1, len(coords) // 40)
    i = 0
    while i < len(coords):
        p = coords[i]
        nearest = min(haversine(p, r) for r in reference)
        worst = max(worst, nearest)
        i += stride
    return worst


def is_distinct_fork(coords: list[tuple[float, float]],
                     reference: list[tuple[float, float]]) -> bool:
    """True if the alt should be drawn (line + ETA bubble). Mirrors the
    two guards: needs >1 point AND must diverge past the threshold."""
    if len(coords) <= 1:
        return False
    if not reference:
        return True  # no active line to compare → keep (matches Swift)
    return max_divergence(coords, reference) >= ALT_MIN_DIVERGENCE_M
