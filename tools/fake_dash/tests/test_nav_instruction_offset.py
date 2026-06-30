"""
Regression for the navigation INSTRUCTION OFF-BY-ONE (Prague, 6/2026 ride).

Field symptom
-------------
On a real ride the dash bubble's TEXT named a maneuver one step too far
ahead of the ARROW the rider was meant to follow. E.g. the dash drew a
left arrow for "turn left onto Papírenská" (correct for the corner the
rider was at) but printed the text "Turn right onto Mlýnská" — the turn
AFTER the next one. The arrow was right; the words were a maneuver ahead.

Root cause
----------
`MKRoute.Step.instructions` describes the maneuver at the END of that
step's polyline — the turn ONTO the next road — NOT a maneuver at the
step's start. So the step whose `.instructions` name the UPCOMING maneuver
is the one the rider is currently TRAVERSING (its polyline ends at the
upcoming node): `ActiveNavigator.stepBeforeNext` (the ARRIVING step). The
old code read the text from `nextStep` (the DEPARTING step, whose polyline
LEAVES the node), which is one maneuver further on. The turn ARROW was
already correct because it comes from the GEOMETRY at the node (the angle
between the arriving leg and the departing leg) — geometry and text were
simply sourced from different nodes.

What this file pins
-------------------
A distilled REAL field log (`fixtures/nav_replay_121712.json`: one
representative tick per maneuver segment, chosen closest to each node)
is replayed two ways:

  1. `test_field_log_reproduces_the_off_by_one` — with the OLD pairing
     (this segment's own text vs this node's arrow geometry) the text
     side disagrees with the arrow on most plain turns: the bug.

  2. `test_corrected_pairing_aligns_text_with_arrow` — with the FIXED
     pairing (the PREVIOUS segment's text — i.e. `stepBeforeNext`'s
     instructions — vs this node's arrow geometry) text and arrow agree
     on every plain-turn node.

  3. Swift-source drift guards — `ActiveNavigator.upcomingInstructions`
     reads `stepBeforeNext` (not `nextStep`), the derived `upcomingManeuver`
     classifies the arriving step against the departing step, and the
     secondary distance is built from the departing leg, not the leg after
     the secondary node. So a refactor that reintroduces the off-by-one
     fails loudly here, on Linux CI, instead of on a moving bike.

Same discipline as test_roundabout_carry.py / test_next_step_index.py:
a faithful replay of the pure logic plus a Swift-source sync assertion.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from tests.maneuver_geometry_mirror import signed_turn_angle, turn as geo_turn

# ----------------------------------------------------------------------
# Fixture loading.
# ----------------------------------------------------------------------

FIXTURE = Path(__file__).resolve().parent / "fixtures" / "nav_replay_121712.json"


def _load_segments() -> list[dict]:
    data = json.loads(FIXTURE.read_text(encoding="utf-8"))
    return data["segments"]


def _repo_root() -> Path:
    return Path(__file__).resolve().parents[3]


# ----------------------------------------------------------------------
# Side helpers — collapse a turn/angle/text to L / R / S(traight).
# ----------------------------------------------------------------------

def _turn_side(turn: str | None) -> str | None:
    if turn is None:
        return None
    if turn == "straight":
        return "S"
    if "Left" in turn or turn == "left":
        return "L"
    if "Right" in turn or turn == "right":
        return "R"
    return None


def _text_side(instruction: str) -> str | None:
    """Earliest of the left/right tokens wins (so a road name later in the
    clause can't override the turn verb). None when neither appears."""
    s = instruction.lower()
    li, ri = s.find("left"), s.find("right")
    if li < 0 and ri < 0:
        return None
    if li < 0:
        return "R"
    if ri < 0:
        return "L"
    return "L" if li < ri else "R"


def _is_roundabout(s: str) -> bool:
    return "roundabout" in s.lower()


def _is_uturn(s: str) -> bool:
    low = s.lower()
    return "u-turn" in low or "make a u" in low


def _geometry_side(seg: dict) -> str | None:
    """The arrow's side at this segment's node, from the polyline anchors
    (mirrors what ManeuverGeometry produces for the dash glyph)."""
    if not seg.get("hasGeometry"):
        return None
    prev = [tuple(p) for p in seg["prevPolyTail"]]
    nxt = [tuple(p) for p in seg["nextPolyHead"]]
    return _turn_side(geo_turn(prev if len(prev) >= 2 else None, nxt))


def _plain_turn_nodes(segments: list[dict]):
    """Yield (k, geo_side, prev_text_side, this_text_side) for nodes whose
    PRECEDING segment is a plain (non-roundabout, non-U-turn) L/R turn and
    whose geometry resolves to a definite L/R. These are the nodes where
    text and arrow are both unambiguous, so the off-by-one is decidable."""
    for k in range(1, len(segments)):
        seg, prev = segments[k], segments[k - 1]
        g = _geometry_side(seg)
        if g not in ("L", "R"):
            continue
        prev_instr = prev["instructions"]
        if _is_roundabout(prev_instr) or _is_uturn(prev_instr):
            continue
        pts = _text_side(prev_instr)
        if pts not in ("L", "R"):
            continue
        yield k, g, pts, _text_side(seg["instructions"])


# ----------------------------------------------------------------------
# 1. The bug reproduces on the real log.
# ----------------------------------------------------------------------

def test_fixture_present_and_shaped():
    segs = _load_segments()
    assert len(segs) >= 10, "fixture lost segments"
    assert sum(1 for s in segs if s.get("hasGeometry")) >= 8, (
        "fixture lost the polyline anchors the replay needs"
    )


def test_field_log_reproduces_the_off_by_one():
    """OLD pairing: each segment's OWN text vs the arrow geometry at its
    node. On the field log these DISAGREE on most plain turns — that is the
    bug the rider saw (words a maneuver ahead of the arrow)."""
    segs = _load_segments()
    nodes = list(_plain_turn_nodes(segs))
    assert nodes, "no decidable plain-turn nodes in fixture"

    # Compare THIS segment's text side to THIS node's arrow side.
    agree = sum(1 for _, g, _prev, this in nodes if this is not None and this == g)
    total = sum(1 for _, _g, _prev, this in nodes if this is not None)
    assert total >= 6, "not enough decidable nodes to demonstrate the bug"
    # The whole point of the bug: same-step text rarely matches the arrow.
    # On the captured ride it's a minority (≈3/9). Pin "clearly broken".
    assert agree / total < 0.5, (
        f"same-step text matched the arrow {agree}/{total} times — the "
        f"off-by-one no longer reproduces, so this regression test has "
        f"lost its teeth (did the fixture change?)."
    )


# ----------------------------------------------------------------------
# 2. The fix aligns text with the arrow.
# ----------------------------------------------------------------------

def test_corrected_pairing_aligns_text_with_arrow():
    """FIXED pairing: the PREVIOUS segment's text (what the rider is
    currently traversing → `stepBeforeNext.instructions` after the fix) vs
    the arrow geometry at the node. These must agree on EVERY decidable
    plain-turn node — that's the corrected dash."""
    segs = _load_segments()
    nodes = list(_plain_turn_nodes(segs))
    assert nodes, "no decidable plain-turn nodes in fixture"

    mismatches = [
        (k, prev, g) for k, g, prev, _this in nodes if prev != g
    ]
    assert not mismatches, (
        "corrected pairing (previous-segment text vs this node's arrow) "
        f"still disagrees at nodes {[m[0] for m in mismatches]} — the fix "
        f"does not fully align text with the arrow on the field log."
    )

    # And it must be a strict improvement over the buggy pairing.
    fixed_agree = sum(1 for _k, g, prev, _this in nodes if prev == g)
    same_agree = sum(1 for _k, g, _prev, this in nodes if this is not None and this == g)
    assert fixed_agree > same_agree, (
        f"corrected pairing ({fixed_agree}) is not better than the buggy "
        f"same-step pairing ({same_agree})"
    )


# ----------------------------------------------------------------------
# 3. Swift-source drift guards — the fix must stay wired in the app.
# ----------------------------------------------------------------------

def _navigator_src() -> str:
    swift = _repo_root() / "TripperDashPP" / "Navigation" / "ActiveNavigator.swift"
    return swift.read_text(encoding="utf-8")


def _navloop_src() -> str:
    swift = _repo_root() / "TripperDashPP" / "Navigation" / "ActiveNavLoop.swift"
    return swift.read_text(encoding="utf-8")


def _hud_src() -> str:
    swift = _repo_root() / "TripperDashPP" / "UI" / "Navigation" / "NavigationHUD.swift"
    return swift.read_text(encoding="utf-8")


def test_swift_upcoming_instructions_reads_arriving_step():
    """`upcomingInstructions` must come from `stepBeforeNext` (the ARRIVING
    step ending at the node), not `nextStep` (the DEPARTING step). This is
    the heart of the fix."""
    src = _navigator_src()
    idx = src.index("var upcomingInstructions")
    decl = src[idx:idx + 200]
    assert "stepBeforeNext" in decl, (
        "upcomingInstructions no longer reads stepBeforeNext — the "
        "instruction off-by-one is back"
    )
    assert "nextStep" not in decl, (
        "upcomingInstructions reads nextStep again — that is the DEPARTING "
        "step, one maneuver too far ahead"
    )


def test_swift_upcoming_maneuver_classifies_arriving_against_departing():
    """The derived `upcomingManeuver` must classify the ARRIVING step
    (text/family) against the DEPARTING step (`nextStep`, geometry)."""
    src = _navigator_src()
    idx = src.index("var upcomingManeuver")
    body = src[idx:idx + 320]
    assert "arrivingStep:" in body and "stepBeforeNext" in body, (
        "upcomingManeuver no longer feeds the arriving step (stepBeforeNext) "
        "as the text/family source"
    )
    assert "departingStep:" in body and "nextStep" in body, (
        "upcomingManeuver no longer uses nextStep as the departing (geometry) leg"
    )


def test_swift_classify_signature_is_arriving_departing():
    """The classifier signature itself must be the arriving/departing/
    preceding shape, so the old `classify(_:previousStep:)` call that
    sourced text from the wrong step can't compile back in."""
    src = (_repo_root() / "TripperDashPP" / "Navigation" / "Models"
           / "ManeuverIcon.swift").read_text(encoding="utf-8")
    assert "func classify(arrivingStep:" in src, "classify lost the arrivingStep parameter"
    assert "departingStep:" in src, "classify lost the departingStep parameter"
    # The arriving step's instructions drive the family; assert the text is
    # taken from the arriving step, not a departing/next one.
    idx = src.index("func classify(arrivingStep:")
    body = src[idx:idx + 600]
    assert "arrivingStep.instructions" in body, (
        "classify no longer reads the maneuver text from the arriving step"
    )


def test_swift_hud_uses_derived_upcoming_model():
    """The SwiftUI HUD must render the derived `upcomingInstructions` /
    `upcomingManeuver`, not re-derive from `nextStep` (which would drift the
    visible text a maneuver ahead of the icon again)."""
    src = _hud_src()
    assert "nav.upcomingInstructions" in src, "HUD no longer shows upcomingInstructions"
    assert "nav.upcomingManeuver" in src, "HUD no longer shows upcomingManeuver"
    assert "nav.nextStep?.instructions" not in src, (
        "HUD reads nextStep.instructions again — the off-by-one returns in the UI"
    )


def test_swift_secondary_distance_uses_departing_leg():
    """The look-ahead distance must be `distanceToNextStep + step.distance`
    (the DEPARTING leg, primary node → secondary node), NOT
    `secondStep.distance` (the leg AFTER the secondary node), which
    overshot the chevron by a whole step on the field log."""
    src = _navigator_src()
    idx = src.index("// F2c: secondary (look-ahead) maneuver")
    body = src[idx:idx + 1100]
    assert "+ step.distance" in body, (
        "secondary distance no longer adds the departing leg's own length"
    )
    # The CODE (not the comment) must not assign from secondStep.distance.
    # Strip comment lines so the historical "previously added
    # secondStep.distance" note doesn't trip this guard.
    code_only = "\n".join(
        ln for ln in body.splitlines() if not ln.lstrip().startswith("//")
    )
    assert "secondStep.distance" not in code_only, (
        "secondary distance adds secondStep.distance again — the look-ahead "
        "chip overshoots by a whole maneuver"
    )
    # Belt-and-braces: the ingest block no longer binds a `secondStep` local
    # at all (it assigns route.steps[secondIdx] straight into the property).
    assert "let secondStep = route.steps[secondIdx]" not in code_only, (
        "ingest reintroduced a secondStep binding — verify the distance math "
        "still uses the departing leg (step.distance), not secondStep.distance"
    )
