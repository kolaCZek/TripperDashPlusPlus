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
        body = decl_body(STATUS, "private func freeRideDecision(")
        self.assertIn("planStaged: plannedRoute != nil", body)
        self.assertIn("shortcutConnect: shortcutConnect", body)
        self.assertIn("silent = rx > Self.silentLinkSeconds", body)
        self.assertIn("handConnectedAt.map { Date().timeIntervalSince($0) < Self.handConnectGraceSeconds }", body)
        # Only a connect the rider started marks the grace, not a reconnect.
        hand = decl_body(STATUS, "func connect(to bike: SavedBike")
        self.assertIn("handConnect = !fromShortcut", hand)
        self.assertIn("bikeLink.patientBootRace = fromShortcut", hand)
        # The rider's own connect wins over a shortcut still starting.
        self.assertIn("if pendingRideRequest == .freeRide { pendingRideRequest = nil }", hand)
        self.assertIn("connect(to: bike, fromShortcut: true)", decl_body(STATUS, "private func connectSelectedBike("))

    def test_shortcut_connect_and_request_hold_the_wakelock(self):
        # The automation fires at AP-up, ~28 s before the dash answers: a
        # phone pocketed meanwhile must not be suspended mid-handshake.
        body = decl_body(STATUS, "private func applyKeepAwake(")
        self.assertIn("let linkComingUp = bikeLink.state == .connecting || bikeLink.state == .handshaking", body)
        self.assertIn("let rideWanted = isStreaming || hasStreamingIntent || pendingRideRequest != nil", body)
        self.assertIn("|| (shortcutConnect && (linkComingUp || bikeLink.state == .reconnecting)))", body)
        obs = decl_body(STATUS, "private func observeStreamingIntent(")
        self.assertIn("_ = pendingRideRequest", obs)

    def test_shortcut_connect_prefers_the_bike_it_is_on(self):
        body = decl_body(STATUS, "private func connectSelectedBike(")
        self.assertIn("savedBikes.bikes.first(where: { $0.ssid == ssid }) ?? savedBikes.selected", body)
        self.assertIn("guard shortcutConnect else { return }", body)

    def test_reconnecting_wait_wakes_the_retry(self):
        body = decl_body(STATUS, "func startFreeRideFromShortcut(")
        wait = body[body.index("case .waitForLink:"):body.index("case .reconnectLink:")]
        self.assertIn("wakeSleepingReconnect()", wait)
        self.assertIn("bikeLink.dropSilentLink()", body)
        stage = decl_body(STATUS, "private func navigateFromShortcut(_ plan: PlannedRoute")
        self.assertIn("default: wakeSleepingReconnect()", stage)
        # A budget that ran out while the app slept must not end the retry at once.
        wake = decl_body(STATUS, "private func wakeSleepingReconnect(")
        self.assertIn("guard bikeLink.state == .reconnecting else { return }", wake)
        self.assertLess(wake.index("bikeLink.renewReconnectBudget()"), wake.index("bikeLink.connect()"))
        self.assertIn("shortcutConnect = true", wake)

    def test_stop_ride_cancels_its_connect_before_the_ride_branches(self):
        body = decl_body(STATUS, "func stopRideFromShortcut(")
        self.assertLess(body.index("if ownConnect { bikeLink.disconnect() }"), body.index("if activeNavigator.isNavigating"))
        self.assertIn("case .connecting, .handshaking, .reconnecting: if ownConnect", body)

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
