"""
Tests for the active-nav bubble distance bucketing
(`DashNavSettings.bucketedManeuverDistance`).

Field request (6/2026, Martin): the dash bubble's "in N m" line to the
next turn twitched on every GPS tick (437 → 436 → 438 …), which is
distracting on a moving bike. Quantize the MANEUVER distance into
proximity-scaled buckets so the number is stable but still precise in the
final approach:

  - < 50 m      → nearest 1 m    (42 → 42)        final approach, fine
  - 50 … <200 m → nearest 25 m   (73 → 75, 188 → 200)
  - >= 200 m    → nearest 100 m  (437 → 400, 985 → 1000)

The total-distance-to-destination is deliberately NOT bucketed (it ticks
down slowly; a rounded value there looks wrong on a long route), so only
the primary/secondary maneuver distances pass through this.

This mirrors the Swift implementation and pins the boundary behaviour.

IMPORTANT — rounding mode: Swift's `Double.rounded()` is
round-half-AWAY-from-zero, whereas Python's built-in `round()` is
round-half-to-EVEN (banker's). They disagree on exact `.5` bucket
boundaries (e.g. 62.5 m → 75 in Swift, 50 with `round()`), so the mirror
uses `math.floor(q + 0.5)` to match Swift exactly. The drift guard also
asserts the Swift source still calls `.rounded()` (not `.rounded(.toNearestOrEven)`).
"""

from __future__ import annotations

import math
import re
from pathlib import Path

import pytest


def _swift_settings_source() -> str:
    here = Path(__file__).resolve()
    repo_root = here.parents[3]
    swift = (
        repo_root / "TripperDashPP" / "Navigation" / "Models" / "DashNavSettings.swift"
    )
    return swift.read_text(encoding="utf-8")


def bucketed_maneuver_distance(m: float, imperial: bool = False) -> float:
    """Mirror of `DashNavSettings.bucketedManeuverDistance`. Uses
    floor(q + 0.5) to match Swift's round-half-away-from-zero `.rounded()`
    (all inputs here are positive).

    Unit-aware (#11): metric rides bucket in 1/25/100 m steps; imperial
    rides bucket in 10/50 ft then 0.1 mi steps so the converted readout
    lands on round imperial numbers. Returns METERS either way — the
    wire/unit-byte helpers re-derive ft/mi from it. The imperial feet↔miles
    crossover is 160 m, matching `primaryUnitWireByte`."""
    if not math.isfinite(m) or m <= 0:
        return 0.0
    if not imperial:
        if m < 50:
            step = 1.0
        elif m < 200:
            step = 25.0
        else:
            step = 100.0
        return math.floor(m / step + 0.5) * step
    # Imperial.
    ft_per_m = 3.280839895
    if m < 160:
        feet = m * ft_per_m
        step = 10.0 if feet < 150 else 50.0
        return (math.floor(feet / step + 0.5) * step) / ft_per_m
    step_m = 1609.344 / 10.0
    return math.floor(m / step_m + 0.5) * step_m


# ----------------------------------------------------------------------
# The exact values Martin called out, plus each bucket's interior.
# ----------------------------------------------------------------------

@pytest.mark.parametrize("meters, expected", [
    # Martin's worked examples.
    (437, 400),
    (188, 200),
    (73, 75),
    (42, 42),
    # < 50 m → nearest 1 m (effectively round to integer metre).
    (0.4, 0),
    (1, 1),
    (12.5, 13),     # half-away-from-zero
    (37.4, 37),
    (49, 49),
    (49.6, 50),     # rounds up into — value 50, still fine
    # 50 … <200 m → nearest 25 m.
    (50, 50),
    (51, 50),
    (62.5, 75),     # half-away (NOT 50, which banker's would give)
    (87, 75),
    (88, 100),
    (137.5, 150),   # half-away
    (199, 200),
    # >= 200 m → nearest 100 m.
    (200, 200),
    (249, 200),
    (250, 300),     # half-away
    (437, 400),
    (985, 1000),
    (1499, 1500),
    (1550, 1600),
])
def test_bucketed_values(meters, expected):
    assert bucketed_maneuver_distance(meters) == expected


# ----------------------------------------------------------------------
# Boundary semantics: the step changes at exactly 50 and 200.
# ----------------------------------------------------------------------

def test_bucket_step_boundaries():
    # Just below 50 → 1 m step (45 stays 45, not snapped to 50).
    assert bucketed_maneuver_distance(45) == 45
    # At 50 → 25 m step (50 stays 50).
    assert bucketed_maneuver_distance(50) == 50
    # Just below 200 → 25 m step (199 snaps to 200).
    assert bucketed_maneuver_distance(199) == 200
    # At 200 → 100 m step (200 stays 200).
    assert bucketed_maneuver_distance(200) == 200


def test_monotonic_non_decreasing():
    """Bucketing must never make a larger input map to a smaller bucket —
    the bubble number must not go *up* as the rider gets closer."""
    prev = -1.0
    m = 0.0
    while m <= 3000:
        b = bucketed_maneuver_distance(m)
        assert b >= prev - 1e-9, f"non-monotonic at {m}: {b} < {prev}"
        prev = b
        m += 0.5


def test_zero_and_nonfinite_guard():
    assert bucketed_maneuver_distance(0) == 0
    assert bucketed_maneuver_distance(-5) == 0
    assert bucketed_maneuver_distance(float("nan")) == 0
    assert bucketed_maneuver_distance(float("inf")) == 0
    # Same guards in imperial.
    assert bucketed_maneuver_distance(0, imperial=True) == 0
    assert bucketed_maneuver_distance(-5, imperial=True) == 0
    assert bucketed_maneuver_distance(float("nan"), imperial=True) == 0
    assert bucketed_maneuver_distance(float("inf"), imperial=True) == 0


# ----------------------------------------------------------------------
# Imperial bucketing (#11): the converted readout must land on round
# feet / tenths-of-a-mile, not the ragged conversion of a metric bucket.
# ----------------------------------------------------------------------

_FT = 3.280839895


@pytest.mark.parametrize("meters, expected_feet", [
    # Feet domain (< 160 m): 10 ft steps under 150 ft, 50 ft steps above.
    (5, 20),       # 16.4 ft → 20
    (9, 30),       # 29.5 ft → 30
    (30, 100),     # 98.4 ft → 100
    (45.72, 150),  # exactly 150 ft → stays (boundary into 50-step)
    (80, 250),     # 262 ft → 250
    (100, 350),    # 328 ft → 350
    (152, 500),    # 498.7 ft → 500
    (159, 500),    # 521.6 ft → still 500 (just under the mile crossover)
])
def test_imperial_feet_buckets_are_round(meters, expected_feet):
    b = bucketed_maneuver_distance(meters, imperial=True)
    assert round(b * _FT) == expected_feet


@pytest.mark.parametrize("meters, expected_tenths_mi", [
    # Miles domain (>= 160 m): nearest 0.1 mi.
    (160, 1),     # 0.0994 mi → 0.1
    (200, 1),     # 0.124 mi → 0.1
    (300, 2),     # 0.186 mi → 0.2
    (800, 5),     # 0.497 mi → 0.5
    (1609.344, 10),  # exactly 1.0 mi
    (2400, 15),   # 1.491 mi → 1.5
])
def test_imperial_mile_buckets_are_tenths(meters, expected_tenths_mi):
    b = bucketed_maneuver_distance(meters, imperial=True)
    tenths = round((b / 1609.344) * 10)
    assert tenths == expected_tenths_mi


def test_imperial_monotonic_non_decreasing():
    """Same invariant as metric: the imperial 'in N ft / N.N mi' readout
    must never increase as the rider gets closer to the turn."""
    prev = -1.0
    m = 0.0
    while m <= 4000:
        b = bucketed_maneuver_distance(m, imperial=True)
        assert b >= prev - 1e-9, f"non-monotonic at {m}: {b} < {prev}"
        prev = b
        m += 0.5


def test_imperial_feet_to_miles_crossover_matches_unit_byte():
    """The bucket's feet↔miles boundary (160 m) must equal the unit byte's
    crossover in primaryUnitWireByte, or a distance could bucket to feet
    but get tagged as miles (or vice-versa)."""
    src = _swift_settings_source()
    # primaryUnitWireByte switches imperial feet→miles at 160 m.
    assert "m < 160 ? 0x50 : 0x20" in src
    # The imperial bucket branch uses the same 160 m threshold.
    start = src.index("func bucketedManeuverDistance(")
    end = src.index("\n    }", start)
    body = src[start:end]
    assert "m < 160" in body, (
        "imperial bucket crossover drifted from primaryUnitWireByte's 160 m"
    )


# ----------------------------------------------------------------------
# Speeding tolerance is unit-aware (#10): canonical store is km/h, the
# stepper shows/sets mph for imperial riders.
# ----------------------------------------------------------------------

def tolerance_to_display(kmh: float, imperial: bool) -> int:
    """Mirror of DashNavSettings.toleranceToDisplay."""
    return (math.floor(kmh / 1.609344 + 0.5) if imperial
            else math.floor(kmh + 0.5))


def tolerance_to_kmh(display: int, imperial: bool) -> float:
    """Mirror of DashNavSettings.toleranceToKmh."""
    v = max(0, display)
    return v * 1.609344 if imperial else float(v)


def test_tolerance_metric_is_identity():
    assert tolerance_to_display(3, imperial=False) == 3
    assert tolerance_to_kmh(5, imperial=False) == 5.0


def test_tolerance_default_3kmh_shows_2mph():
    # 3 km/h is the default; an imperial rider sees +2 mph.
    assert tolerance_to_display(3.0, imperial=True) == 2


def test_tolerance_mph_round_trips_through_kmh():
    # Dialing 5 mph stores ~8.05 km/h and reads back as 5 mph.
    kmh = tolerance_to_kmh(5, imperial=True)
    assert abs(kmh - 8.04672) < 1e-4
    assert tolerance_to_display(kmh, imperial=True) == 5


def test_tolerance_clamps_negative_to_zero():
    assert tolerance_to_kmh(-3, imperial=True) == 0.0
    assert tolerance_to_kmh(-3, imperial=False) == 0.0


def test_swift_tolerance_helpers_exist_and_match():
    """Drift guard: the Swift conversion helpers must exist with the same
    1.609344 factor and clamp, or the stepper and the km/h store diverge."""
    src = _swift_settings_source()
    assert "static func toleranceToDisplay(kmh: Double, imperial: Bool) -> Int" in src
    assert "static func toleranceToKmh(display: Int, imperial: Bool) -> Double" in src
    assert "1.609344" in src
    assert "max(0, display)" in src


# ----------------------------------------------------------------------
# Swift-source drift guard: thresholds + rounding mode must match.
# ----------------------------------------------------------------------

def test_swift_bucket_thresholds_match_mirror():
    src = _swift_settings_source()
    # Locate the bucketing function body (signature → closing brace).
    start = src.index("func bucketedManeuverDistance(")
    end = src.index("\n    }", start)
    body = src[start:end]
    # The metric thresholds (50, 200) and the three steps (1, 25, 100)
    # must all be literally present in the Swift body.
    for needed in ("< 50", "< 200", "= 1", "= 25", "= 100"):
        assert needed in body, (
            f"Bucket constant '{needed}' missing from Swift "
            f"bucketedManeuverDistance — thresholds drifted from this mirror."
        )


def test_swift_uses_round_half_away_not_banker():
    """If someone changes the Swift `.rounded()` to `.rounded(.toNearestOrEven)`
    the `.5`-boundary buckets would silently diverge from this mirror.
    Pin the plain `.rounded()` call."""
    src = _swift_settings_source()
    start = src.index("func bucketedManeuverDistance(")
    end = src.index("\n    }", start)
    body = src[start:end]
    assert ".rounded()" in body, "expected a plain .rounded() call in bucketing"
    assert ".toNearestOrEven" not in body, (
        "bucketing switched to banker's rounding — the mirror uses "
        "round-half-away-from-zero, they will disagree on .5 boundaries."
    )
