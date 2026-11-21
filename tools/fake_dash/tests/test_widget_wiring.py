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

    def test_mid_ride_fuel_adds_a_stop(self):
        body = decl_body(STATUS, "func runWidgetAction(")
        # Mid-navigation Fuel keeps the plan: station first, then the stops
        # still ahead, swapped in through the Edit route path (replacePlan).
        fuel = body[body.index("let ahead = running.map"):]
        self.assertIn("let ahead = running.map { PlannedRoute.remainingStops(of: $0, fromLegIndex: legIndex) }", body)
        self.assertIn("stops: [Waypoint.from(destination: dest)] + ahead", fuel)
        self.assertIn("PlannedRoute.carryComputedLegs(from: running, into: plan)", fuel)
        self.assertLess(fuel.index("navigateFromShortcut(plan, running: running, legIndex: legIndex, label: dest.name)"),
                        fuel.index("navigateFromShortcut(to: dest"))
        # A planned stop that already is the station isn't added twice.
        self.assertRegex(fuel, r"let next = ahead\.first, Self\.isSameSpot\(next\.coordinate, dest\.coordinate\) \{"
                               r"[^}]*said = \"Rerouting to")
        self.assertLess(fuel.index("Self.isSameSpot("), fuel.index("[Waypoint.from(destination: dest)] + ahead"))
        redirect = decl_body(STATUS, "private func navigateFromShortcut(_ plan")
        self.assertIn("nav.replacePlan(plan)", redirect)
        # A stop reached during routing makes the inserted plan stale: the
        # leg is checked while routing and again right before the swap.
        self.assertIn("nav.plan === running && (legIndex == nil || nav.currentLegIndex == legIndex)", redirect)
        self.assertIn("isStillLive: isLive)", redirect)
        self.assertIn("guard isLive(), await nav.replacePlan(plan)", redirect)
        # The failure notice names the station, not the final destination.
        self.assertIn('let dest = label ?? plan.waypoints.last?.name', redirect)
        # Carried legs aren't routed again.
        self.assertIn("dirtyLegIndices: Set(plan.legs.indices.filter { !plan.legs[$0].isComputed })", redirect)

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
        # Stop Ride withdrawing a widget plan's request disarms its auto-start.
        picker_src = strip_comments((ROOT / "UI/MapPickerView.swift").read_text())
        self.assertIn("if old == .navigate && new == nil { pendingAutoStart = false }", picker_src)
        self.assertIn("!(byRequest && status.pendingRideRequest == nil)", picker_src)
        # Free Ride decides once and hands that decision on.
        self.assertIn("freeRideShortcutRefusal(decision)", body)
        self.assertIn("startFreeRideFromShortcut(decision)", body)
        # The notice is drawn outside the planner, in every mode.
        picker = strip_comments((ROOT / "UI/MapPickerView.swift").read_text())
        self.assertIn("if let notice = status.widgetNotice", decl_body(picker, "var body: some View"))


if __name__ == "__main__":
    unittest.main()
