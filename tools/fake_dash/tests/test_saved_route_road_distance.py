"""Editing a saved waypoint route keeps a road distance, not a straight line.

`updatePoints` recomputes `totalDistanceMeters` as the straight-line path
length, so a route saved from the planner (road distance) showed a much
shorter figure after any add / delete / reorder. Every point edit now also
re-routes the legs and stores the road total — unless the points changed again
in the meantime.
"""

from pathlib import Path

from tests.swift_source import decl_body, strip_comments

APP = Path(__file__).resolve().parents[3] / "TripperDashPP"
VIEW = APP / "UI/Navigation/SavedRouteDetailView.swift"
STORE = APP / "Navigation/SavedRoutesStore.swift"


def test_every_point_edit_refreshes_the_road_distance():
    src = strip_comments(VIEW.read_text())
    for fn in ("private func deletePoints", "private func addStop", "private func movePoints"):
        body = decl_body(src, fn)
        assert "store.updatePoints(id: route.id, points: pts)" in body, fn
        assert "refreshRoadDistance(route.id, kind: route.kind, points: pts)" in body, fn


def test_refresh_routes_each_leg_and_only_waypoint_routes():
    body = decl_body(strip_comments(VIEW.read_text()), "private func refreshRoadDistance")
    assert "guard kind == .waypoints" in body          # a track keeps its trace length
    assert "zip(points, points.dropFirst())" in body
    assert "alternates: false" not in body   # planner parity under an avoid filter
    # Superseded edits stop before the next MapKit request.
    assert "guard store.route(id: id)?.points == points else { return }" in body
    assert "guard let leg = opts?.first else { return }" in body   # any failed leg: keep straight line
    assert "store.setRoadDistance(id: id, meters: total, forPoints: points)" in body


def test_store_drops_a_stale_road_distance():
    body = decl_body(strip_comments(STORE.read_text()), "func setRoadDistance")
    assert "routes[idx].points == points" in body
