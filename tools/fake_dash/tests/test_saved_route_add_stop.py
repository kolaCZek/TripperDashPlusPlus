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
    assert "dest.name.isEmpty ? nil : dest.name" in body  # blank name -> nil, like SavedRoute.fromPlan


def test_add_stop_is_offered_for_waypoint_routes_only():
    src = strip_comments(SRC.read_text())
    section = decl_body(src, "private func editablePointsSection")
    # `- 1` leaves room for the live origin that starting navigation prepends.
    assert "route.kind == .waypoints && route.points.count < RoutePoint.editableListThreshold - 1" in section
    assert "showAddStop = true" in section
    assert "DestinationSearchSheet(onPick: { dest in addStop(dest) })" in src
