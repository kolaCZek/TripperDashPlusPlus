"""
Tests for the maneuver state when NO step lies ahead in the current leg —
the "leg tail" — in `ActiveNavigator.ingest(fix:)`.

Field report (Ari, 9/2026, RE Guerrilla 450, `2Flags.gpx`):

    "The upcoming turn info not working well. It is better than before
     though. It takes quite a long way after the turn to update how far
     next turn is. It does not show which direction you need to turn when
     you get to the turn."

The dash photo shows a straight-ahead arrow reading `0 ft` while the rider
is sitting at a junction — a maneuver bubble that has stopped updating.

ROOT CAUSE — a missing `else`.

`ingest(fix:)` refreshes the whole maneuver model inside:

    if let stepIdx = PolylineMath.nextStepIndex(in: route,
                                                afterPolylineIndex: segIdx),
       stepIdx < route.steps.count {
        ... nextStep / stepBeforeNext / distanceToNextStep / look-ahead ...
    }

`nextStepIndex` returns nil once the rider passes the LAST step start in
the leg — there is no step whose start lies beyond `segIdx`. With no
`else` branch, every field above simply kept its previous value: the
distance froze mid-count-down and the glyph froze with it, until the leg
boundary reseeded them via `seed()`.

WHY IT DOMINATES ON A GPX TRACK. An imported `<trk>` is reduced by
Douglas-Peucker to <= `RoutePoint.navigableCap` (40) waypoints, and each
waypoint is a LEG boundary. A leg is therefore often a single hop with no
intermediate junction, so MapKit returns just [depart, arrive] — and the
arrive step has an EMPTY polyline, which `nextStepIndex` skips by design.
`nextStepIndex` then returns nil for the WHOLE leg: the maneuver bubble is
frozen for 100% of it. Measured on Ari's own file (752 trkpt, 52.6 km, 39
legs) that is the entire ride.

It also explains why the PR #120 boundary fix ("better than before" but
not fixed) could almost never fire: `upcomingManeuver` only borrows
`nextLegFirstStep` when `nextStep == nil`, and the freeze kept a STALE
`nextStep` non-nil. The borrow was unreachable exactly when it was needed.

THE FIX adds the `else`: arriving = the last step with real geometry (its
polyline ends at the leg's end node), departing = nil (so the #120 borrow
becomes reachable), distance = `remaining` (live distance along the
polyline to the leg end, so it counts down), look-ahead cleared.

This file mirrors the leg-tail rule in Python, drives it over Ari's real
GPX geometry, and pins a Swift-source drift guard so the missing-`else`
regression cannot silently return.
"""

from __future__ import annotations

import math
from pathlib import Path
from typing import Optional, Sequence

from tests.swift_source import decl_body, strip_comments
from tests.test_next_step_index import haversine, next_step_index


REPO = Path(__file__).resolve().parents[3]
NAV = REPO / "TripperDashPP" / "Navigation" / "ActiveNavigator.swift"


# --------------------------------------------------------------------------
# Python mirror of the maneuver-model update, INCLUDING the new else branch.
# --------------------------------------------------------------------------

class ManeuverModel:
    """Mirror of the four maneuver fields `ingest(fix:)` maintains."""

    def __init__(self) -> None:
        self.next_step: Optional[int] = None        # index, None == nil
        self.step_before_next: Optional[int] = None
        self.distance_to_next: Optional[float] = None
        self.second_next_step: Optional[int] = None

    def update(self,
               route_points: Sequence[tuple[float, float]],
               step_starts: Sequence[Optional[tuple[float, float]]],
               seg_idx: int,
               coord: tuple[float, float],
               remaining: float,
               step_distances: Sequence[float]) -> None:
        """Mirror of the `if let stepIdx = ... { } else { }` in ingest()."""
        step_idx = next_step_index(route_points, step_starts, seg_idx)
        if step_idx is not None and step_idx < len(step_starts):
            self.next_step = step_idx
            self.step_before_next = step_idx - 1 if step_idx > 0 else None
            start = step_starts[step_idx]
            self.distance_to_next = haversine(coord, start) if start else 0.0
            second = step_idx + 1
            self.second_next_step = second if second < len(step_starts) else None
        else:
            # THE FIX — leg tail.
            self.next_step = None
            geometric = [i for i, s in enumerate(step_starts) if s is not None]
            self.step_before_next = geometric[-1] if geometric else None
            self.distance_to_next = remaining
            self.second_next_step = None


def path_length(coords: Sequence[tuple[float, float]]) -> float:
    return sum(haversine(coords[i], coords[i + 1]) for i in range(len(coords) - 1))


# --------------------------------------------------------------------------
# Ari's real geometry: a single-hop leg (the dominant GPX-track shape).
# --------------------------------------------------------------------------

# A real leg from 2Flags.gpx (Kurviger export, <trk>), taken between two
# consecutive Douglas-Peucker waypoints. Straight-ish hop, no intermediate
# junction -> MapKit returns [depart, arrive] and arrive has no polyline.
ARI_LEG = [
    (52.67126, -0.8186), (52.67149, -0.8185), (52.67151, -0.81779),
    (52.67149, -0.81751), (52.67144, -0.81733), (52.67099, -0.81625),
    (52.67076, -0.81578), (52.67056, -0.81529), (52.67041, -0.81483),
    (52.67027, -0.81423), (52.67019, -0.81365), (52.67016, -0.81314),
]


class TestLegTailNotFrozen:
    """The bubble must keep counting down after the last in-leg maneuver."""

    def test_single_hop_leg_never_freezes_the_distance(self) -> None:
        """Ari's case: no mid-leg step at all -> every fix must still update.

        Before the fix `next_step_index` returned None from vertex 0 and the
        model was never written, so the distance kept whatever stale value
        the previous leg left behind.
        """
        # [depart @ leg start, arrive @ EMPTY polyline] — the arrive step is
        # modelled as None, exactly as the Swift `pointCount > 0` guard skips.
        step_starts: list[Optional[tuple[float, float]]] = [ARI_LEG[0], None]
        step_distances = [path_length(ARI_LEG), 0.0]

        model = ManeuverModel()
        model.distance_to_next = 999.0      # stale value from the previous leg

        seen: list[float] = []
        for v in range(len(ARI_LEG)):
            remaining = path_length(ARI_LEG[v:])
            model.update(ARI_LEG, step_starts, v, ARI_LEG[v],
                         remaining, step_distances)
            seen.append(model.distance_to_next)

        # The stale 999 must be gone on the very first fix.
        assert 999.0 not in seen, "stale distance survived into the leg tail"

        # And it must be monotonically decreasing — a live count-down.
        for a, b in zip(seen, seen[1:]):
            assert b < a, f"distance did not decrease: {a} -> {b}"

        # Ends effectively at the leg boundary.
        assert seen[-1] < 1.0

    def test_leg_tail_clears_next_step_so_the_pr120_borrow_can_fire(self) -> None:
        """`upcomingManeuver` borrows `nextLegFirstStep` only when
        `nextStep == nil`. The freeze kept it non-nil, making the PR #120
        boundary fix unreachable — which is why Ari still saw no direction.
        """
        step_starts: list[Optional[tuple[float, float]]] = [ARI_LEG[0], None]
        step_distances = [path_length(ARI_LEG), 0.0]

        model = ManeuverModel()
        model.next_step = 7        # stale non-nil from the previous leg

        model.update(ARI_LEG, step_starts, len(ARI_LEG) - 1, ARI_LEG[-1],
                     0.0, step_distances)

        assert model.next_step is None, (
            "nextStep must be nil in the leg tail, otherwise upcomingManeuver "
            "never borrows nextLegFirstStep and the turn stays unannounced"
        )

    def test_leg_tail_arriving_step_is_the_last_one_with_geometry(self) -> None:
        """The arriving step carries the maneuver TEXT. MapKit's terminal
        'arrive' step has an empty polyline, so it must not be picked."""
        step_starts: list[Optional[tuple[float, float]]] = [
            ARI_LEG[0], ARI_LEG[5], None,
        ]
        step_distances = [200.0, 200.0, 0.0]

        model = ManeuverModel()
        model.update(ARI_LEG, step_starts, len(ARI_LEG) - 1, ARI_LEG[-1],
                     0.0, step_distances)

        assert model.step_before_next == 1, (
            "arriving step must be the last step WITH geometry (index 1), "
            "not the empty terminal arrive step (index 2)"
        )

    def test_leg_tail_clears_the_lookahead(self) -> None:
        """A stale secondary chip is worse than none."""
        step_starts: list[Optional[tuple[float, float]]] = [ARI_LEG[0], None]
        model = ManeuverModel()
        model.second_next_step = 4        # stale
        model.update(ARI_LEG, step_starts, len(ARI_LEG) - 1, ARI_LEG[-1],
                     0.0, [100.0, 0.0])
        assert model.second_next_step is None

    def test_midleg_behaviour_is_unchanged(self) -> None:
        """Regression guard: while a step IS ahead, nothing changes.

        'Ale bacha, at tim nerozbijes uz fungujici navigaci' — the normal
        point-to-point path must be byte-for-byte the old behaviour.
        """
        step_starts: list[Optional[tuple[float, float]]] = [
            ARI_LEG[0], ARI_LEG[8], None,
        ]
        model = ManeuverModel()
        model.update(ARI_LEG, step_starts, 2, ARI_LEG[2], 500.0, [300.0, 200.0, 0.0])

        # Step 1 starts beyond segment 2 -> normal branch, distance is the
        # straight line to that node, NOT `remaining`.
        assert model.next_step == 1
        assert model.step_before_next == 0
        assert model.distance_to_next is not None
        assert abs(model.distance_to_next - haversine(ARI_LEG[2], ARI_LEG[8])) < 1e-6
        assert model.distance_to_next != 500.0


class TestLegTailSwiftSourceGuard:
    """Pin the fix in Swift so the missing-`else` cannot come back."""

    def _ingest_body(self) -> str:
        src = NAV.read_text(encoding="utf-8")
        return strip_comments(decl_body(src, "func ingest"))

    def test_next_step_index_lookup_has_an_else_branch(self) -> None:
        body = self._ingest_body()
        assert "PolylineMath.nextStepIndex" in body, "maneuver lookup moved"
        # Scope to the region BETWEEN the maneuver lookup and the start of
        # the off-route/reroute logic — otherwise the `} else {` of the
        # off-route branch further down satisfies the assert on its own.
        after = body.split("PolylineMath.nextStepIndex", 1)[1]
        assert "let nowOff = distFromRoute" in after, (
            "off-route marker moved — this guard's scope is no longer valid"
        )
        region = after.split("let nowOff = distFromRoute", 1)[0]
        # Match on INDENTATION, not just the token: the region still holds
        # the nested `secondIdx` if/else at 12 spaces, which passed even
        # with the fix reverted (caught by mutation testing). The leg-tail
        # else is the one at the outer 8-space level.
        assert "\n        } else {" in region, (
            "the nextStepIndex lookup lost its outer else branch — the leg "
            "tail freezes the maneuver bubble again (Ari, 9/2026)"
        )

    def test_leg_tail_assigns_all_four_maneuver_fields(self) -> None:
        body = self._ingest_body()
        tail = body.split("PolylineMath.nextStepIndex", 1)[1].split("} else {", 1)[1]
        for field in ("self.nextStep = nil",
                      "self.stepBeforeNext",
                      "self.distanceToNextStep = remaining",
                      "self.secondNextStep = nil"):
            assert field in tail, f"leg-tail branch no longer sets {field!r}"

    def test_leg_tail_distance_is_live_not_a_stale_step_distance(self) -> None:
        """`remaining` is recomputed per fix; a step distance is not."""
        body = self._ingest_body()
        tail = body.split("PolylineMath.nextStepIndex", 1)[1].split("} else {", 1)[1]
        assert "self.distanceToNextStep = remaining" in tail
        assert "self.distanceToNextStep = step.distance" not in tail

    def test_leg_tail_skips_empty_polyline_steps_when_picking_arriving(self) -> None:
        """MapKit's terminal arrive step has no polyline and carries no
        usable geometry — the arriving step must filter on pointCount."""
        body = self._ingest_body()
        tail = body.split("PolylineMath.nextStepIndex", 1)[1].split("} else {", 1)[1]
        assert "polyline.pointCount > 0" in tail, (
            "leg-tail arriving step must skip empty-polyline steps"
        )
