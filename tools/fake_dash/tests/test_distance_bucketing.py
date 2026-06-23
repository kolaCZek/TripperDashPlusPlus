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


def bucketed_maneuver_distance(m: float) -> float:
    """Mirror of `DashNavSettings.bucketedManeuverDistance`. Uses
    floor(q + 0.5) to match Swift's round-half-away-from-zero `.rounded()`
    (all inputs here are positive)."""
    if not math.isfinite(m) or m <= 0:
        return 0.0
    if m < 50:
        step = 1.0
    elif m < 200:
        step = 25.0
    else:
        step = 100.0
    return math.floor(m / step + 0.5) * step


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


# ----------------------------------------------------------------------
# Swift-source drift guard: thresholds + rounding mode must match.
# ----------------------------------------------------------------------

def test_swift_bucket_thresholds_match_mirror():
    src = _swift_settings_source()
    # Locate the bucketing function body (signature → closing brace).
    start = src.index("func bucketedManeuverDistance(")
    end = src.index("\n    }", start)
    body = src[start:end]
    # The two thresholds (50, 200) and the three steps (1, 25, 100) must
    # all be literally present in the Swift body.
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
