"""
Regression for the "reroute has no blue line" field bug (8/2026): the
rider took a wrong turn, the route recalculated, but NO blue line was
drawn along the road they were told to ride.

## Mechanism

Two things paint the route on the dash:

  1. `MapViewSource.setRoutePolyline(newRoute.polyline)` — the ACTIVE
     leg's line, pushed straight from the reroute result.
  2. `installFullRouteContext(plan:)` — rebuilds the WHOLE-TRIP line by
     concatenating every leg's *selected* option from the `PlannedRoute`.

The renderer draws `routeDrawCoords = fullRouteCoords.isEmpty ?
routePolylineCoords : fullRouteCoords` — i.e. the whole-trip line WINS
whenever it is non-empty.

The off-route reroute path (`ActiveNavigator.installSwappedRoute`) used
to swap `activeRoute` + call `setRoutePolyline` but NEVER update the
plan. The route-changed hook then called `installFullRouteContext(plan:)`,
which rebuilt `fullRouteCoords` from the STALE plan leg — the road the
rider had already left. That stale whole-trip line is non-empty, so it
won over the fresh reroute polyline: the dash drew the OLD road (nowhere
near the rider) and, because the rider was off it, it looked like "no
line at all".

## Fix

`installSwappedRoute` now calls `plan.replaceLegRoute(legIndex:with:)`
BEFORE firing the hook, so the whole-trip line is rebuilt from the NEW
road. This file mirrors the draw-selection + plan-sync logic and pins
both the bug and the fix, plus a Swift-source drift guard.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Optional
from pathlib import Path


# --- Minimal mirror of the plan + draw-selection logic ----------------------


@dataclass
class FakeLeg:
    """One leg = its selected option's coordinate list (modelled as ints)."""
    coords: list[int]


@dataclass
class FakePlan:
    legs: list[FakeLeg]
    current_leg: int = 0

    def replace_leg_route(self, leg_index: int, coords: list[int]) -> None:
        """Mirror of `PlannedRoute.replaceLegRoute` — swap the current
        leg's geometry to the freshly-rerouted road."""
        if 0 <= leg_index < len(self.legs):
            self.legs[leg_index] = FakeLeg(coords=list(coords))

    def full_route_coords(self) -> list[int]:
        """Mirror of `installFullRouteContext`: concatenate every leg's
        selected coords (dedup of shared join points omitted — irrelevant
        to this invariant)."""
        out: list[int] = []
        for leg in self.legs:
            out.extend(leg.coords)
        return out


@dataclass
class FakeRenderer:
    route_polyline_coords: list[int] = field(default_factory=list)
    full_route_coords: list[int] = field(default_factory=list)

    def set_route_polyline(self, coords: list[int]) -> None:
        self.route_polyline_coords = list(coords)

    def set_full_route(self, coords: list[int]) -> None:
        self.full_route_coords = list(coords)

    @property
    def route_draw_coords(self) -> list[int]:
        """Mirror of the renderer's `routeDrawCoords` selection: the
        whole-trip line wins whenever it's non-empty."""
        return self.full_route_coords if self.full_route_coords else self.route_polyline_coords


def install_swapped_route(plan: Optional[FakePlan],
                          renderer: FakeRenderer,
                          new_coords: list[int],
                          *,
                          sync_plan: bool) -> None:
    """Mirror of `ActiveNavigator.installSwappedRoute` + the route-changed
    hook. `sync_plan=False` reproduces the OLD (buggy) behaviour; True is
    the fix."""
    # (1) active-leg polyline pushed straight from the reroute result.
    renderer.set_route_polyline(new_coords)
    # (fix) sync the plan's current leg BEFORE rebuilding the whole-trip line.
    if sync_plan and plan is not None and 0 <= plan.current_leg < len(plan.legs):
        plan.replace_leg_route(plan.current_leg, new_coords)
    # (2) route-changed hook rebuilds the whole-trip line from the plan.
    if plan is not None:
        renderer.set_full_route(plan.full_route_coords())


# --- The bug + the fix ------------------------------------------------------


OLD_ROAD = [10, 11, 12, 13]      # pre-reroute leg (rider already left it)
NEW_ROAD = [20, 21, 22, 23]      # reroute result (the road to actually ride)


def test_without_plan_sync_stale_full_route_hides_the_reroute():
    """OLD behaviour: the whole-trip line stays on the old road, wins over
    the fresh reroute polyline, so the dash draws the road the rider left."""
    plan = FakePlan(legs=[FakeLeg(coords=OLD_ROAD)], current_leg=0)
    r = FakeRenderer()
    install_swapped_route(plan, r, NEW_ROAD, sync_plan=False)
    # The active polyline IS the new road ...
    assert r.route_polyline_coords == NEW_ROAD
    # ... but the whole-trip line is still the OLD road and wins the draw.
    assert r.route_draw_coords == OLD_ROAD  # <-- the bug: wrong road drawn


def test_plan_sync_makes_the_reroute_the_drawn_route():
    """FIX: syncing the plan leg rebuilds the whole-trip line on the NEW
    road, so that's what gets drawn."""
    plan = FakePlan(legs=[FakeLeg(coords=OLD_ROAD)], current_leg=0)
    r = FakeRenderer()
    install_swapped_route(plan, r, NEW_ROAD, sync_plan=True)
    assert r.route_polyline_coords == NEW_ROAD
    assert r.route_draw_coords == NEW_ROAD  # correct road drawn


def test_plan_sync_only_touches_the_current_leg():
    """A multi-stop plan: reroute on leg 1 must leave legs 0 and 2 intact
    and only swap the middle leg, so the whole-trip line = prefix + new +
    suffix."""
    plan = FakePlan(
        legs=[FakeLeg([1, 2]), FakeLeg(OLD_ROAD), FakeLeg([30, 31])],
        current_leg=1,
    )
    r = FakeRenderer()
    install_swapped_route(plan, r, NEW_ROAD, sync_plan=True)
    assert plan.legs[0].coords == [1, 2]
    assert plan.legs[1].coords == NEW_ROAD
    assert plan.legs[2].coords == [30, 31]
    assert r.route_draw_coords == [1, 2] + NEW_ROAD + [30, 31]


def test_single_destination_no_plan_uses_polyline():
    """Single-destination nav (plan is None) has no whole-trip line, so the
    reroute polyline is drawn directly — nothing to sync."""
    r = FakeRenderer()
    install_swapped_route(None, r, NEW_ROAD, sync_plan=True)
    assert r.route_draw_coords == NEW_ROAD


# --- Swift-source drift guards ----------------------------------------------


def _repo_root() -> Path:
    return Path(__file__).resolve().parents[3]


def test_swift_install_swapped_route_syncs_the_plan():
    """`installSwappedRoute` must call `replaceLegRoute` before firing the
    route-changed hook, or the stale-full-route bug returns."""
    nav = _repo_root() / "TripperDashPP" / "Navigation" / "ActiveNavigator.swift"
    src = nav.read_text(encoding="utf-8")
    idx = src.index("private func installSwappedRoute")
    body = src[idx:idx + 2200]
    assert "replaceLegRoute" in body, (
        "installSwappedRoute no longer syncs the plan leg — the whole-trip "
        "line will be rebuilt from the stale pre-reroute road and hide the "
        "reroute (no blue line along the road the rider is on)"
    )
    # The sync must precede the hook fire.
    assert body.index("replaceLegRoute") < body.index("onActiveRouteChanged"), (
        "plan sync must run BEFORE onActiveRouteChanged — the hook reads the "
        "plan to rebuild the whole-trip line"
    )


def test_swift_planned_route_has_replace_leg_route():
    pr = _repo_root() / "TripperDashPP" / "Navigation" / "Models" / "PlannedRoute.swift"
    src = pr.read_text(encoding="utf-8")
    assert "func replaceLegRoute" in src, (
        "PlannedRoute.replaceLegRoute removed — installSwappedRoute relies "
        "on it to sync the rerouted leg into the plan"
    )
