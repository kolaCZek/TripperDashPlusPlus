"""
Field bug (2026-10-19): a stop removed from the dash menu (button 0x20,
`skipCurrentLeg`) kept its blue line. The dash still drew the route to the
removed stop.

Three things kept it on screen:
  1. `installFullRouteContext` concatenated EVERY leg, including the one to
     the removed stop, and kept its via-dot.
  2. The next leg starts AT the removed stop, so until the off-route
     reroute (~7 s later in the log) the active line and turns led there.
  3. The off-route reroute replaced the leg's options but left the old
     alternatives (grey lines from the removed stop) drawn.
Plus (reviews): the progress bar is rebased on the legs still ahead, so it
neither jumps by the skipped leg nor keeps the removed stop's tick; and a
reroute already in flight when the stop is removed must not land on the
new leg: `requestReroute` drops a result whose destination is no longer
the current one and lets the next off-route fix reroute at once.
"""

from __future__ import annotations

import pathlib
import unittest

from tests.swift_source import decl_body, strip_comments

ROOT = pathlib.Path(__file__).resolve().parents[3] / "TripperDashPP"
NAV = ROOT / "Navigation/ActiveNavigator.swift"
PICKER = ROOT / "UI/MapPickerView.swift"


def dots_ahead(n_waypoints: int, from_leg: int) -> list[int]:
    """Mirror of the via-dot slice: waypoint indices still ahead, final
    destination excluded (leg i runs waypoint i -> i+1)."""
    first = from_leg + 1
    return list(range(first, n_waypoints - 1)) if first < n_waypoints - 1 else []


class DotsAhead(unittest.TestCase):
    def test_slices(self):
        # origin + 4 stops + destination = 6 waypoints, 5 legs
        self.assertEqual(dots_ahead(6, 0), [1, 2, 3, 4])
        self.assertEqual(dots_ahead(6, 1), [2, 3, 4])   # stop 1 removed/reached
        self.assertEqual(dots_ahead(6, 4), [])          # final leg
        self.assertEqual(dots_ahead(2, 0), [])          # single destination


class SwiftWiring(unittest.TestCase):
    def setUp(self):
        self.nav = strip_comments(NAV.read_text(encoding="utf-8"))
        self.picker = strip_comments(PICKER.read_text(encoding="utf-8"))

    def test_full_route_starts_at_current_leg(self):
        body = decl_body(self.picker, "private func installFullRouteContext")
        self.assertIn("plan.legs.dropFirst(fromLeg)", body)
        self.assertIn("let firstAhead = fromLeg + 1", body)
        self.assertIn("wps[firstAhead..<(wps.count - 1)]", body)
        self.assertIn("fromLeg: status.activeNavigator.currentLegIndex", self.picker)
        self.assertIn("installFullRouteContext(plan: plan, fromLeg: 0)", self.picker)

    def test_skip_reroutes_from_rider_at_once(self):
        body = decl_body(self.nav, "func skipCurrentLeg(")
        self.assertLess(body.index("await advanceToNextLeg("),
                        body.index("await requestReroute(from: here)"))

    def test_late_reroute_for_an_old_leg_is_dropped(self):
        # A reroute in flight when the stop is removed (an off-route one, or
        # a first press before a second) must not be installed on the new leg.
        body = decl_body(self.nav, "private func requestReroute(")
        guard = body.index("guard destination == dest else")
        self.assertLess(body.index("await cb(coord, dest)"), guard)
        self.assertLess(guard, body.index("offRouteSince = .distantPast"))
        self.assertLess(body.index("offRouteSince = .distantPast"), body.index("await installSwappedRoute(newRoute)"))

    def test_skip_rebases_progress_bar(self):
        body = decl_body(self.nav, "func skipCurrentLeg(")
        covered = body.index("let covered = plannedTotalDistance - finalDestinationRemainingDistance")
        self.assertLess(covered, body.index("await advanceToNextLeg(in: plan, rebaseCovered: covered)"))
        # Rebase before the advance's first await (a second press reads it).
        adv = decl_body(self.nav, "private func advanceToNextLeg(")
        self.assertLess(adv.index("setProgressBaseline(plan: plan, fromLegIndex: next, alreadyCovered: rebaseCovered)"),
                        adv.index("await onActiveRouteChanged?("))
        # Post-reroute rebase only on the same ride, plan and leg.
        guard = body.index("guard isNavigating, !hasArrived, self.plan === plan")
        rebase = body.index("setProgressBaseline(plan: plan, fromLegIndex: currentLegIndex, alreadyCovered: covered)")
        self.assertLess(body.index("await requestReroute(from: here)"), guard)
        self.assertLess(guard, rebase)
        # Tick-comb cutoff counts the plan's via-points, not just those ahead.
        self.assertIn("let viaCount = plan.legs.count - 1",
                      decl_body(self.nav, "private func setProgressBaseline("))

    def test_reroute_drops_stale_alternatives(self):
        body = decl_body(self.nav, "private func installSwappedRoute(")
        self.assertLess(body.index("plan.replaceLegRoute("), body.index("refreshAlternatives()"))
        self.assertLess(body.index("refreshAlternatives()"), body.index("await onActiveRouteChanged?("))


if __name__ == "__main__":
    unittest.main()
