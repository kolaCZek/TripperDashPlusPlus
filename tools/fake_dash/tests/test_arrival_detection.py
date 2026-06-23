"""
Tests for final-destination arrival detection, as implemented in:

  - TripperDashPP/Navigation/ActiveNavigator.swift
    (`ingest(fix:)` arrival branch + `handleArrival()` + `hasArrived`
    state + `hasBeenUnderway` guard, reset in `stop()`)
  - TripperDashPP/App/AppStatus.swift
    (`onArrived` tears down the stream + route artefacts)
  - TripperDashPP/UI/MapPickerView.swift
    (auto-dismiss 4 s after arrival → finishArrival → stop())

Python mirror of the Swift arrival state machine, pinning the
behaviour so a refactor that, say, drops the underway guard (and
fires arrival at t=0) or fires on an intermediate waypoint is caught
immediately. Mirrors the structure of test_reroute_lifecycle.py.

Decision (rider-confirmed): arrival auto-dismisses; single-destination
AND last-leg-of-plan both count as "final"; intermediate legs advance
instead of arriving.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Optional


# --- Minimal mirror of the relevant Swift state -----------------------------

# Matches the Swift constants in ActiveNavigator.swift.
DESTINATION_ARRIVAL_THRESHOLD = 25.0  # metres
LEG_ARRIVAL_THRESHOLD = 30.0          # metres


@dataclass
class FakePlan:
    """Mirror of the bits of PlannedRoute the arrival branch reads."""

    leg_count: int


@dataclass
class FakeNavigator:
    """Mirrors ActiveNavigator's arrival-relevant fields/methods."""

    is_navigating: bool = True
    has_arrived: bool = False
    has_been_underway: bool = False
    remaining_distance: float = 0.0
    plan: Optional[FakePlan] = None
    current_leg_index: int = 0

    # Side-effect recorders (stand in for the Swift callbacks).
    on_arrived_fired: int = 0
    leg_advances: list[int] = field(default_factory=list)

    def ingest(self, remaining: float) -> None:
        """Mirror of the arrival-relevant slice of ingest(fix:)."""
        if not self.is_navigating:
            return
        self.remaining_distance = remaining

        # Arm the "been under way" guard.
        if remaining > DESTINATION_ARRIVAL_THRESHOLD * 2:
            self.has_been_underway = True

        # Multi-stop leg advance (intermediate legs only).
        if (
            self.plan is not None
            and self.current_leg_index < self.plan.leg_count - 1
            and remaining <= LEG_ARRIVAL_THRESHOLD
        ):
            self.current_leg_index += 1
            self.leg_advances.append(self.current_leg_index)
            return

        # Final-destination arrival.
        is_final_leg = self.plan is None or self.current_leg_index >= (
            (self.plan.leg_count if self.plan else 1) - 1
        )
        if (
            is_final_leg
            and self.has_been_underway
            and not self.has_arrived
            and remaining <= DESTINATION_ARRIVAL_THRESHOLD
        ):
            self._handle_arrival()
            return

    def _handle_arrival(self) -> None:
        # Mirrors Swift handleArrival(): set hasArrived + fire onArrived,
        # but deliberately DO NOT touch is_navigating — MapPickerView's
        # `mode` is derived from it, so flipping it here would unmount the
        # HUD before the "You've arrived" card can render. stop() (called
        # by MapPickerView after the 4 s auto-dismiss) clears it.
        self.has_arrived = True
        self.on_arrived_fired += 1

    def stop(self) -> None:
        self.is_navigating = False
        self.has_arrived = False
        self.has_been_underway = False
        self.plan = None
        self.current_leg_index = 0


# --- Single-destination route -----------------------------------------------


def test_arrival_fires_on_single_destination_within_threshold():
    nav = FakeNavigator()
    nav.ingest(500)   # under way
    nav.ingest(200)
    nav.ingest(20)    # within 25 m → arrive
    assert nav.has_arrived is True
    # is_navigating stays True so the HUD (and its arrival card) stays
    # mounted; stop() — fired by the 4 s auto-dismiss — clears it.
    assert nav.is_navigating is True
    assert nav.on_arrived_fired == 1
    # Auto-dismiss beat:
    nav.stop()
    assert nav.is_navigating is False


def test_arrival_does_not_fire_at_t0_on_short_route():
    """The hasBeenUnderway guard: a route that starts already inside the
    arrival radius must NOT instantly 'arrive' on the first fix."""
    nav = FakeNavigator()
    nav.ingest(15)    # first fix already < 25 m
    assert nav.has_arrived is False
    assert nav.is_navigating is True
    assert nav.on_arrived_fired == 0


def test_arrival_fires_once_underway_then_close_even_on_short_route():
    """Same short route, but once we've moved >50 m away and back, the
    guard is armed and arrival fires."""
    nav = FakeNavigator()
    nav.ingest(60)    # >50 m → arms the guard
    nav.ingest(10)
    assert nav.has_arrived is True
    assert nav.on_arrived_fired == 1


def test_arrival_fires_exactly_once():
    nav = FakeNavigator()
    nav.ingest(500)
    nav.ingest(10)
    nav.ingest(8)
    nav.ingest(5)
    assert nav.on_arrived_fired == 1


def test_no_arrival_while_still_far():
    nav = FakeNavigator()
    nav.ingest(500)
    nav.ingest(100)
    nav.ingest(40)   # still beyond 25 m
    assert nav.has_arrived is False
    assert nav.is_navigating is True


# --- Multi-stop plan --------------------------------------------------------


def test_intermediate_leg_advances_does_not_arrive():
    """3-leg plan: arriving at leg 0's end advances to leg 1, NOT arrival."""
    nav = FakeNavigator(plan=FakePlan(leg_count=3), current_leg_index=0)
    nav.ingest(500)
    nav.ingest(20)   # within leg threshold of waypoint 1
    assert nav.leg_advances == [1]
    assert nav.has_arrived is False
    assert nav.is_navigating is True


def test_final_leg_of_plan_arrives():
    """On the last leg of a plan, the same proximity triggers arrival."""
    nav = FakeNavigator(plan=FakePlan(leg_count=3), current_leg_index=2)
    nav.ingest(500)
    nav.ingest(15)
    assert nav.has_arrived is True
    assert nav.on_arrived_fired == 1
    assert nav.leg_advances == []


def test_walk_full_plan_advances_then_arrives():
    nav = FakeNavigator(plan=FakePlan(leg_count=2), current_leg_index=0)
    # Leg 0 → waypoint 1.
    nav.ingest(500)
    nav.ingest(20)
    assert nav.current_leg_index == 1
    assert nav.has_arrived is False
    # Leg 1 is the final leg → arrival.
    nav.ingest(500)
    nav.ingest(15)
    assert nav.has_arrived is True
    assert nav.on_arrived_fired == 1


# --- Reset ------------------------------------------------------------------


def test_stop_resets_arrival_state():
    nav = FakeNavigator()
    nav.ingest(500)
    nav.ingest(10)
    assert nav.has_arrived is True
    nav.stop()
    assert nav.has_arrived is False
    assert nav.has_been_underway is False
    assert nav.is_navigating is False


def test_next_route_after_arrival_starts_clean():
    """After arriving + stop(), a fresh route must be able to arrive again
    (i.e. the once-only latch was cleared)."""
    nav = FakeNavigator()
    nav.ingest(500)
    nav.ingest(10)
    nav.stop()
    # New route.
    nav.is_navigating = True
    nav.ingest(500)
    nav.ingest(10)
    assert nav.has_arrived is True
    assert nav.on_arrived_fired == 2
