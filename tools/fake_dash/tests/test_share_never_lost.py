"""
Drift guards: a "Share to TripperDash++" payload is never silently lost.

  - M1: the picker consumes a pending search hint only when it can actually
    present Search (idle picker, no other modal, no Save-route alert) and
    re-checks when that gate opens. It used to set `showSearch = true` over
    an open sheet (SwiftUI drops it) and clear the hint anyway.
  - M2: a share arriving mid-ride (navigation or free ride) is parked in ONE
    `AppStatus.pendingShare` slot (latest wins) instead of staged — the next
    `stopNavigation()` nils `plannedRoute` and would wipe it. The rider gets
    a dash notice; the picker replays it once the ride is over.
  - L11: a supported share that resolves to nothing shows an alert in the
    extension instead of closing without a word.
"""

from __future__ import annotations

import pathlib
import unittest

from tests.swift_source import decl_body, strip_comments

ROOT = pathlib.Path(__file__).resolve().parents[3] / "TripperDashPP"
PICKER = ROOT / "UI/MapPickerView.swift"
STATUS = ROOT / "App/AppStatus.swift"
SHARE = ROOT / "TripperDashShare/ShareViewController.swift"


class SearchHintWaitsForGate(unittest.TestCase):
    def setUp(self):
        self.src = strip_comments(PICKER.read_text(encoding="utf-8"))

    def test_gate_covers_modals_and_ride(self):
        gate = decl_body(self.src, "private var shareGateOpen")
        for part in ("mode == .picking", "!anotherModalUp", "!showPlanSaveAlert"):
            self.assertIn(part, gate)

    def test_consume_is_gated_and_only_path_to_search(self):
        consume = decl_body(self.src, "private func consumePendingShare")
        self.assertIn("guard shareGateOpen else { return }", consume)
        self.assertLess(consume.index("guard shareGateOpen"),
                        consume.index("status.pendingSearchHint = nil"))
        self.assertIn("status.beginPlanningFromShared(share", consume)
        # The hint onChange must not present Search / clear the hint itself.
        self.assertIn(".onChange(of: status.pendingSearchHint) { _, _ in consumePendingShare() }",
                      self.src)
        self.assertIn(".onChange(of: status.pendingShare) { _, _ in consumePendingShare() }",
                      self.src)

    def test_rechecks_when_gate_opens(self):
        handler = decl_body(self.src, ".onChange(of: [shareGateOpen, isPlanning], initial: true)")
        self.assertIn("guard shareGateOpen else { return }", handler)
        self.assertIn("consumePendingShare()", handler)

    def test_parked_share_does_not_replace_a_plan_in_progress(self):
        consume = decl_body(self.src, "private func consumePendingShare")
        self.assertIn("if !isPlanning, let share = status.pendingShare", consume)


class ShareParkedDuringRide(unittest.TestCase):
    def setUp(self):
        self.src = strip_comments(STATUS.read_text(encoding="utf-8"))

    def test_ride_active_covers_nav_and_free_ride(self):
        self.assertIn(
            "private var rideActive: Bool { activeNavigator.isNavigating || isFreeRiding }",
            self.src)

    def test_begin_parks_before_staging(self):
        body = decl_body(self.src, "func beginPlanningFromShared")
        self.assertLess(body.index("rideActive"), body.index("switch resolution"))
        self.assertIn("parkShare(resolution)", body)

    def test_empty_share_leaves_a_parked_one_alone(self):
        # An unreadable share has nothing to replace a parked one with.
        body = decl_body(self.src, "func beginPlanningFromShared")
        self.assertLess(body.index("guard resolution != .empty else { return false }"),
                        body.index("pendingShare = nil"))

    def test_replay_does_not_replace_a_plan_started_during_its_geocode(self):
        body = decl_body(self.src, "func beginPlanningFromShared")
        self.assertEqual(body.count("replay: replay"), 2)   # both stagePlan calls
        stage = decl_body(self.src, "private func stagePlan")
        guard = stage.index("guard !(replay && plannedRoute != nil)")
        self.assertLess(guard, stage.index("plannedRoute = plan"))
        self.assertIn("pendingShare = shared", stage[guard:stage.index("plannedRoute = plan")])
        picker = strip_comments(PICKER.read_text(encoding="utf-8"))
        self.assertIn("status.beginPlanningFromShared(share, replay: true)", picker)

    def test_starting_a_ride_from_another_plan_drops_a_parked_share(self):
        picker = strip_comments(PICKER.read_text(encoding="utf-8"))
        start = decl_body(picker, "private func startNavigation(plan: PlannedRoute)")
        self.assertIn("status.pendingShare = nil", start)

    def test_newer_share_supersedes_a_parked_one(self):
        # Latest wins: once not parking, the handled share clears the slot
        # before it's staged, so an older parked share can't replay over it.
        body = decl_body(self.src, "func beginPlanningFromShared")
        park = body.index("parkShare(resolution)")
        clear = body.index("pendingShare = nil", park)
        self.assertLess(clear, body.index("switch resolution"))

    def test_stage_plan_rechecks_after_geocode(self):
        body = decl_body(self.src, "private func stagePlan")
        self.assertLess(body.index("guard !rideActive"), body.index("plannedRoute = plan"))
        self.assertIn("parkShare(", body)

    def test_park_is_single_slot_and_tells_rider(self):
        body = decl_body(self.src, "private func parkShare")
        self.assertIn("pendingShare = resolution", body)
        self.assertIn("showNotice(", body)


class EmptyShareNotSilent(unittest.TestCase):
    def test_nothing_actionable_shows_alert(self):
        src = strip_comments(SHARE.read_text(encoding="utf-8"))
        i = src.index('log.warning("share resolved to nothing actionable")')
        branch = src[i:src.index("return", i)]
        self.assertIn("showUnsupported(message:", branch)
        self.assertNotIn("finish()", branch)


if __name__ == "__main__":
    unittest.main()
