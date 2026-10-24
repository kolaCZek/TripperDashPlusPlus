"""Drift guards for the Shortcuts wiring around `ShortcutPolicy`.

`ShortcutPolicyTests.swift` pins the pure policy; these pin what feeds it and
what acts on its answer, which the policy tests can't see:

1. The free-ride decision gets `planStaged` from ANY staged plan (not only a
   hand-built one) and the shortcut-connect flag, so a "joined the bike's
   Wi-Fi" automation fired by the app's own join never takes over the rider's
   connect or plan.
2. A pending free ride starts on `.connected` only with no ride and no plan.
3. The picker consumes only a `.navigate` request.
4. Navigate from a free ride routes BEFORE it ends the free ride, and keeps the
   free ride when routing fails.
"""

from __future__ import annotations

import pathlib
import unittest

from tests.swift_source import decl_body, strip_comments

ROOT = pathlib.Path(__file__).resolve().parents[3] / "TripperDashPP"
STATUS = strip_comments((ROOT / "App/AppStatus.swift").read_text())
PICKER = strip_comments((ROOT / "UI/MapPickerView.swift").read_text())


class ShortcutWiringTests(unittest.TestCase):

    def test_free_ride_decision_inputs(self):
        body = decl_body(STATUS, "private var freeRideDecision:")
        self.assertIn("planStaged: plannedRoute != nil", body)
        self.assertIn("shortcutConnect: shortcutConnect", body)

    def test_pending_free_ride_needs_no_ride_and_no_plan(self):
        self.assertIn("if !self.rideActive && self.plannedRoute == nil { await self.startFreeRide() }", STATUS)

    def test_picker_consumes_only_navigate(self):
        body = decl_body(PICKER, "private func consumeRideRequest(")
        self.assertIn("guard status.pendingRideRequest == .navigate else { return }", body)

    def test_navigate_from_free_ride_routes_first(self):
        body = decl_body(STATUS, "private func navigateFromShortcut(_ plan: PlannedRoute")
        stage = body[body.index("case .stage:"):]
        self.assertLess(stage.index("try await routingService.recompute(plan"), stage.index("stopFreeRide()"))
        self.assertIn('return "Couldn\'t find a route to \\(dest). Free ride continues."', stage)


if __name__ == "__main__":
    unittest.main()
