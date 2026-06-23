"""
Tests for the geometry-based turn-direction classifier
(`ManeuverGeometry.swift`) and the hybrid `ManeuverKind.classify`.

Two field bugs motivated this whole change (6/2026 ride):

  Bug A — roundabout exit 1 rendered as exit 3 (byte 0x0D not 0x0B),
          because the old parser grabbed the first digit anywhere in the
          string. Covered by `test_roundabout_parser.py`.

  Bug B — a RIGHT turn rendered as a LEFT arrow (byte 0x14 not 0x15),
          because the old classifier substring-matched "left" anywhere in
          the clause (incl. the road name) and checked left before right.

The fix derives turn DIRECTION from route geometry (the signed angle
between incoming and outgoing headings), which is language-independent
and immune to road names. These tests pin:

  1. the geometry math (bearing, signed delta, anchor-distance sampling),
  2. the angle→bucket thresholds,
  3. the jitter-robustness that makes it trustworthy on real polylines,
  4. that the Swift thresholds / anchor distance match this mirror.

fake_dash can't run Swift, so the hybrid classifier is mirrored as a
small pure-Python function and table-tested for the family routing +
the two bug reproductions.
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest

from tests.maneuver_geometry_mirror import (
    ANCHOR_DISAGREEMENT_DEG,
    ANCHOR_DISTANCE_M,
    SHORT_ANCHOR_DISTANCE_M,
    bearing,
    offset,
    signed_delta,
    turn,
    turn_for_angle,
)

# A maneuver node somewhere in Czechia.
NODE = (50.0, 14.0)


def _swift_geometry_source() -> str:
    here = Path(__file__).resolve()
    repo_root = here.parents[3]
    swift = repo_root / "TripperDashPP" / "Navigation" / "Models" / "ManeuverGeometry.swift"
    return swift.read_text(encoding="utf-8")


# ----------------------------------------------------------------------
# Bearing / signed-delta primitives.
# ----------------------------------------------------------------------

def test_bearing_cardinals():
    assert abs(bearing(NODE, offset(*NODE, 0, 50)) - 0) < 0.5      # north
    assert abs(bearing(NODE, offset(*NODE, 90, 50)) - 90) < 0.5    # east
    assert abs(bearing(NODE, offset(*NODE, 180, 50)) - 180) < 0.5  # south
    assert abs(bearing(NODE, offset(*NODE, 270, 50)) - 270) < 0.5  # west


@pytest.mark.parametrize("i,o,expected", [
    (0, 90, 90),     # right
    (0, 270, -90),   # left (shorter way round)
    (90, 0, -90),    # left
    (350, 10, 20),   # wrap across north, right
    (10, 350, -20),  # wrap across north, left
    # Exact 180° is the half-open boundary: the shared formula
    # `(o-i+540)%360-180` yields -180 (range [-180, 180)). The sign of a
    # perfect U-turn is arbitrary and never occurs with real GPS coords;
    # what matters is Swift and this mirror agree on the boundary value.
    (0, 180, -180),
])
def test_signed_delta(i, o, expected):
    assert abs(signed_delta(i, o) - expected) < 0.001


# ----------------------------------------------------------------------
# Angle → bucket thresholds.
# ----------------------------------------------------------------------

@pytest.mark.parametrize("angle,expected", [
    (0, "straight"), (5, "straight"), (-5, "straight"),
    (12, "slightRight"), (-12, "slightLeft"), (30, "slightRight"),
    (35, "right"), (-35, "left"), (90, "right"), (-90, "left"), (109, "right"),
    (110, "sharpRight"), (-110, "sharpLeft"), (159, "sharpRight"),
    (160, "uTurnRight"), (-160, "uTurnLeft"), (180, "uTurnRight"),
    (None, None),
])
def test_turn_for_angle(angle, expected):
    assert turn_for_angle(angle) == expected


# ----------------------------------------------------------------------
# End-to-end geometry: build incoming + outgoing legs, classify.
# ----------------------------------------------------------------------

def _legs(approach_brg: float, depart_brg: float, leg_m: float = 60):
    """Incoming leg ENDS at NODE (heading `approach_brg`); outgoing leg
    STARTS at NODE (heading `depart_brg`)."""
    prev = [offset(*NODE, (approach_brg + 180) % 360, leg_m), NODE]
    cur = [NODE, offset(*NODE, depart_brg, leg_m)]
    return prev, cur


@pytest.mark.parametrize("approach,depart,expected", [
    (0, 0, "straight"),
    (0, 90, "right"),
    (0, 270, "left"),
    (0, 20, "slightRight"),
    (0, 340, "slightLeft"),
    (0, 140, "sharpRight"),
    (0, 220, "sharpLeft"),
    (90, 180, "right"),     # heading east, turn to south = right
    (90, 0, "left"),        # heading east, turn to north = left
])
def test_geometry_classifies_turn(approach, depart, expected):
    prev, cur = _legs(approach, depart)
    assert turn(prev, cur) == expected


def test_first_step_has_no_incoming_leg():
    """No previous polyline → no angle → None (caller falls back to text)."""
    _, cur = _legs(0, 90)
    assert turn(None, cur) is None


# ----------------------------------------------------------------------
# Bug B reproduction at the geometry level: a RIGHT turn must read right
# regardless of any text. Plus the jitter-robustness that makes it safe.
# ----------------------------------------------------------------------

def test_bug_b_right_turn_reads_right_from_geometry():
    """The field bug: rider turned right, dash showed a left arrow. With
    geometry the right turn is unambiguous."""
    prev, cur = _legs(approach_brg=0, depart_brg=90)   # north then east = right
    assert turn(prev, cur) == "right"


def test_jitter_segment_does_not_flip_direction():
    """A sub-meter jitter vertex right at the node would flip a naive
    last-segment bearing read. The distance-accumulating sampler must
    ignore it and still read the real +90° right turn."""
    # Incoming: 80 m from due south up to NODE, with a 0.4 m WSW blip just
    # before the node.
    p_start = offset(*NODE, 180, 80)
    p_jitter = offset(*NODE, 250, 0.4)
    prev = [p_start, p_jitter, NODE]
    # Outgoing: 0.3 m NNE blip, then 60 m due east.
    c_jit = offset(*NODE, 20, 0.3)
    c_end = offset(*NODE, 90, 60)
    cur = [NODE, c_jit, c_end]

    assert turn(prev, cur) == "right", (
        "Jitter vertex flipped the turn — anchor-distance sampling is "
        "not accumulating enough span before taking the bearing."
    )


# ----------------------------------------------------------------------
# Swift ↔ Python sync: thresholds + anchor distance must match.
# ----------------------------------------------------------------------

def test_swift_anchor_distance_matches_mirror():
    src = _swift_geometry_source()
    m = re.search(r"anchorDistanceMeters:\s*CLLocationDistance\s*=\s*([\d.]+)", src)
    assert m, "Could not find anchorDistanceMeters in Swift source."
    assert float(m.group(1)) == ANCHOR_DISTANCE_M, (
        f"Anchor distance drift: Swift {m.group(1)} vs mirror {ANCHOR_DISTANCE_M}"
    )


def test_swift_angle_thresholds_match_mirror():
    """The four threshold magnitudes (12 / 35 / 110 / 160) must match the
    mirror's `turn_for_angle`, or a turn that reads 'right' here could read
    'sharpRight' on the bike."""
    src = _swift_geometry_source()
    # Pull the numeric bounds out of the `switch mag` cases.
    bounds = set(re.findall(r"case\s+([\d]+)\.\.<?", src))
    bounds |= set(re.findall(r"(\d+)\.\.\.:", src))      # `case 160...:`
    for needed in ("12", "35", "110", "160"):
        assert needed in bounds, (
            f"Threshold {needed} missing from Swift `turn(forSignedAngle:)` "
            f"switch — found bounds {sorted(bounds)}."
        )


# ----------------------------------------------------------------------
# Adaptive short/long anchor scheme (6/2026 Zvoleneves field bug).
# ----------------------------------------------------------------------

def test_swift_short_anchor_matches_mirror():
    src = _swift_geometry_source()
    m = re.search(r"shortAnchorDistanceMeters:\s*CLLocationDistance\s*=\s*([\d.]+)", src)
    assert m, "Could not find shortAnchorDistanceMeters in Swift source."
    assert float(m.group(1)) == SHORT_ANCHOR_DISTANCE_M, (
        f"Short anchor drift: Swift {m.group(1)} vs mirror {SHORT_ANCHOR_DISTANCE_M}"
    )


def test_swift_disagreement_threshold_matches_mirror():
    src = _swift_geometry_source()
    m = re.search(r"anchorDisagreementDeg:\s*Double\s*=\s*([\d.]+)", src)
    assert m, "Could not find anchorDisagreementDeg in Swift source."
    assert float(m.group(1)) == ANCHOR_DISAGREEMENT_DEG, (
        f"Disagreement threshold drift: Swift {m.group(1)} vs mirror "
        f"{ANCHOR_DISAGREEMENT_DEG}"
    )


def test_adaptive_anchor_reads_sharp_turnin_over_flattened_long():
    """The Zvoleneves field bug: a right turn at a stop sign whose road
    bends left ~60 m past the corner. The 18 m long anchor reaches into
    that following bend and flattens the angle to ~+28° (slightRight); the
    8 m short anchor sits inside the corner and reads the true ~+61°
    (right). With disagreement > 15° the adaptive scheme must pick the
    short read so the rider sees a proper right arrow, not a slight one.
    """
    # Approach: 60 m from due south up to NODE (heading north).
    prev = [offset(*NODE, 180, 60), NODE]
    # Outgoing: a 10 m sharp turn-in at +61°, then 100 m bending back
    # toward +25° (the road curving left past the corner).
    b1 = offset(*NODE, 61, 10)
    b2 = offset(*b1, 25, 100)
    cur = [NODE, b1, b2]
    assert turn(prev, cur) == "right", (
        "Adaptive anchor failed to recover the sharp turn-in — the long "
        "anchor's flattened angle won, which is the original field bug."
    )


def test_adaptive_anchor_keeps_long_read_when_anchors_agree():
    """On a clean turn (straight approach, straight departure) the short
    and long anchors agree, so the jitter-robust long read is kept. This
    pins the 'strict superset, no regression' property."""
    # Both legs single-segment and straight: 90° right, no following bend.
    prev = [offset(*NODE, 180, 60), NODE]      # heading north
    cur = [NODE, offset(*NODE, 90, 60)]        # heading east
    assert turn(prev, cur) == "right"


def test_jitter_robustness_survives_adaptive_scheme():
    """Belt-and-braces: the adaptive scheme must NOT reintroduce the
    jitter sensitivity the long anchor was added to kill. A sub-meter blip
    at the node still classifies as a clean right turn (the short anchor
    is 8 m — well past the 0.4 m jitter — and agrees with the long read).
    """
    p_start = offset(*NODE, 180, 80)
    p_jitter = offset(*NODE, 250, 0.4)
    prev = [p_start, p_jitter, NODE]
    c_jit = offset(*NODE, 20, 0.3)
    c_end = offset(*NODE, 90, 60)
    cur = [NODE, c_jit, c_end]
    assert turn(prev, cur) == "right"
