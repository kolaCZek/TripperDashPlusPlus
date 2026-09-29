"""
Save a route straight from the planner (Martin, 2026-09-29):

    "moznost ulozit trasu primo z planovace. Abych si mohl doma
     naplanovat, ulozit a u motorky jen spustit navigaci na ulozenou
     trasu."
    ("save a route straight from the planner, so I can plan it at home,
     save it, and at the bike just start navigation on the saved route.")

Contract pinned here, without Xcode:

  - `SavedRoute.fromPlan` keeps the rider's stops in order, with their
    names, and DROPS the live-GPS origin: `beginPlanningFromSavedRoute`
    re-prepends wherever the rider is at start time. Storing the home
    origin would route the rider back home first.
  - Saved as `.waypoints`, so starting it never runs Douglas–Peucker (a
    `.track` would be reduced and its stops presented as shape).
  - ROUND TRIP: plan at home → save → start at the bike gives a plan whose
    stops equal the planned stops, with the bike's position as origin.
  - A plan launched from Saved routes (ANY kind) is not offered for
    saving — the copy would be degraded (review of #151).
  - Saving the same plan again overwrites its entry (no duplicates); the
    "saved" state includes stop names, so a pin that gets its
    reverse-geocoded name re-arms the button.
  - An empty stop name falls back to coordinates (no " → X" names).
  - A round trip started at its destination never offers "start from
    the nearest point" (it would arrive instantly).
  - The toolbar button routes through `AppStatus.saveCurrentPlan`.
  The Swift itself is covered by `SavedRouteFromPlanTests.swift`.
"""

from __future__ import annotations

import math
from dataclasses import dataclass
from pathlib import Path

from tests.swift_source import decl_body, strip_comments

REPO = Path(__file__).resolve().parents[3]
SAVED_ROUTE = REPO / "TripperDashPP" / "Navigation" / "Models" / "SavedRoute.swift"
APPSTATUS = REPO / "TripperDashPP" / "App" / "AppStatus.swift"
PICKER = REPO / "TripperDashPP" / "UI" / "MapPickerView.swift"


# ─────────────────────────── Python mirror ───────────────────────────


@dataclass(frozen=True)
class Waypoint:
    name: str
    lat: float
    lon: float
    is_current_location: bool = False


def _haversine(a, b) -> float:
    r = 6_371_000.0
    p1, p2 = math.radians(a[0]), math.radians(b[0])
    dp, dl = p2 - p1, math.radians(b[1] - a[1])
    h = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * r * math.asin(math.sqrt(h))


def _label(p) -> str:
    return p[2] if p[2] else f"{p[0]:.4f}, {p[1]:.4f}"


def from_plan(waypoints: list[Waypoint], road_distance: float | None):
    """Mirror of `SavedRoute.fromPlan`."""
    stops = [w for w in waypoints if not w.is_current_location]
    if not stops:
        return None
    points = [(w.lat, w.lon, w.name or None) for w in stops]
    name = _label(points[0]) if len(points) == 1 else f"{_label(points[0])} → {_label(points[-1])}"
    dist = road_distance
    if dist is None:
        dist = sum(_haversine(points[i][:2], points[i + 1][:2]) for i in range(len(points) - 1))
    return {"name": name, "kind": "waypoints", "points": points, "distance": dist}


def begin_from_saved(route, rider: tuple[float, float]) -> list[Waypoint]:
    """Mirror of `beginPlanningFromSavedRoute(.fromFirst)` for `.waypoints`
    (no reduction; live origin prepended)."""
    assert route["kind"] == "waypoints"
    origin = Waypoint("Current location", rider[0], rider[1], is_current_location=True)
    return [origin] + [Waypoint(n, la, lo) for la, lo, n in route["points"]]


HOME = Waypoint("Current location", 50.2385, 14.2011, is_current_location=True)
MELNIK = Waypoint("Mělník", 50.3505, 14.4741)
KOKORIN = Waypoint("Kokořín", 50.4330, 14.5780)
MACHA = Waypoint("Doksy", 50.5647, 14.6550)


# ────────────────────────────── mirror ───────────────────────────────


def test_origin_is_dropped_and_stops_kept_in_order():
    r = from_plan([HOME, MELNIK, KOKORIN, MACHA], road_distance=92_000)
    assert [p[2] for p in r["points"]] == ["Mělník", "Kokořín", "Doksy"]
    assert r["kind"] == "waypoints"
    assert r["name"] == "Mělník → Doksy"
    assert r["distance"] == 92_000


def test_single_destination_is_named_after_it():
    r = from_plan([HOME, KOKORIN], road_distance=None)
    assert r["name"] == "Kokořín"
    assert r["distance"] == 0  # one point: no straight-line length


def test_uncomputed_plan_falls_back_to_straight_line_length():
    r = from_plan([HOME, MELNIK, KOKORIN], road_distance=None)
    assert 10_000 < r["distance"] < 12_000  # Mělník–Kokořín ≈ 11.6 km as the crow flies


def test_plan_with_only_the_live_origin_saves_nothing():
    assert from_plan([HOME], road_distance=None) is None


def test_round_trip_plan_at_home_start_at_the_bike():
    planned = [HOME, MELNIK, KOKORIN, MACHA]
    saved = from_plan(planned, road_distance=None)
    bike = (50.2400, 14.2050)  # a street away from home
    started = begin_from_saved(saved, bike)
    assert started[0].is_current_location and (started[0].lat, started[0].lon) == bike
    assert started[1:] == planned[1:]
    # The home origin never comes back as a stop.
    assert sum(w.is_current_location for w in started) == 1


# ───────────────────────── Swift drift guards ────────────────────────


def _from_plan_body() -> str:
    return strip_comments(decl_body(SAVED_ROUTE.read_text(), "static func fromPlan"))


def test_swift_from_plan_drops_live_origin():
    body = _from_plan_body()
    assert "!$0.isCurrentLocation" in body


def test_swift_from_plan_saves_waypoints_kind_not_track():
    body = _from_plan_body()
    assert "kind: .waypoints" in body
    assert ".track" not in body


def test_swift_from_plan_keeps_stop_names():
    assert "$0.name.isEmpty ? nil : $0.name" in _from_plan_body()


def test_swift_saved_waypoints_route_is_not_reduced_on_start():
    # The round-trip mirror assumes `.waypoints` skips Douglas–Peucker.
    body = strip_comments(decl_body(APPSTATUS.read_text(), "func beginPlanningFromSavedRoute"))
    assert "route.kind == .track" in body and "GPXGeometry.reduce" in body


def test_empty_stop_name_falls_back_to_coordinates():
    r = from_plan([HOME, Waypoint("", 50.4330, 14.5780)], road_distance=None)
    assert r["name"] == "50.4330, 14.5780"
    assert r["points"][0][2] is None


def test_swift_save_current_plan_skips_library_plans_and_overwrites_on_resave():
    body = strip_comments(decl_body(APPSTATUS.read_text(), "func saveCurrentPlan"))
    assert "!plan.isFromLibrary" in body
    assert "!plan.isTrack" not in body, "a .waypoints plan from the library must be hidden too"
    assert "SavedRoute.fromPlan" in body
    assert "savedRoutesStore.replace(id: id, with: route)" in body
    assert body.index("savedRoutesStore.replace(") < body.index("savedRoutesStore.add(")
    assert "plan.savedRouteId = saved.id" in body


def test_swift_every_library_start_is_flagged():
    body = strip_comments(decl_body(APPSTATUS.read_text(), "func beginPlanningFromSavedRoute"))
    assert "plan.isFromLibrary = true" in body


def test_swift_from_plan_empty_names_fall_back():
    body = _from_plan_body()
    assert "$0.name.isEmpty ? nil : $0.name" in body
    assert "label(for: points.first)" in body and "label(for: points.last)" in body


def test_swift_planner_toolbar_has_save_button():
    body = strip_comments(decl_body(PICKER.read_text(), "private func planningBody"))
    assert "status.saveCurrentPlan()" in body
    assert "if !plan.isFromLibrary {" in body
    assert "savedPlanStops = Self.stopsSnapshot(plan)" in body
    snap = strip_comments(decl_body(PICKER.read_text(), "private static func stopsSnapshot"))
    assert "$0.name" in snap, "a pin renamed by reverse geocoding must re-arm the button"
