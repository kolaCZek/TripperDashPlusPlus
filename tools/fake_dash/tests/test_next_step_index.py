"""
Tests for `PolylineMath.nextStepIndex(in:afterPolylineIndex:)` — the
mapping of each MKRoute.Step's start onto the route polyline that decides
which maneuver is surfaced next.

Field bug (Slaný, 6/2026 ride): on the route from 50.232856,14.175982 to
50.232983,14.084437 the junction at 50.225171,14.114728 was dropped from
the instructions ENTIRELY. From 50.239272,14.162810 onward the dash showed
a roundabout glyph with NO exit number, and the moment the rider passed the
dropped junction the glyph flipped to a plain right arrow.

Root cause: the old mapping snapped each step start to the FIRST route
vertex within a hard 5 m threshold, advancing a SHARED monotonic cursor:

    while pointIdx < count:
        if haversine(routePoints[pointIdx], stepStart) < 5: break
        pointIdx += 1

Two failure modes, both live on a city route:

  1. The route polyline is decimated — vertices sit ~10-30 m apart, so a
     step's start frequently has NO vertex within 5 m. The `while` then ran
     the shared cursor to the END of the polyline, corrupting the index for
     every later step (they'd all map past `segmentIndex` or fall off).

  2. Two maneuvers closer together than the vertex pitch — MapKit's
     roundabout entry/exit split, or two junctions in quick succession —
     could match the SAME vertex, so one step was silently skipped. That is
     exactly the dropped junction + the roundabout that "lost" its exit
     number (the exit step's stale .roundabout classification leaked through
     as the next surfaced step was wrong).

Fix: snap each step start to the NEAREST route vertex (argmin) searching
forward from a cursor, then advance the cursor to bestIdx + 1 so two steps
can never collapse onto one vertex. This Python file mirrors the new Swift
algorithm, table-tests the skip scenarios, and pins a Swift-source drift
guard so the hard-threshold regression can't silently come back.

Same discipline as test_roundabout_carry.py / maneuver_geometry_mirror.py:
a faithful Python twin of the pure logic + a sync assertion against Swift.
"""

from __future__ import annotations

import math
from pathlib import Path


EARTH_R = 6_371_000.0


def haversine(a: tuple[float, float], b: tuple[float, float]) -> float:
    """Mirror of `PolylineMath.haversine` (metres between two lat/lon)."""
    lat1, lat2 = math.radians(a[0]), math.radians(b[0])
    dlat = math.radians(b[0] - a[0])
    dlon = math.radians(b[1] - a[1])
    h = math.sin(dlat / 2) ** 2 + math.cos(lat1) * math.cos(lat2) * math.sin(dlon / 2) ** 2
    return 2 * EARTH_R * math.asin(min(1.0, math.sqrt(h)))


# Must match the rising-streak break in `PolylineMath.nextStepIndex`.
RISING_STREAK_BREAK = 8


def next_step_index(route_points: list[tuple[float, float]],
                    step_starts: list[tuple[float, float]],
                    segment_index: int) -> int | None:
    """Faithful mirror of the NEW `PolylineMath.nextStepIndex`.

    `route_points` is the route polyline's vertex list; `step_starts` is the
    first coordinate of each step's polyline (steps in route order).
    Returns the index of the first step whose nearest route vertex is
    strictly beyond `segment_index`, or None.
    """
    count = len(route_points)
    if count == 0:
        return None

    cursor = 0
    for step_idx, start in enumerate(step_starts):
        best_idx = cursor
        best_dist = float("inf")
        rising = 0
        i = cursor
        while i < count:
            d = haversine(route_points[i], start)
            if d < best_dist:
                best_dist = d
                best_idx = i
                rising = 0
            else:
                rising += 1
                if rising >= RISING_STREAK_BREAK:
                    break
            i += 1
        cursor = min(best_idx + 1, count - 1)
        if best_idx > segment_index:
            return step_idx
    return None


def old_next_step_index(route_points: list[tuple[float, float]],
                        step_starts: list[tuple[float, float]],
                        segment_index: int) -> int | None:
    """The OLD buggy algorithm, kept ONLY to demonstrate the regression in
    a test (so the fix is shown to actually change behaviour on the field
    case). First vertex within 5 m, shared monotonic cursor."""
    count = len(route_points)
    point_idx = 0
    for step_idx, start in enumerate(step_starts):
        while point_idx < count:
            if haversine(route_points[point_idx], start) < 5:
                break
            point_idx += 1
        if point_idx > segment_index:
            return step_idx
    return None


# ----------------------------------------------------------------------
# Synthetic route helpers.
# ----------------------------------------------------------------------

def line(a: tuple[float, float], b: tuple[float, float], n: int):
    """n evenly spaced vertices from a to b inclusive (decimated polyline)."""
    return [(a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t)
            for t in (k / (n - 1) for k in range(n))]


# ----------------------------------------------------------------------
# Core regression: a step whose start has no vertex within 5 m must still
# be found (and must not corrupt later steps).
# ----------------------------------------------------------------------

def test_off_grid_maneuver_does_not_corrupt_later_steps():
    """The cursor-blowout bug: a step start with NO route vertex within 5 m
    ran the OLD shared cursor to the end of the polyline. Once blown, the
    old algorithm can only ever return the EARLIEST step past segment_index
    — so once the rider has PASSED that off-grid maneuver, it keeps
    surfacing the stale, already-passed step instead of the next one.

    Decimated polyline ~22 m pitch; step 1 sits ~10 m from its nearest
    vertex (off-grid); the rider (segment_index=5) has already passed it.
    """
    route = line((50.2000, 14.1000), (50.2020, 14.1000), 11)   # ~22 m pitch
    off_grid = (50.20071, 14.1000)   # ~10 m from nearest vertex (v4) → off grid
    step_starts = [route[0], off_grid, route[7]]
    # Rider is at segment 5 — already past the off-grid maneuver (≈ vertex 4),
    # not yet at step 2's maneuver (vertex 7). The NEXT maneuver is step 2.
    assert next_step_index(route, step_starts, segment_index=5) == 2
    # The OLD algorithm blew the cursor to the end on the off-grid step and
    # surfaces the STALE, already-passed step 1 instead.
    assert old_next_step_index(route, step_starts, segment_index=5) == 1


def test_two_close_maneuvers_do_not_collapse():
    """Two junctions ~15 m apart on a 22 m-pitch polyline: both must map to
    DISTINCT vertices so neither maneuver is dropped. This is the Slaný
    dropped-junction shape (roundabout exit + immediate turn)."""
    route = line((50.2300, 14.1200), (50.2320, 14.1200), 11)  # ~22 m pitch
    j1 = (50.23085, 14.1200)   # near vertex ~4-5
    j2 = (50.230995, 14.1200)  # ~16 m past j1, near vertex ~5-6
    step_starts = [route[0], j1, j2]
    # From the start, the first upcoming maneuver is j1 (step 1).
    assert next_step_index(route, step_starts, segment_index=0) == 1
    # Once the rider is just past j1's vertex, j2 (step 2) must surface —
    # not be collapsed onto j1 and skipped.
    j1_vtx = min(range(len(route)), key=lambda i: haversine(route[i], j1))
    assert next_step_index(route, step_starts, segment_index=j1_vtx) == 2


def test_old_algorithm_skipped_a_close_maneuver():
    """Pin the actual regression: the OLD algorithm collapses j2 onto j1's
    vertex (or overshoots) and fails to surface step 2 from j1, while the
    NEW one does. If someone reverts the fix, this fails."""
    route = line((50.2300, 14.1200), (50.2320, 14.1200), 11)
    j1 = (50.23085, 14.1200)
    j2 = (50.230995, 14.1200)
    step_starts = [route[0], j1, j2]
    j1_vtx = min(range(len(route)), key=lambda i: haversine(route[i], j1))
    new = next_step_index(route, step_starts, segment_index=j1_vtx)
    old = old_next_step_index(route, step_starts, segment_index=j1_vtx)
    assert new == 2
    assert old != 2     # the bug: step 2 was not surfaced


# ----------------------------------------------------------------------
# Ordering + monotonicity: steps map to non-decreasing vertices and the
# returned index advances as the rider progresses.
# ----------------------------------------------------------------------

def test_steps_map_to_monotonic_nondecreasing_vertices():
    route = line((50.2000, 14.1000), (50.2100, 14.1300), 60)
    # Five step starts sampled in route order.
    step_starts = [route[0], route[12], route[25], route[40], route[58]]
    # Reconstruct the per-step best vertex the way the algorithm walks it.
    best = []
    cursor = 0
    for start in step_starts:
        bi, bd, rising, i = cursor, float("inf"), 0, cursor
        while i < len(route):
            d = haversine(route[i], start)
            if d < bd:
                bd, bi, rising = d, i, 0
            else:
                rising += 1
                if rising >= RISING_STREAK_BREAK:
                    break
            i += 1
        best.append(bi)
        cursor = min(bi + 1, len(route) - 1)
    assert best == sorted(best), f"step vertices not monotonic: {best}"
    assert len(set(best)) == len(best), f"two steps shared a vertex: {best}"


def test_returned_step_advances_with_progress():
    route = line((50.2000, 14.1000), (50.2100, 14.1000), 50)
    step_starts = [route[0], route[15], route[30], route[45]]
    seen = []
    for seg in (0, 14, 16, 29, 31, 44):
        seen.append(next_step_index(route, step_starts, seg))
    # As segment_index grows, the surfaced step index is non-decreasing.
    cleaned = [s for s in seen if s is not None]
    assert cleaned == sorted(cleaned), seen


def test_no_steps_returns_none():
    route = line((50.2000, 14.1000), (50.2100, 14.1000), 10)
    assert next_step_index(route, [], segment_index=0) is None


def test_empty_polyline_returns_none():
    assert next_step_index([], [(50.0, 14.0)], segment_index=0) is None


# ----------------------------------------------------------------------
# Swift-source drift guard: the hard 5 m threshold + shared monotonic
# `pointIdx += 1` walk must NOT come back, and the nearest-vertex cursor
# advance must be present.
# ----------------------------------------------------------------------

def _polyline_math_src() -> str:
    here = Path(__file__).resolve()
    repo_root = here.parents[3]
    swift = repo_root / "TripperDashPP" / "Navigation" / "PolylineMath.swift"
    return swift.read_text(encoding="utf-8")


def test_swift_dropped_the_hard_5m_threshold_walk():
    src = _polyline_math_src()
    idx = src.index("static func nextStepIndex")
    body = src[idx:idx + 2600]
    # The old failure shape was `haversine(p, stepStart) < 5` driving a
    # shared `pointIdx += 1` walk. Neither may survive in the function.
    assert "< 5 { break }" not in body, (
        "hard 5 m nearest-vertex threshold is back — the off-grid step "
        "start / cursor-blowout regression will recur"
    )
    assert "pointIdx" not in body, (
        "shared monotonic pointIdx walk is back — adjacent maneuvers can "
        "collapse onto one vertex again"
    )


def test_swift_uses_nearest_vertex_with_cursor_advance():
    src = _polyline_math_src()
    idx = src.index("static func nextStepIndex")
    body = src[idx:idx + 2600]
    # New algorithm markers: argmin (bestIdx / bestDist) + cursor advance to
    # just past the matched vertex.
    assert "bestIdx" in body and "bestDist" in body, (
        "nearest-vertex (argmin) mapping missing from nextStepIndex"
    )
    assert "bestIdx + 1" in body, (
        "cursor no longer advances past the matched vertex — two steps "
        "could collapse onto one vertex"
    )
