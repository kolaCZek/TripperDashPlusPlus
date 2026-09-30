"""A saved waypoint route can gain stops, not just lose them.

The detail view offered delete + reorder only, so a rider who wanted one more
stop had to rebuild the route in the planner. "Add stop" opens the place
search and inserts the pick just before the end point.
"""

from pathlib import Path

from tests.swift_source import decl_body, strip_comments

SRC = Path(__file__).resolve().parents[3] / "TripperDashPP/UI/Navigation/SavedRouteDetailView.swift"


def test_add_stop_inserts_before_the_end_and_persists():
    src = strip_comments(SRC.read_text())
    body = decl_body(src, "private func addStop")
    assert "at: max(pts.count - 1, 0)" in body          # before the finish, never after it
    assert "store.updatePoints(id: route.id, points: pts)" in body


def test_add_stop_is_offered_for_waypoint_routes_only():
    src = strip_comments(SRC.read_text())
    section = decl_body(src, "private func editablePointsSection")
    assert "route.kind == .waypoints && route.points.count < RoutePoint.editableListThreshold" in section
    assert "showAddStop = true" in section
    assert "DestinationSearchSheet(onPick: { dest in addStop(dest) })" in src
