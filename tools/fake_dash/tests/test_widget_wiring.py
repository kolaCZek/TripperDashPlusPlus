"""Drift guards for the Quick Ride home-screen widget.

The widget (`TripperDashWidgetsBundle.swift`) only opens
`tripperdash://ride?to=<id>`; `AppStatus.runWidgetAction` acts on it. These
pin that every widget button has a handler, that the `ride` host is caught
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
        self.assertIn('URL(string: "tripperdash://ride?to=\\(a.id)")', WIDGET)
        body = decl_body(STATUS, "func runWidgetAction(")
        self.assertIn('to == "free"', body)
        self.assertIn('to == "fuel"', body)
        self.assertIn("QuickAccessSlot(rawValue: to)", body)
        for slot in ("home", "work"):
            self.assertRegex(STORE, rf"case {slot}\b")

    def test_ride_host_caught_before_share_decode(self):
        body = decl_body(STATUS, "func handleIncomingURL(")
        ride = body.index('== "ride"')
        self.assertLess(ride, body.index("SharedDeepLink.decode"))
        self.assertIn("return", body[ride:body.index("SharedDeepLink.decode")])

    def test_hidden_success_replies_exist(self):
        body = decl_body(STATUS, "private func navigateFromShortcut(_ plan")
        self.assertIn('return "Starting navigation to', body)
        self.assertIn('return "Rerouting to', body)
        self.assertIn('said.hasPrefix("Starting navigation") || said.hasPrefix("Rerouting to")',
                      decl_body(STATUS, "func runWidgetAction("))


if __name__ == "__main__":
    unittest.main()
