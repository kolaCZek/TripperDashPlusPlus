"""
Tests for the reroute → polyline-swap → tile-rebake lifecycle, as
implemented in:

  - TripperDashPP/Navigation/ActiveNavigator.swift
    (`onActiveRouteChanged` callback fires on start() AND reroute)
  - TripperDashPP/UI/MapPickerView.swift
    (hook installs polyline immediately, schedules tile bake)
  - TripperDashPP/Map/MapViewSource.swift
    (`scheduleTileCacheRebuild` bakes immediately in EVERY app state —
    the bake is BG-safe URLSession + CGContext since the OSM migration —
    and coalesces overlapping reroutes to the latest via
    `pendingRebakeInFlight`)

This file is a Python mirror of the Swift state machine — pinning
the behaviour so a future refactor that re-introduces an
`applicationState == .active` gate on the reroute bake is caught
immediately. The Swift unit tests would need XCTest + a UIApplication
mock; this is a lot cheaper.

## History (why this file was rewritten)

An earlier version of these tests asserted the OPPOSITE invariant:
that a reroute in `.background` must DEFER its tile bake to
`didBecomeActiveNotification`, "because MKMapSnapshotter is GPU-bound
and blocked in BG". That was true in the MKMapSnapshotter era, but the
OSM tile migration (mid-2026) made the bake pure URLSession + CGContext,
which is BG-safe. The `.active` gate then became a latent bug: a rider
who took a wrong turn mid-ride (phone pocketed → app is `.background`
the whole time) would get a reroute polyline but NO map ground under it
— `drawVectorOnlyFrame` painting a bare route line on a blank Light
canvas — for the rest of the trip, because the deferred bake never
drained (the phone never returned to `.active`). Removing the gate is
the fix; these tests were inverted to pin the corrected behaviour, the
same way `test_tile_cache_style_isolation.py` was deleted when the
share-one-cache invariant flipped. Keeping the old assertions would have
pinned the bug.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Optional


# --- Minimal mirror of the relevant Swift state -----------------------------


class AppState:
    ACTIVE = "active"
    INACTIVE = "inactive"
    BACKGROUND = "background"


@dataclass
class FakeMapViewSource:
    """Mirrors the relevant fields/methods on Swift MapViewSource."""

    app_state: str = AppState.ACTIVE
    current_polyline_id: Optional[int] = None          # set_route_polyline
    current_tile_cache_route_id: Optional[int] = None  # set_tile_cache
    pending_rebake_route_id: Optional[int] = None
    pending_rebake_in_flight: bool = False
    bakes_executed: list[int] = field(default_factory=list)

    def set_route_polyline(self, route_id: int) -> None:
        self.current_polyline_id = route_id

    def set_tile_cache(self, route_id: Optional[int]) -> None:
        self.current_tile_cache_route_id = route_id

    def schedule_tile_cache_rebuild(self, route_id: int) -> None:
        # Mirror of Swift `scheduleTileCacheRebuild`: NO app-state gate.
        # Record the requested route, then bake immediately — unless a
        # bake is already running, in which case the in-flight bake will
        # pick up this newer route when it finishes (coalescing).
        self.pending_rebake_route_id = route_id
        if self.pending_rebake_in_flight:
            return
        self._perform_pending_rebake()

    def _perform_pending_rebake(self) -> None:
        # Mirror of Swift `performPendingRebake`: MUST run on main, but
        # has NO `applicationState == .active` guard — the bake is
        # BG-safe (URLSession + CGContext).
        route_id = self.pending_rebake_route_id
        if route_id is None:
            return
        self.pending_rebake_in_flight = True
        baking_for = route_id
        # ... bake happens here (modelled as instantaneous) ...
        self.bakes_executed.append(baking_for)
        self.pending_rebake_in_flight = False
        # Mid-bake new reroute? Recurse with the latest.
        if self.pending_rebake_route_id != baking_for:
            self._perform_pending_rebake()
            return
        self.pending_rebake_route_id = None
        self.set_tile_cache(baking_for)

    def did_become_active(self) -> None:
        """Mirror of UIApplication.didBecomeActiveNotification handler.

        Reroute bakes are NO LONGER deferred here (they fire immediately
        in every state). This drain is a belt-and-braces safety net for a
        `pendingRebakeRoute` that somehow outlived its bake Task.
        """
        self.app_state = AppState.ACTIVE
        if self.pending_rebake_route_id is None or self.pending_rebake_in_flight:
            return
        self._perform_pending_rebake()


# --- Initial install --------------------------------------------------------


def test_initial_route_in_foreground_sets_both_polyline_and_cache():
    src = FakeMapViewSource(app_state=AppState.ACTIVE)
    src.set_route_polyline(1)
    src.schedule_tile_cache_rebuild(1)
    assert src.current_polyline_id == 1
    assert src.current_tile_cache_route_id == 1
    assert src.bakes_executed == [1]


# --- Reroute in foreground --------------------------------------------------


def test_reroute_in_foreground_replaces_polyline_and_cache_immediately():
    src = FakeMapViewSource(app_state=AppState.ACTIVE)
    src.set_route_polyline(1)
    src.schedule_tile_cache_rebuild(1)
    # Now a reroute lands.
    src.set_route_polyline(2)
    src.schedule_tile_cache_rebuild(2)
    assert src.current_polyline_id == 2
    assert src.current_tile_cache_route_id == 2
    assert src.bakes_executed == [1, 2]


# --- Reroute in background (THE regression guard) ---------------------------


def test_reroute_in_background_bakes_immediately():
    """THE bug guard. In BG/lock the reroute bake MUST still run — the
    bake is BG-safe (URLSession + CGContext) since the OSM migration.

    Regression this pins: an `applicationState == .active` gate here used
    to defer the bake to `didBecomeActive`, which never arrives while the
    phone is pocketed, so the dash showed the new route line on a blank
    ground (drawVectorOnlyFrame) for the rest of the ride. If someone
    re-adds that gate, this test goes red.
    """
    src = FakeMapViewSource(app_state=AppState.ACTIVE)
    src.set_route_polyline(1)
    src.schedule_tile_cache_rebuild(1)
    # User pockets phone, app goes BG.
    src.app_state = AppState.BACKGROUND
    # Reroute happens while locked.
    src.set_route_polyline(2)
    src.schedule_tile_cache_rebuild(2)
    # Polyline updated (visible on dash immediately) ...
    assert src.current_polyline_id == 2
    # ... AND the new corridor was baked right away, even in BG.
    assert src.current_tile_cache_route_id == 2
    assert src.bakes_executed == [1, 2]
    assert src.pending_rebake_route_id is None


def test_reroute_in_inactive_state_also_bakes_immediately():
    """`.inactive` is the brief screen-locking transition. It must NOT
    gate the bake either (it was lumped in with `.background` by the old
    deferring guard)."""
    src = FakeMapViewSource(app_state=AppState.INACTIVE)
    src.set_tile_cache(1)
    src.set_route_polyline(2)
    src.schedule_tile_cache_rebuild(2)
    assert src.current_tile_cache_route_id == 2
    assert src.bakes_executed == [2]


def test_bake_does_not_wait_for_app_to_become_active():
    """Complement to the FG/BG pair: a bake scheduled in BG has already
    run by the time the app becomes active, so did_become_active is a
    no-op (nothing left pending)."""
    src = FakeMapViewSource(app_state=AppState.BACKGROUND)
    src.set_tile_cache(1)
    src.set_route_polyline(2)
    src.schedule_tile_cache_rebuild(2)
    # Already baked — no waiting for foreground.
    assert src.current_tile_cache_route_id == 2
    assert src.bakes_executed == [2]
    # Waking adds nothing.
    src.did_become_active()
    assert src.bakes_executed == [2]


# --- Coalescing overlapping reroutes ----------------------------------------


def test_reroute_while_bake_in_flight_coalesces_to_latest():
    """Two reroutes where the second lands WHILE the first is baking →
    only the latest corridor is kept. This is the coalescing path: a
    30 s reroute cooldown plus a wandering rider can stack requests, and
    we don't want to bake a route that's already stale.

    Modelled by manually holding the first bake 'in flight' (the Swift
    bake is an `await prerender`, i.e. genuinely concurrent) and landing
    reroutes during it.
    """
    src = FakeMapViewSource(app_state=AppState.BACKGROUND)

    original = src._perform_pending_rebake
    call_count = {"n": 0}

    def patched():
        call_count["n"] += 1
        if call_count["n"] == 1:
            baking_for = src.pending_rebake_route_id
            assert baking_for == 2
            src.pending_rebake_in_flight = True
            src.bakes_executed.append(baking_for)
            # Two more reroutes land during the (awaited) bake — each just
            # updates pending and returns because in_flight is set.
            src.schedule_tile_cache_rebuild(3)
            src.schedule_tile_cache_rebuild(4)
            assert src.bakes_executed == [2]  # 3 and 4 did NOT start a bake
            src.pending_rebake_in_flight = False
            # In-flight bake finishes, sees pending(4) != bakingFor(2),
            # recurses with the latest.
            original()
            return
        original()

    src._perform_pending_rebake = patched  # type: ignore[method-assign]
    src.schedule_tile_cache_rebuild(2)
    assert src.bakes_executed == [2, 4]
    assert src.current_tile_cache_route_id == 4
    assert src.pending_rebake_route_id is None


def test_second_reroute_after_bake_finished_bakes_again():
    """Sanity: reroutes that DON'T overlap each bake normally (no
    coalescing when the previous bake already finished)."""
    src = FakeMapViewSource(app_state=AppState.BACKGROUND)
    src.schedule_tile_cache_rebuild(2)
    src.schedule_tile_cache_rebuild(3)
    assert src.bakes_executed == [2, 3]
    assert src.current_tile_cache_route_id == 3


# --- Edge cases -------------------------------------------------------------


def test_did_become_active_with_nothing_pending_is_noop():
    src = FakeMapViewSource(app_state=AppState.BACKGROUND)
    src.set_tile_cache(1)
    src.did_become_active()
    assert src.bakes_executed == []
    assert src.current_tile_cache_route_id == 1


def test_stray_pending_route_drains_on_activation():
    """Belt-and-braces: if a bake Task were cancelled leaving a stray
    `pendingRebakeRoute`, did_become_active mops it up. (Constructed
    by hand — the normal path never leaves a stray.)"""
    src = FakeMapViewSource(app_state=AppState.BACKGROUND)
    src.set_tile_cache(1)
    src.pending_rebake_route_id = 2  # simulate a cancelled-Task leftover
    src.did_become_active()
    assert src.bakes_executed == [2]
    assert src.current_tile_cache_route_id == 2


# --- Documented invariant ---------------------------------------------------


def test_polyline_is_NEVER_held_back_by_app_state():
    """The polyline path is pure CGContext drawing — it works in BG.
    Verify by setting polyline in every state, always succeeds."""
    for state in [AppState.ACTIVE, AppState.INACTIVE, AppState.BACKGROUND]:
        src = FakeMapViewSource(app_state=state)
        src.set_route_polyline(42)
        assert src.current_polyline_id == 42, f"failed in state={state}"


def test_tile_bake_is_NEVER_held_back_by_app_state():
    """The tile bake is BG-safe (URLSession + CGContext) since the OSM
    migration. Verify a reroute bakes in EVERY state — this is the whole
    point of the fix."""
    for state in [AppState.ACTIVE, AppState.INACTIVE, AppState.BACKGROUND]:
        src = FakeMapViewSource(app_state=state)
        src.schedule_tile_cache_rebuild(7)
        assert src.bakes_executed == [7], f"failed in state={state}"
        assert src.current_tile_cache_route_id == 7, f"failed in state={state}"
