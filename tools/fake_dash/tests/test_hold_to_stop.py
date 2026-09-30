"""
Ride-ending phone buttons need a 1 s hold; planner Cancel asks before
discarding an unsaved multi-stop plan.

  - With gloves, or with the phone on a handlebar mount, one stray tap on
    "Stop navigation" / "Stop free ride" ended the ride and the dash
    projection. There's no undo: getting back means re-planning, a new
    MKDirections call and a new prerender. Both buttons now go through
    `HoldToConfirmButton` (minimum duration 1 s). The dash exit button and
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
UI = REPO / "TripperDashPP" / "UI"
PICKER = UI / "MapPickerView.swift"


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
    # Any `Button` whose action closure calls a ride stop is a one-tap stop.
    # `stopFreeRide` is public on AppStatus, so check every UI file.
    one_tap_re = re.compile(
        r"(?<!\w)Button\b[^{}]*\{\s*(?:status\.)?(?:stopNavigation|stopFreeRide)\(\)")
    free_ride_calls = 0
    for f in sorted(UI.rglob("*.swift")):
        src = strip_comments(f.read_text(encoding="utf-8"))
        assert not one_tap_re.findall(src), f.name
        free_ride_calls += src.count("stopFreeRide()")
    # The only UI call site is the hold button.
    assert free_ride_calls == 1
    # `stopNavigation` is private to the picker: its only button is the hold
    # one (the dash exit hook's `self.stopNavigation()` stays immediate).
    src = _src()
    assert len(re.findall(r"\{\s*stopNavigation\(\)\s*\}", src)) == 1


def test_hold_component_needs_one_second_and_fires_once():
    body = decl_body(_src(), "private struct HoldToConfirmButton")
    assert re.search(r"static let holdDuration(?::\s*\w+)?\s*=\s*1(?:\.0)?\b", body)
    assert ".onLongPressGesture(minimumDuration: Self.holdDuration" in body
    assert "onPressingChanged:" in body
    assert ".linear(duration: Self.holdDuration)" in body
    # VoiceOver can still stop the ride with a double-tap.
    assert ".accessibilityAddTraits(.isButton)" in body
    assert ".accessibilityAction { action() }" in body
    # VoiceOver acts on a double-tap, so its label must not say "Hold to".
    assert ".accessibilityLabel(spokenTitle)" in body
    for spoken in ('spokenTitle: "Stop navigation"', 'spokenTitle: "Stop free ride"'):
        assert spoken in _src()
    # No hand-rolled timer loop.
    assert "Timer" not in body and "Task.sleep" not in body


def test_planner_cancel_checks_for_unsaved_work():
    src = _src()
    plan = decl_body(src, "private func planningBody")
    cancel = plan[plan.index('Button("Cancel")'):]
    cancel = cancel[:cancel.index("ToolbarItem")]
    assert "Self.planHasUnsavedWork(stops: Self.stopsSnapshot(plan), saved: baseline)" in cancel
    # A library plan is compared with its stops as loaded (edits for this
    # ride can still be lost); a planner plan with its last save.
    assert "plan.isFromLibrary ? libraryBaselineStops : savedPlanStops" in cancel
    body = strip_comments(decl_body(src, "var body: some View"))
    staged = body[body.index(".onChange(of: status.plannedRoute.map(ObjectIdentifier.init), initial: true)"):]
    staged = staged[:staged.index(".onChange(", 1)]
    assert "plan.isFromLibrary" in staged
    assert "libraryBaselineStops = Self.stopsSnapshot(plan)" in staged
    assert "showDiscardPlanDialog = true" in cancel
    assert cancel.index("planHasUnsavedWork") < cancel.index("status.cancelPlanning()")
    dialog = plan[plan.index('.confirmationDialog("Discard this plan?"'):plan.index(".toolbar")]
    assert "isPresented: $showDiscardPlanDialog" in dialog
    assert 'Button("Discard", role: .destructive)' in dialog
    assert "status.cancelPlanning()" in dialog
    assert 'Button("Keep editing", role: .cancel)' in dialog
    assert "stops.count > 2" in decl_body(src, "static func planHasUnsavedWork")


def test_auto_start_is_held_under_the_discard_dialog():
    # Connect & start, then Cancel → "Discard this plan?": the link coming up
    # must not launch the plan under the dialog; Keep editing resumes it,
    # Discard disarms it.
    src = _src()
    auto = decl_body(src, "private func tryAutoStartNavigation")
    assert "!showDiscardPlanDialog" in auto
    assert auto.index("!showDiscardPlanDialog") < auto.index("startNavigation(plan:")
    resume = src[src.index(".onChange(of: showDiscardPlanDialog)"):]
    resume = resume[:resume.index(".onChange(", 1)]
    assert "if !up { tryAutoStartNavigation() }" in resume
    # The plan going away OR being replaced (a share while the dialog is up)
    # clears the flag: Discard must never hit a plan the rider didn't see, and
    # a dropped write-back must not keep `anotherModalUp` true for good.
    ident = src[src.index(".onChange(of: status.plannedRoute.map(ObjectIdentifier.init)"):]
    ident = ident[:ident.index(".onChange(", 1)]
    assert "showDiscardPlanDialog = false" in ident
    dialog = src[src.index('.confirmationDialog("Discard this plan?"'):]
    discard = dialog[dialog.index('Button("Discard"'):dialog.index('Button("Keep editing"')]
    assert discard.index("pendingAutoStart = false") < discard.index("status.cancelPlanning()")
    assert "showDiscardPlanDialog" in decl_body(src, "private var anotherModalUp")
