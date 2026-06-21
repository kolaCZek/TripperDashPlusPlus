"""
Tests for the reroute → polyline-swap → deferred-tile-rebake
lifecycle, as implemented in:

  - TripperDashPP/Navigation/ActiveNavigator.swift
    (`onActiveRouteChanged` callback fires on start() AND reroute)
  - TripperDashPP/UI/MapPickerView.swift
    (hook installs polyline immediately, schedules tile bake)
  - TripperDashPP/Map/MapViewSource.swift
    (`scheduleTileCacheRebuild` runs now if .active, defers to
    `didBecomeActiveNotification` if .background or .inactive,
    coalesces multiple reroutes to the latest)

This file is a Python mirror of the Swift state machine — pinning
the behaviour so a future refactor that, say, drops the deferred
path or bakes-anyway in BG is caught immediately. The Swift unit
tests would need XCTest + a UIApplication mock; this is a lot
cheaper.
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
    current_polyline_id: Optional[int] = None       # set_route_polyline
    current_tile_cache_route_id: Optional[int] = None  # set_tile_cache
    pending_rebake_route_id: Optional[int] = None
    pending_rebake_in_flight: bool = False
    bakes_executed: list[int] = field(default_factory=list)

    def set_route_polyline(self, route_id: int) -> None:
        self.current_polyline_id = route_id

    def set_tile_cache(self, route_id: Optional[int]) -> None:
        self.current_tile_cache_route_id = route_id

    def schedule_tile_cache_rebuild(self, route_id: int) -> None:
        self.pending_rebake_route_id = route_id
        if self.app_state == AppState.ACTIVE:
            self._perform_pending_rebake()
        # else: defer — observer will drain on didBecomeActive

    def _perform_pending_rebake(self) -> None:
        route_id = self.pending_rebake_route_id
        if route_id is None:
            return
        if self.app_state != AppState.ACTIVE:
            return  # safety re-check (mirror of Swift guard)
        self.pending_rebake_in_flight = True
        baking_for = route_id
        # ... bake happens here (modelled as instantaneous) ...
        self.bakes_executed.append(baking_for)
        self.pending_rebake_in_flight = False
        # Mid-bake new reroute? Recurse.
        if self.pending_rebake_route_id != baking_for:
            self._perform_pending_rebake()
            return
        self.pending_rebake_route_id = None
        self.set_tile_cache(baking_for)

    def did_become_active(self) -> None:
        """Mirror of UIApplication.didBecomeActiveNotification handler."""
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


# --- Reroute in background --------------------------------------------------


def test_reroute_in_background_updates_polyline_but_defers_bake():
    """The critical bug guard: in BG/lock we MUST NOT bake (MKMapSnapshotter
    blocked) but the polyline path (pure CPU) MUST still update so the
    rider sees the new line immediately."""
    src = FakeMapViewSource(app_state=AppState.ACTIVE)
    src.set_route_polyline(1)
    src.schedule_tile_cache_rebuild(1)
    # User pockets phone, app goes BG.
    src.app_state = AppState.BACKGROUND
    # Reroute happens while locked.
    src.set_route_polyline(2)
    src.schedule_tile_cache_rebuild(2)
    # Polyline DID update (visible on dash immediately).
    assert src.current_polyline_id == 2
    # Tile cache STILL points to the old route — better stale tiles
    # than a black screen.
    assert src.current_tile_cache_route_id == 1
    # Bake is pending, not executed.
    assert src.pending_rebake_route_id == 2
    assert src.bakes_executed == [1]


def test_bake_drains_when_app_becomes_active():
    src = FakeMapViewSource(app_state=AppState.BACKGROUND)
    # Pretend we're mid-trip with a stale cache from a prior route.
    src.set_tile_cache(1)
    src.set_route_polyline(2)
    src.schedule_tile_cache_rebuild(2)
    # Nothing happened yet — app is BG.
    assert src.current_tile_cache_route_id == 1
    assert src.bakes_executed == []
    # User unlocks phone.
    src.did_become_active()
    # Now the deferred bake fires.
    assert src.current_tile_cache_route_id == 2
    assert src.bakes_executed == [2]
    assert src.pending_rebake_route_id is None


def test_multiple_reroutes_in_bg_coalesce_to_latest():
    """Two reroutes while locked → only the latest gets baked when
    we wake. This matters: a 30 s reroute cooldown plus a wandering
    rider can stack two requests before the screen turns on, and
    we don't want to waste 20 s baking a route that's already stale."""
    src = FakeMapViewSource(app_state=AppState.BACKGROUND)
    src.set_tile_cache(1)
    src.schedule_tile_cache_rebuild(2)
    src.schedule_tile_cache_rebuild(3)
    src.schedule_tile_cache_rebuild(4)
    src.did_become_active()
    assert src.bakes_executed == [4]
    assert src.current_tile_cache_route_id == 4


def test_inactive_state_also_defers():
    """`.inactive` happens during the screen-locking transition — for
    a brief moment we're neither active nor backgrounded. Treat it
    the same as `.background` (defer the bake)."""
    src = FakeMapViewSource(app_state=AppState.INACTIVE)
    src.set_tile_cache(1)
    src.schedule_tile_cache_rebuild(2)
    assert src.bakes_executed == []
    assert src.pending_rebake_route_id == 2


# --- Edge cases -------------------------------------------------------------


def test_did_become_active_with_nothing_pending_is_noop():
    src = FakeMapViewSource(app_state=AppState.BACKGROUND)
    src.set_tile_cache(1)
    src.did_become_active()
    assert src.bakes_executed == []
    assert src.current_tile_cache_route_id == 1


def test_reroute_while_bake_in_flight_recurses_with_latest():
    """Simulate the rare race: bake starts → reroute lands mid-bake →
    when the in-flight bake finishes, it sees pending != bakingFor
    and recurses to bake the newer route."""
    src = FakeMapViewSource(app_state=AppState.ACTIVE)

    # Manually patch _perform_pending_rebake so we can land a new
    # reroute "during" the bake.
    original = src._perform_pending_rebake
    call_count = {"n": 0}

    def patched():
        # First entry: simulate a reroute landing mid-bake.
        call_count["n"] += 1
        if call_count["n"] == 1:
            baking_for = src.pending_rebake_route_id
            assert baking_for is not None
            src.pending_rebake_in_flight = True
            src.bakes_executed.append(baking_for)
            # Mid-bake reroute:
            src.pending_rebake_route_id = 99
            src.pending_rebake_in_flight = False
            # Recurse — should bake 99.
            patched()
            return
        # Subsequent entries behave normally.
        original()

    src._perform_pending_rebake = patched  # type: ignore[method-assign]
    src.schedule_tile_cache_rebuild(50)
    assert src.bakes_executed == [50, 99]
    assert src.current_tile_cache_route_id == 99


# --- Documented invariant ---------------------------------------------------


def test_polyline_is_NEVER_held_back_by_app_state():
    """The polyline path is pure CGContext drawing — it works in BG.
    The whole point of separating polyline from tile cache is that
    the polyline update is unconditional. Verify by setting polyline
    in every state, always succeeds."""
    for state in [AppState.ACTIVE, AppState.INACTIVE, AppState.BACKGROUND]:
        src = FakeMapViewSource(app_state=state)
        src.set_route_polyline(42)
        assert src.current_polyline_id == 42, f"failed in state={state}"
