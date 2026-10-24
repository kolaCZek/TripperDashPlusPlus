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
PENALTY = 30.0


def wrong_way_since(since, delta, t, active):
    """Mirror of ActiveNavigator.wrongWaySince."""
    if delta > 120:
        return since if since is not None else t
    if delta < 60 or not active:
        return None
    return since


def run(samples):
    """samples: (t, |course - line| deg, or None for a slow fix) -> isWrongWay
    after each (mirror of updateWrongWay)."""
    since, active, out = None, False, []
    for t, delta in samples:
        if delta is None:
            if not active:
                since = None
        else:
            since = wrong_way_since(since, delta, t, active)
            active = since is not None and t - since >= DELAY
        out.append(active)
    return out


class Hysteresis(unittest.TestCase):
    def test_needs_three_seconds_against_the_line(self):
        self.assertEqual(run([(0, 180), (1, 175), (2, 178), (3, 180)]), [False, False, False, True])

    def test_turn_or_bend_does_not_trigger(self):
        self.assertEqual(run([(t, 90) for t in range(10)]), [False] * 10)

    def test_brief_flip_does_not_trigger(self):
        # GPS glitch / hairpin: two seconds against, then back along the line.
        self.assertEqual(run([(0, 170), (1, 170), (2, 20), (3, 170), (4, 170)]), [False] * 5)

    def test_start_needs_every_fix_against(self):
        # One fix against, then the 60-120 band or a slow fix: no clock left.
        self.assertEqual(run([(0, 180), (1, 100), (2, 100), (3, 180)]), [False] * 4)
        self.assertEqual(run([(0, 180), (1, None), (2, None), (3, 180)]), [False] * 4)

    def test_active_u_turn_survives_turning_round_and_stops(self):
        # Turning round in a junction passes through 90 deg, maybe slowly:
        # the U-turn stays until the rider actually rides along the line.
        self.assertEqual(run([(0, 180), (1, 180), (2, 180), (3, 180), (4, 100), (5, None), (6, 70), (7, 30)]),
                         [False, False, False, True, True, True, True, False])


# --- nearestSegment with preferContinuity -----------------------------------

WINDOW, MARGIN, KEEP = 300.0, 25.0, 60.0


def nearest_segment(segs, rider, start, continuity=False):
    """Mirror of PolylineMath.nearestSegment on a flat metre grid.
    segs: [((x1, y1), (x2, y2)), ...]."""
    import math
    best_d = near_d = float("inf")
    best_i = near_i = start
    along = 0.0
    for i in range(start, len(segs)):
        (ax, ay), (bx, by) = segs[i]
        dx, dy = bx - ax, by - ay
        t = max(0.0, min(1.0, ((rider[0] - ax) * dx + (rider[1] - ay) * dy) / (dx * dx + dy * dy)))
        d = math.hypot(rider[0] - (ax + t * dx), rider[1] - (ay + t * dy))
        if d < best_d:
            best_d, best_i = d, i
        if continuity and along <= WINDOW:
            if d < near_d:
                near_d, near_i = d, i
            along += math.hypot(dx, dy)
    if continuity and near_i != best_i and near_d <= KEEP and near_d - best_d < MARGIN:
        return near_d, near_i
    return best_d, best_i


# Divided highway turnaround: up carriageway A (x = 0), across, back down B
# (x = 20). 100 m segments.
A = [((0, y), (0, y + 100)) for y in range(0, 1000, 100)]
TURN = [((0, 1000), (20, 1000))]
B = [((20, y), (20, y - 100)) for y in range(1000, 0, -100)]
ROUTE = A + TURN + B


class CursorJump(unittest.TestCase):
    def test_gps_error_towards_far_carriageway(self):
        # Rider on A at y = 450, fix 11 m towards B.
        self.assertGreater(nearest_segment(ROUTE, (11, 450), 4)[1], len(A))   # old: jumps to B
        d, i = nearest_segment(ROUTE, (11, 450), 4, continuity=True)
        self.assertEqual((round(d), i), (11, 4))                              # stays on A

    def test_riding_backwards_keeps_cursor_on_a(self):
        # Wrong way down A next to B: still A, so wrong-way is detected.
        self.assertEqual(nearest_segment(ROUTE, (2, 380), 4, continuity=True)[1], 4)

    def test_forward_progress(self):
        self.assertEqual(nearest_segment(ROUTE, (0, 650), 4, continuity=True)[1], 6)

    def test_lost_near_stretch_jumps_as_before(self):
        # Tunnel exit / cut corner: the near stretch is > 60 m away.
        self.assertEqual(nearest_segment(ROUTE, (90, 450), 0, continuity=True)[1],
                         nearest_segment(ROUTE, (90, 450), 0)[1])

    def test_far_stretch_clearly_closer_jumps(self):
        # Rider really on a later stretch 30 m nearer than the near one.
        far = [((0, 0), (0, 100)), ((0, 100), (300, 100)), ((300, 100), (300, -200)),
               ((300, -200), (40, -200)), ((40, -200), (40, 50))]
        self.assertEqual(nearest_segment(far, (39, 50), 0, continuity=True)[1], 4)


class SwiftWiring(unittest.TestCase):
    def setUp(self):
        self.nav = strip_comments(NAV.read_text(encoding="utf-8"))
        self.loop = strip_comments(LOOP.read_text(encoding="utf-8"))

    def test_mirror_matches_swift(self):
        body = decl_body(self.nav, "static func wrongWaySince(")
        self.assertIn("if delta > 120 { return since ?? t }", body)
        self.assertIn("if delta < 60 || !active { return nil }", body)
        self.assertIn("private let wrongWayDelay: TimeInterval = 3", self.nav)
        upd = decl_body(self.nav, "private func updateWrongWay(")
        self.assertIn("if !isWrongWay { wrongWaySince = nil }", upd)
        self.assertIn("active: isWrongWay", upd)
        poly = strip_comments((ROOT / "PolylineMath.swift").read_text(encoding="utf-8"))
        seg = decl_body(poly, "static func nearestSegment(")
        self.assertIn("if preferContinuity, along <= continuityWindow {", seg)
        self.assertIn("nearDist <= continuityKeepWithin, nearDist - bestDist < continuityJumpMargin", seg)
        for const in ("continuityWindow: CLLocationDistance = 300",
                      "continuityJumpMargin: CLLocationDistance = 25",
                      "continuityKeepWithin: CLLocationDistance = 60"):
            self.assertIn(const, poly)

    def test_ingest_matches_with_course_and_zeroes_distance(self):
        ingest = decl_body(self.nav, "func ingest(fix: Fix)")
        self.assertIn("preferContinuity: true", ingest)
        zero = ingest.index("if isWrongWay { self.distanceToNextStep = 0 }")
        self.assertLess(ingest.rindex("self.distanceToNextStep = remaining"), zero)
        self.assertLess(zero, ingest.index("let nowOff = distFromRoute > offRouteDistanceThreshold"))
        self.assertIn('isWrongWay ? "Make a U-turn" : stepBeforeNext?.instructions', self.nav)

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

    def test_reset_on_every_new_line(self):
        reset = decl_body(self.nav, "private func resetWrongWay(")
        self.assertIn("isWrongWay = false", reset)
        self.assertIn("wrongWaySince = nil", reset)
        for decl in ("func stop()", "private func seed(", "private func installSwappedRoute("):
            self.assertIn("resetWrongWay()", decl_body(self.nav, decl), decl)

    def test_loop_speaks_once_and_hides_lookahead(self):
        self.assertIn("&& !nav.isWrongWay", self.loop)
        voice = decl_body(self.loop, "private func emitVoice(")
        self.assertLess(voice.index("if isRerouting {"), voice.index("if isWrongWay {"))
        branch = voice[voice.index("if isWrongWay {"):]
        latch = branch.index("spokeUTurnForEpisode = true")
        self.assertLess(branch.index("if !spokeUTurnForEpisode,"), latch)
        self.assertLess(latch, branch.index("voice.speak(phrase"))
        # Re-armed only once the rider is no longer wrong-way.
        self.assertLess(branch.index("return"), branch.index("spokeUTurnForEpisode = false"))
        self.assertIn("isWrongWay: nav.isWrongWay", self.loop)


if __name__ == "__main__":
    unittest.main()
