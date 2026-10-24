"""
Field bug (2026-10): off the route, the reroute often led straight back the
way the rider came. The rider dragged the blue line behind and the distance
to the turn kept growing.

MKDirections takes no heading. From a bare point it picks either direction
of the road. `requestReroute` now asks for Apple's alternatives (the hook the
live-traffic check already uses) and takes the best one that leaves within
90 deg of the rider's GPS course (`forwardRouteIndex`). If every option turns
back, it keeps Apple's best and retries at the 10 s failure pace, so a rider
who rides on gets a fresh try instead of 30 s of the line behind.
"""

from __future__ import annotations

import math
import pathlib
import unittest

from tests.swift_source import decl_body, strip_comments

NAV = pathlib.Path(__file__).resolve().parents[3] / "TripperDashPP/Navigation/ActiveNavigator.swift"


def haversine(a, b):
    p1, p2 = math.radians(a[0]), math.radians(b[0])
    dp, dl = p2 - p1, math.radians(b[1] - a[1])
    h = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 6_371_000 * 2 * math.atan2(math.sqrt(h), math.sqrt(1 - h))


def bearing(a, b):
    p1, p2 = math.radians(a[0]), math.radians(b[0])
    dl = math.radians(b[1] - a[1])
    y = math.sin(dl) * math.cos(p2)
    x = math.cos(p1) * math.sin(p2) - math.sin(p1) * math.cos(p2) * math.cos(dl)
    return (math.degrees(math.atan2(y, x)) + 360) % 360


def outgoing_bearing(pts, anchor):
    """Mirror of ManeuverGeometry.outgoingBearing."""
    acc, end = 0.0, pts[-1]
    for i in range(len(pts) - 1):
        acc += haversine(pts[i], pts[i + 1])
        end = pts[i + 1]
        if acc >= anchor:
            break
    return bearing(pts[0], end) if haversine(pts[0], end) >= 1.0 else None


def forward_route_index(routes, course, anchor=30):
    """Mirror of ActiveNavigator.forwardRouteIndex."""
    for i, pts in enumerate(routes):
        if len(pts) < 2:
            continue
        start = outgoing_bearing(pts, anchor)
        if start is None:
            continue
        if abs((start - course + 540) % 360 - 180) < 90:
            return i
    return None


O = (50.0, 14.0)
D = 0.001  # ~111 m of latitude
NORTH = [O, (O[0] + D, O[1])]
SOUTH = [O, (O[0] - D, O[1])]
# 10 m ahead, then a hard right: still leaves ahead (bearing ~63 deg).
RIGHT_AT_JUNCTION = [O, (O[0] + 0.00009, O[1]), (O[0] + 0.00009, O[1] + 0.00028)]


class ForwardRouteIndex(unittest.TestCase):
    def test_takes_best_route_that_carries_on(self):
        self.assertEqual(forward_route_index([SOUTH, NORTH], course=0), 1)
        self.assertEqual(forward_route_index([NORTH, SOUTH], course=0), 0)

    def test_all_turn_back(self):
        self.assertIsNone(forward_route_index([SOUTH, SOUTH], course=0))
        self.assertIsNone(forward_route_index([], course=0))

    def test_wraps_around_north(self):
        self.assertEqual(forward_route_index([SOUTH, NORTH], course=350), 1)
        self.assertEqual(forward_route_index([NORTH, SOUTH], course=170), 1)

    def test_turn_right_just_ahead_counts_as_ahead(self):
        self.assertEqual(forward_route_index([SOUTH, RIGHT_AT_JUNCTION], course=0), 1)

    def test_degenerate_routes_skipped(self):
        self.assertEqual(forward_route_index([[O], [O, O], NORTH], course=0), 2)


class SwiftWiring(unittest.TestCase):
    def setUp(self):
        self.nav = strip_comments(NAV.read_text(encoding="utf-8"))

    def test_mirror_matches_swift(self):
        body = decl_body(self.nav, "static func forwardRouteIndex(")
        self.assertIn("departureAnchorMeters: CLLocationDistance = 30", self.nav)
        self.assertIn("guard coords.count >= 2", body)
        self.assertIn("abs(ManeuverGeometry.signedDelta(from: course, to: start)) < 90", body)
        self.assertIn("routes.firstIndex", body)

    def test_course_only_while_moving(self):
        self.assertIn("if fix.course >= 0, fix.speed >= courseMinSpeed { travelCourse = fix.course }",
                      decl_body(self.nav, "func ingest(fix: Fix)"))
        self.assertIn("self.travelCourse = nil", decl_body(self.nav, "func stop()"))

    def test_reroute_prefers_road_ahead(self):
        body = decl_body(self.nav, "private func requestReroute(")
        alts = body.index("await alternatives(coord, dest)")
        self.assertLess(body.index("if let course = travelCourse, let alternatives = onTrafficRoutesRequested"), alts)
        self.assertIn("rerouted = ahead.map { routes[$0] } ?? routes.first", body)
        # No course yet (standing start): Apple's single best, as before.
        self.assertLess(alts, body.index("rerouted = await cb(coord, dest)"))
        # The stale-leg guard still runs before anything is installed.
        self.assertLess(body.index("guard destination == dest else"), body.index("await installSwappedRoute(newRoute)"))

    def test_u_turn_only_retries_soon(self):
        body = decl_body(self.nav, "private func requestReroute(")
        self.assertLess(body.index("await installSwappedRoute(newRoute)"), body.index("if needsUTurn {"))


if __name__ == "__main__":
    unittest.main()
