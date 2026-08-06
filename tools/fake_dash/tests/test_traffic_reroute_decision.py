"""
Python mirror of the live-traffic reroute decision core, as implemented in:

  - TripperDashPP/Navigation/ActiveNavigator.swift
    (`trafficRerouteDecision(...)` + `routesAreDistinct(...)` — the pure,
    actor-free, MapKit-free decision functions)

The Swift methods are deliberately `static` and free of actor state /
MapKit calls precisely so their logic can be pinned here cheaply (a real
XCTest would need an MKRoute + MKDirections mock; this is far cheaper and
runs in the same fake_dash suite as the rest of the nav mirrors).

## What the feature does (feat/live-traffic-reroute)

While navigating, the ETA re-fetch pump ALSO (when the opt-in
`trafficRerouteEnabled` setting is on) asks Apple for the current
traffic-aware alternative set from the rider's live position to the SAME
destination. `trafficRerouteDecision` then decides whether to swap:

  - baseline = the current route's live `expectedTravelTime`
  - a candidate is only eligible if it is a genuinely DIFFERENT road
    (`routesAreDistinct` — a mid-route sample of one path strays > 120 m
    from the other). This stops a "reroute" onto an identical road that
    Apple merely re-timed faster because traffic eased.
  - the fastest eligible candidate must beat the baseline by at least the
    user's `savingThreshold` seconds (default 300 s = 5 min).

Conservative by construction: no distinct + faster-by-threshold candidate
→ return None → DON'T reroute.
"""

from __future__ import annotations

import math
from dataclasses import dataclass


# --- Geometry primitive (mirror of PolylineMath.haversine) ------------------


def haversine(a: tuple[float, float], b: tuple[float, float]) -> float:
    """Great-circle distance in metres between (lat, lon) pairs."""
    R = 6_371_000.0
    lat1, lon1 = a
    lat2, lon2 = b
    p1 = lat1 * math.pi / 180
    p2 = lat2 * math.pi / 180
    dp = (lat2 - lat1) * math.pi / 180
    dl = (lon2 - lon1) * math.pi / 180
    h = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return R * 2 * math.atan2(math.sqrt(h), math.sqrt(1 - h))


# --- Decision core (mirror of ActiveNavigator.routesAreDistinct) ------------


def routes_are_distinct(
    a: list[tuple[float, float]],
    b: list[tuple[float, float]],
    threshold_meters: float = 120.0,
) -> bool:
    if len(a) < 2 or len(b) < 2:
        return False
    fractions = [0.2, 0.35, 0.5, 0.65, 0.8]
    for f in fractions:
        idx = min(len(a) - 1, max(0, int((len(a) - 1) * f)))
        p = a[idx]
        nearest = float("inf")
        for q in b:
            d = haversine(p, q)
            if d < nearest:
                nearest = d
            if nearest <= threshold_meters:
                break
        if nearest > threshold_meters:
            return True
    return False


@dataclass
class Candidate:
    time: float
    coords: list[tuple[float, float]]


def traffic_reroute_decision(
    current_baseline_time: float,
    candidates: list[Candidate],
    current_coords: list[tuple[float, float]],
    saving_threshold: float,
    distinct_threshold_meters: float = 120.0,
):
    """Returns (best_index, saving_seconds) or None. Mirror of
    ActiveNavigator.trafficRerouteDecision."""
    if not (math.isfinite(current_baseline_time) and current_baseline_time > 0):
        return None
    best_idx = None
    best_time = current_baseline_time - saving_threshold  # must beat this
    for i, cand in enumerate(candidates):
        if not (math.isfinite(cand.time) and cand.time > 0):
            continue
        if not routes_are_distinct(
            current_coords, cand.coords, distinct_threshold_meters
        ):
            continue
        if cand.time < best_time:
            best_time = cand.time
            best_idx = i
    if best_idx is None:
        return None
    return (best_idx, current_baseline_time - candidates[best_idx].time)


# --- Test fixtures ----------------------------------------------------------

# A straight-ish "current" corridor heading roughly east from Slaný.
CURRENT = [
    (50.2300, 14.0850),
    (50.2305, 14.0950),
    (50.2310, 14.1050),
    (50.2315, 14.1150),
    (50.2320, 14.1250),
]

# A clearly DIFFERENT road: same endpoints, but bulging ~1 km north in the
# middle (a real alternative corridor).
ALT_DISTINCT = [
    (50.2300, 14.0850),
    (50.2405, 14.0950),
    (50.2410, 14.1050),
    (50.2415, 14.1150),
    (50.2320, 14.1250),
]

# The SAME road as CURRENT, jittered by a few metres per vertex (GPS /
# decimation noise) — must NOT count as distinct.
ALT_SAME_JITTERED = [
    (50.23001, 14.08501),
    (50.23052, 14.09499),
    (50.23099, 14.10502),
    (50.23151, 14.11498),
    (50.23200, 14.12501),
]


# --- routes_are_distinct -----------------------------------------------------


def test_bulging_alternative_is_distinct():
    assert routes_are_distinct(CURRENT, ALT_DISTINCT) is True


def test_same_road_with_gps_jitter_is_not_distinct():
    assert routes_are_distinct(CURRENT, ALT_SAME_JITTERED) is False


def test_identical_path_is_not_distinct():
    assert routes_are_distinct(CURRENT, list(CURRENT)) is False


def test_degenerate_paths_are_not_distinct():
    assert routes_are_distinct([(50.0, 14.0)], CURRENT) is False
    assert routes_are_distinct(CURRENT, [(50.0, 14.0)]) is False


# --- traffic_reroute_decision: the threshold gate ---------------------------


def test_faster_distinct_route_over_threshold_reroutes():
    """Baseline 20 min, a distinct alt at 13 min → saving 7 min ≥ 5 min → swap."""
    dec = traffic_reroute_decision(
        current_baseline_time=1200,
        candidates=[Candidate(time=780, coords=ALT_DISTINCT)],
        current_coords=CURRENT,
        saving_threshold=300,
    )
    assert dec is not None
    idx, saving = dec
    assert idx == 0
    assert saving == 420  # 7 min


def test_faster_but_under_threshold_does_not_reroute():
    """Baseline 20 min, distinct alt at 17 min → saving 3 min < 5 min → no swap."""
    dec = traffic_reroute_decision(
        current_baseline_time=1200,
        candidates=[Candidate(time=1020, coords=ALT_DISTINCT)],
        current_coords=CURRENT,
        saving_threshold=300,
    )
    assert dec is None


def test_saving_exactly_at_threshold_does_not_reroute():
    """Strictly-less-than gate: a candidate that saves EXACTLY the threshold
    must NOT fire (cand.time < baseline - threshold is strict). 1200-300=900;
    a 900 s candidate is not < 900."""
    dec = traffic_reroute_decision(
        current_baseline_time=1200,
        candidates=[Candidate(time=900, coords=ALT_DISTINCT)],
        current_coords=CURRENT,
        saving_threshold=300,
    )
    assert dec is None


def test_one_second_over_threshold_reroutes():
    """Complement to the exact-threshold test — 301 s of saving clears it."""
    dec = traffic_reroute_decision(
        current_baseline_time=1200,
        candidates=[Candidate(time=899, coords=ALT_DISTINCT)],
        current_coords=CURRENT,
        saving_threshold=300,
    )
    assert dec is not None
    assert dec[1] == 301


# --- traffic_reroute_decision: the distinctness gate ------------------------


def test_faster_but_same_road_does_not_reroute():
    """THE key guard: Apple re-times the SAME road 6 min faster (traffic
    eased). Big saving, but it's the identical corridor → no swap (no point
    re-baking tiles + flashing the dash for a road the rider is already on)."""
    dec = traffic_reroute_decision(
        current_baseline_time=1200,
        candidates=[Candidate(time=840, coords=ALT_SAME_JITTERED)],
        current_coords=CURRENT,
        saving_threshold=300,
    )
    assert dec is None


def test_picks_fastest_among_multiple_distinct_candidates():
    """Two distinct alternatives both over threshold → the FASTEST wins."""
    # A second distinct corridor bulging SOUTH, slightly slower than ALT_DISTINCT.
    alt_south = [
        (50.2300, 14.0850),
        (50.2205, 14.0950),
        (50.2200, 14.1050),
        (50.2205, 14.1150),
        (50.2320, 14.1250),
    ]
    dec = traffic_reroute_decision(
        current_baseline_time=1200,
        candidates=[
            Candidate(time=900 - 1, coords=alt_south),      # 899 s (barely qualifies)
            Candidate(time=780, coords=ALT_DISTINCT),       # 780 s (faster)
        ],
        current_coords=CURRENT,
        saving_threshold=300,
    )
    assert dec is not None
    idx, saving = dec
    assert idx == 1  # the faster ALT_DISTINCT
    assert saving == 420


def test_same_road_ignored_even_when_a_distinct_one_qualifies():
    """A fast same-road candidate is skipped, a slower distinct one is taken."""
    dec = traffic_reroute_decision(
        current_baseline_time=1200,
        candidates=[
            Candidate(time=600, coords=ALT_SAME_JITTERED),  # fastest, but same road
            Candidate(time=850, coords=ALT_DISTINCT),       # distinct, over threshold
        ],
        current_coords=CURRENT,
        saving_threshold=300,
    )
    assert dec is not None
    idx, _ = dec
    assert idx == 1


# --- traffic_reroute_decision: bad input / edge cases -----------------------


def test_no_candidates_returns_none():
    assert (
        traffic_reroute_decision(1200, [], CURRENT, 300) is None
    )


def test_nonfinite_baseline_returns_none():
    assert (
        traffic_reroute_decision(float("inf"), [Candidate(600, ALT_DISTINCT)], CURRENT, 300)
        is None
    )
    assert (
        traffic_reroute_decision(0, [Candidate(600, ALT_DISTINCT)], CURRENT, 300)
        is None
    )


def test_candidate_with_bad_time_is_skipped():
    dec = traffic_reroute_decision(
        current_baseline_time=1200,
        candidates=[
            Candidate(time=float("nan"), coords=ALT_DISTINCT),
            Candidate(time=0, coords=ALT_DISTINCT),
        ],
        current_coords=CURRENT,
        saving_threshold=300,
    )
    assert dec is None


def test_slower_alternative_never_reroutes():
    """A distinct but SLOWER alternative (traffic worse there) → no swap."""
    dec = traffic_reroute_decision(
        current_baseline_time=1200,
        candidates=[Candidate(time=1500, coords=ALT_DISTINCT)],
        current_coords=CURRENT,
        saving_threshold=300,
    )
    assert dec is None
