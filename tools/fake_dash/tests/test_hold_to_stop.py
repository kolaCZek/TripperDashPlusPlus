"""
Ride-ending phone buttons need a 2 s hold; planner Cancel asks before
discarding an unsaved multi-stop plan.

  - With gloves, or with the phone on a handlebar mount, one stray tap on
    "Stop navigation" / "Stop free ride" ended the ride and the dash
    projection. There's no undo: getting back means re-planning, a new
    MKDirections call and a new prerender. Both buttons now go through
    `HoldToConfirmButton` (minimum duration 2 s). The dash exit button and
    programmatic stops (arrival, disconnect) still stop immediately.
  - Planner Cancel threw away a multi-stop plan on one tap. It now shows
    "Discard this plan?" when `planHasUnsavedWork` (more than 2 stops that
    differ from the last save), and otherwise cancels as before.
  The predicate itself is covered by `SavedRouteFromPlanTests.swift`.
"""

from __future__ import annotations

import re
from pathlib import Path

from .swift_source import decl_body, strip_comments

REPO = Path(__file__).resolve().parents[3]
PICKER = REPO / "TripperDashPP" / "UI" / "MapPickerView.swift"


def _src() -> str:
    return strip_comments(PICKER.read_text(encoding="utf-8"))


def test_ride_stop_buttons_use_the_hold_component():
    ctrl = decl_body(_src(), "private var controlButton")
    nav = ctrl[ctrl.index("case (.navigating, _):"):ctrl.index("case (.freeRiding, _):")]
    free = ctrl[ctrl.index("case (.freeRiding, _):"):]
    free = free[:free.index("case (", 1)]
    assert 'HoldToConfirmButton(title: "Hold to stop navigation"' in nav
    assert "{ stopNavigation() }" in nav
    assert 'HoldToConfirmButton(title: "Hold to stop free ride"' in free
    assert "{ status.stopFreeRide() }" in free


def test_no_plain_button_stops_a_ride():
    src = _src()
    # Any `Button` whose action closure calls a ride stop is a one-tap stop.
    one_tap = re.findall(r"(?<!\w)Button\b[^{}]*\{\s*(?:status\.)?(?:stopNavigation|stopFreeRide)\(\)", src)
    assert not one_tap, one_tap
    # And the only UI call sites are the two hold buttons (the dash exit
    # hook's `self.stopNavigation()` is not a button and stays immediate).
    assert src.count("status.stopFreeRide()") == 1
    assert len(re.findall(r"(?<![.\w])(?<!func )stopNavigation\(\)", src)) == 1


def test_hold_component_needs_two_seconds_and_fires_once():
    body = decl_body(_src(), "private struct HoldToConfirmButton")
    assert "static let holdDuration: Double = 2" in body
    assert ".onLongPressGesture(minimumDuration: Self.holdDuration" in body
    assert "onPressingChanged:" in body
    assert ".linear(duration: Self.holdDuration)" in body
    # VoiceOver can still stop the ride with a double-tap.
    assert ".accessibilityAddTraits(.isButton)" in body
    assert ".accessibilityAction { action() }" in body
    # No hand-rolled timer loop.
    assert "Timer" not in body and "Task.sleep" not in body


def test_planner_cancel_checks_for_unsaved_work():
    src = _src()
    plan = decl_body(src, "private func planningBody")
    cancel = plan[plan.index('Button("Cancel")'):]
    cancel = cancel[:cancel.index("ToolbarItem")]
    assert "Self.planHasUnsavedWork(stops: Self.stopsSnapshot(plan), saved: savedPlanStops)" in cancel
    assert "showDiscardPlanDialog = true" in cancel
    assert cancel.index("planHasUnsavedWork") < cancel.index("status.cancelPlanning()")
    dialog = plan[plan.index('.confirmationDialog("Discard this plan?"'):plan.index(".toolbar")]
    assert "isPresented: $showDiscardPlanDialog" in dialog
    assert 'Button("Discard", role: .destructive) { status.cancelPlanning() }' in dialog
    assert 'Button("Keep editing", role: .cancel)' in dialog
    pred = decl_body(src, "static func planHasUnsavedWork")
    assert "stops.count > 2 && stops != saved" in pred
    assert "showDiscardPlanDialog" in decl_body(src, "private var anotherModalUp")
