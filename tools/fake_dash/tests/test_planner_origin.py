"""
Drift guards: the planner doesn't show the "Current location" snapshot, and
a shared route waits for a fix before dropping a start at the rider.

The origin waypoint's coordinate is a snapshot taken at planning time. With
no fix yet (app launched cold by a share) it is stop 1's coordinate, so a
green origin pin there hid the stop-1 pin, and fitting to it left the rider
off screen. Routing never reads it (`.forCurrentLocation()`).
"""

from __future__ import annotations

import pathlib
import unittest

from tests.swift_source import decl_body, strip_comments

ROOT = pathlib.Path(__file__).resolve().parents[3] / "TripperDashPP"
MAP = ROOT / "UI/Navigation/PlanningMapView.swift"
STATUS = ROOT / "App/AppStatus.swift"


class PlanningMapSkipsSnapshot(unittest.TestCase):
    def setUp(self):
        self.src = strip_comments(MAP.read_text(encoding="utf-8"))

    def test_no_pin_for_current_location(self):
        body = decl_body(self.src, "func syncWaypointPins")
        self.assertIn("!$0.element.isCurrentLocation", body)
        self.assertIn("pinned.map", body)

    def test_fit_skips_snapshot_and_refits_on_legs(self):
        fit = decl_body(self.src, "func fitIfNeeded")
        self.assertIn("where !wp.isCurrentLocation", fit)
        sig = decl_body(self.src, "private func waypointSignature")
        self.assertIn("hasher.combine(parent.plan.isComputed)", sig)


class SharedRouteWaitsForFix(unittest.TestCase):
    def test_wait_precedes_stops_and_same_spot_drop(self):
        src = strip_comments(STATUS.read_text(encoding="utf-8"))
        body = decl_body(src, "func beginPlanningFromShared")
        wait = body.index("await waitForFirstFix()")
        self.assertLess(wait, body.index("var stops: [Waypoint] = []"))
        self.assertLess(wait, body.index("Self.isSameSpot("))

    def test_single_wait_helper(self):
        # #184 adds the same helper for Shortcuts: one copy only, or the
        # merged file redeclares it (git merges that cleanly).
        src = strip_comments(STATUS.read_text(encoding="utf-8"))
        self.assertEqual(src.count("func waitForFirstFix()"), 1)


if __name__ == "__main__":
    unittest.main()
