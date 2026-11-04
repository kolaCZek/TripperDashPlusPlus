"""Drift guards for the Quick Ride home-screen widget.

The widget (`TripperDashWidgetsBundle.swift`) only opens
`tripperdash://quick?to=<id>`; `AppStatus.runWidgetAction` acts on it. These
pin that every widget button has a handler, that the `quick` host is caught
before the share-link decoder, and that the success replies the handler
hides still exist in `navigateFromShortcut`.
"""

from __future__ import annotations

import pathlib
import re
import unittest

from tests.swift_source import decl_body, strip_comments

ROOT = pathlib.Path(__file__).resolve().parents[3] / "TripperDashPP"
STATUS = strip_comments((ROOT / "App/AppStatus.swift").read_text())
WIDGET = strip_comments((ROOT / "TripperDashWidgets/TripperDashWidgetsBundle.swift").read_text())
STORE = strip_comments((ROOT / "Navigation/NavigationStore.swift").read_text())


class WidgetWiringTests(unittest.TestCase):

    def test_every_button_has_a_handler(self):
        ids = re.findall(r'Action\(id: "(\w+)"', WIDGET)
        self.assertEqual(sorted(ids), ["free", "fuel", "home", "work"])
        self.assertIn('URL(string: "tripperdash://quick?to=\\(a.id)")', WIDGET)
        body = decl_body(STATUS, "func runWidgetAction(")
        self.assertIn('if to == "free" {', body)
        self.assertIn('} else if to == "fuel" {', body)
        self.assertIn("QuickAccessSlot(rawValue: to)", body)
        for slot in ("home", "work"):
            self.assertRegex(STORE, rf"case {slot}\b")

    def test_quick_host_caught_before_share_decode(self):
        body = decl_body(STATUS, "func handleIncomingURL(")
        quick = body.index('== "quick"')
        self.assertLess(quick, body.index("SharedDeepLink.decode"))
        self.assertIn("return", body[quick:body.index("SharedDeepLink.decode")])

    def test_hidden_success_replies_exist(self):
        body = decl_body(STATUS, "private func navigateFromShortcut(_ plan")
        self.assertIn('return "Starting navigation to', body)
        self.assertIn('return "Rerouting to', body)
        self.assertIn('said.hasPrefix("Starting navigation") || said.hasPrefix("Rerouting to")',
                      decl_body(STATUS, "func runWidgetAction("))

    def test_rider_facing_choices(self):
        body = decl_body(STATUS, "func runWidgetAction(")
        # The hand-plan refusal is decided before any await (the fuel search).
        self.assertLess(body.index("handPlanStaged && !activeNavigator.isNavigating"), body.index("await waitForFirstFix()"))
        # A widget-staged plan is the rider's from the stage itself (before
        # the connect's first await): no unattended teardown.
        self.assertIn("riderOwned: true)", body)
        stage = decl_body(STATUS, "private func navigateFromShortcut(_ plan")
        self.assertIn("shortcutStopIds = riderOwned ? [] : plan.waypoints.map", stage)
        self.assertLess(stage.index("shortcutStopIds = riderOwned"), stage.index("await connectSelectedBike()"))
        # A deliberate Free Ride tap rides a hand link, or arms one coming up.
        self.assertRegex(body, r"case \.handConnected:\s*await startFreeRide\(\)")
        self.assertRegex(body, r"case \.handConnecting:\s*pendingRideRequest = \.freeRide")
        # The notice is drawn outside the planner, in every mode.
        picker = strip_comments((ROOT / "UI/MapPickerView.swift").read_text())
        self.assertIn("if let notice = status.widgetNotice", decl_body(picker, "var body: some View"))


if __name__ == "__main__":
    unittest.main()
