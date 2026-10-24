"""
Field request (2026-10): when every reroute option turns back, the rider
rides on dragging the blue line behind them while the dash still shows the
next turn (far behind) with a growing distance. Apple Maps says "make a
U-turn" instead.

`ActiveNavigator.updateWrongWay` compares the GPS course (while moving,
>= 3 m/s) with the bearing of the route segment nearest the rider. Riding
more than 120 deg against the line for 3 s sets `isWrongWay`; riding within
60 deg of it clears it (in between, e.g. a bend or a turn, keeps the state).
`upcomingManeuver` then returns a U-turn (side by driving side), so the dash
bubble, overlay, Live Activity and phone HUD all show it; the nav loop drops
the look-ahead chip and speaks the U-turn once per episode.
"""

from __future__ import annotations

import pathlib
import unittest

from tests.swift_source import decl_body, strip_comments

ROOT = pathlib.Path(__file__).resolve().parents[3] / "TripperDashPP/Navigation"
NAV = ROOT / "ActiveNavigator.swift"
LOOP = ROOT / "ActiveNavLoop.swift"

DELAY = 3.0


def wrong_way_since(since, delta, t):
    """Mirror of ActiveNavigator.wrongWaySince."""
    if delta > 120:
        return since if since is not None else t
    if delta < 60:
        return None
    return since


def run(samples):
    """samples: (t, |course - line| deg) per moving fix -> isWrongWay after each."""
    since, out = None, []
    for t, delta in samples:
        since = wrong_way_since(since, delta, t)
        out.append(since is not None and t - since >= DELAY)
    return out


class Hysteresis(unittest.TestCase):
    def test_needs_three_seconds_against_the_line(self):
        self.assertEqual(run([(0, 180), (1, 175), (2, 178), (3, 180)]), [False, False, False, True])

    def test_turn_or_bend_does_not_trigger(self):
        self.assertEqual(run([(t, 90) for t in range(10)]), [False] * 10)

    def test_brief_flip_does_not_trigger(self):
        # GPS glitch / hairpin: two seconds against, then back along the line.
        self.assertEqual(run([(0, 170), (1, 170), (2, 20), (3, 170), (4, 170)]), [False] * 5)

    def test_between_60_and_120_keeps_state(self):
        # Turning round in a junction passes through 90 deg: the U-turn stays
        # until the rider actually rides along the line.
        self.assertEqual(run([(0, 180), (3, 180), (4, 100), (5, 70), (6, 30)]),
                         [False, True, True, True, False])


class SwiftWiring(unittest.TestCase):
    def setUp(self):
        self.nav = strip_comments(NAV.read_text(encoding="utf-8"))
        self.loop = strip_comments(LOOP.read_text(encoding="utf-8"))

    def test_mirror_matches_swift(self):
        body = decl_body(self.nav, "static func wrongWaySince(")
        self.assertIn("if delta > 120 { return since ?? t }", body)
        self.assertIn("if delta < 60 { return nil }", body)
        self.assertIn("private let wrongWayDelay: TimeInterval = 3", self.nav)

    def test_checked_on_every_fix_against_the_nearest_segment(self):
        ingest = decl_body(self.nav, "func ingest(fix: Fix)")
        self.assertLess(ingest.index("self.lastSegmentIndex = segIdx"),
                        ingest.index("updateWrongWay(fix: fix, on: route.polyline, segmentIndex: segIdx)"))
        upd = decl_body(self.nav, "private func updateWrongWay(")
        self.assertIn("fix.speed >= courseMinSpeed", upd)
        self.assertIn("ManeuverGeometry.bearing(from: pts[i].coordinate, to: pts[i + 1].coordinate)", upd)

    def test_upcoming_maneuver_becomes_u_turn(self):
        body = decl_body(self.nav, "var upcomingManeuver")
        self.assertLess(body.index("if isWrongWay"), body.index("ManeuverKind.classify("))
        self.assertIn(".uTurnRight : .uTurnLeft", body)

    def test_reset_on_stop(self):
        stop = decl_body(self.nav, "func stop()")
        self.assertIn("self.isWrongWay = false", stop)
        self.assertIn("self.wrongWaySince = nil", stop)

    def test_loop_speaks_once_and_hides_lookahead(self):
        self.assertIn("&& !nav.isWrongWay", self.loop)
        voice = decl_body(self.loop, "private func emitVoice(")
        self.assertLess(voice.index("if isRerouting {"), voice.index("if isWrongWay {"))
        self.assertIn("if !spokeUTurnForEpisode,", voice)
        self.assertIn("isWrongWay: nav.isWrongWay", self.loop)


if __name__ == "__main__":
    unittest.main()
