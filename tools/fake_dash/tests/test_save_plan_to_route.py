"""
Save a route straight from the planner (Martin, 2026-09-29):

    "moznost ulozit trasu primo z planovace. Abych si mohl doma
     naplanovat, ulozit a u motorky jen spustit navigaci na ulozenou
     trasu."
    ("save a route straight from the planner, so I can plan it at home,
     save it, and at the bike just start navigation on the saved route.")

Contract pinned here, without Xcode:

  - `SavedRoute.fromPlan` keeps EVERY point in order (Martin: "chci tam
    vsechny body vcetne aktualni polohy"), the live-GPS origin included —
    as a fixed point at the latest fix, named by reverse geocode
    (coordinates offline, never "Current location"). The rider removes it
    from the plan if they don't want it.
  - At start the live position is prepended as the routing origin and the
    first point is skipped when the rider is within 300 m of it, so a loop
    saved at home and started at home rides the loop, not "arrived at
    stop 1". Without a live fix nothing is skipped.
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
  - The toolbar button builds the route (`AppStatus.draftPlanSave`), asks
    for a name in a "Save route" alert (Cancel / Save, prefilled with the
    name it was saved under before, else `First → Last`), and stores it
    via `commitPlanSave` → `SavedRoutesStore.save` (blank → automatic).
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
STORE = REPO / "TripperDashPP" / "Navigation" / "SavedRoutesStore.swift"


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


def from_plan(waypoints: list[Waypoint], road_distance: float | None,
              here: tuple[float, float] | None = None, here_name: str | None = None):
    """Mirror of `SavedRoute.fromPlan`."""
    if all(w.is_current_location for w in waypoints):
        return None
    points = []
    for w in waypoints:
        if w.is_current_location:
            lat, lon = here or (w.lat, w.lon)
            points.append((lat, lon, here_name or None))
        else:
            points.append((w.lat, w.lon, w.name or None))
    name = _label(points[0]) if len(points) == 1 else f"{_label(points[0])} → {_label(points[-1])}"
    dist = road_distance
    if dist is None:
        dist = sum(_haversine(points[i][:2], points[i + 1][:2]) for i in range(len(points) - 1))
    return {"name": name, "kind": "waypoints", "points": points, "distance": dist}


START_SKIP_M = 300.0   # RouteStartPlanner.promptThresholdMeters


def begin_from_saved(route, rider: tuple[float, float]) -> list[Waypoint]:
    """Mirror of `beginPlanningFromSavedRoute(.fromFirst)` for `.waypoints`
    (no reduction; reached first point dropped; live origin prepended)."""
    assert route["kind"] == "waypoints"
    pts = route["points"]
    if len(pts) > 1 and _haversine(rider, pts[0][:2]) <= START_SKIP_M:
        pts = pts[1:]
    origin = Waypoint("Current location", rider[0], rider[1], is_current_location=True)
    return [origin] + [Waypoint(n or "", la, lo) for la, lo, n in pts]


HOME = Waypoint("Current location", 50.2385, 14.2011, is_current_location=True)
MELNIK = Waypoint("Mělník", 50.3505, 14.4741)
KOKORIN = Waypoint("Kokořín", 50.4330, 14.5780)
MACHA = Waypoint("Doksy", 50.5647, 14.6550)


# ────────────────────────────── mirror ───────────────────────────────


def test_every_point_is_kept_origin_as_a_named_fixed_point():
    fix = (50.2390, 14.2020)
    r = from_plan([HOME, MELNIK, KOKORIN, MACHA], road_distance=92_000, here=fix, here_name="Zvoleněves")
    assert [p[2] for p in r["points"]] == ["Zvoleněves", "Mělník", "Kokořín", "Doksy"]
    assert r["points"][0][:2] == fix          # latest fix, not the stale snapshot
    assert r["kind"] == "waypoints"
    assert r["name"] == "Zvoleněves → Doksy"
    assert r["distance"] == 92_000


def test_ungeocoded_origin_falls_back_to_coordinates():
    r = from_plan([HOME, KOKORIN], road_distance=None)
    assert r["points"][0] == (HOME.lat, HOME.lon, None)
    assert r["name"] == "50.2385, 14.2011 → Kokořín"


def test_single_destination_is_named_after_it():
    r = from_plan([KOKORIN], road_distance=None)       # origin removed by the rider
    assert r["name"] == "Kokořín"
    assert r["distance"] == 0  # one point: no straight-line length


def test_uncomputed_plan_falls_back_to_straight_line_length():
    r = from_plan([MELNIK, KOKORIN], road_distance=None)
    assert 10_000 < r["distance"] < 12_000  # Mělník–Kokořín ≈ 11.6 km as the crow flies


def test_plan_with_only_the_live_origin_saves_nothing():
    assert from_plan([HOME], road_distance=None) is None


def test_round_trip_plan_at_home_start_at_the_bike():
    planned = [HOME, MELNIK, KOKORIN, MACHA]
    saved = from_plan(planned, road_distance=None, here=(HOME.lat, HOME.lon), here_name="Zvoleněves")
    bike = (50.2410, 14.2060)  # a few streets away (>300 m)
    near = (50.2390, 14.2020)  # ~80 m: at the bike in the drive
    started = begin_from_saved(saved, near)
    assert started[0].is_current_location and (started[0].lat, started[0].lon) == near
    assert started[1:] == planned[1:]      # home skipped: already there
    assert sum(w.is_current_location for w in started) == 1
    # Further than 300 m from home → home is a real first stop again.
    assert _haversine(bike, (HOME.lat, HOME.lon)) > START_SKIP_M
    assert [w.name for w in begin_from_saved(saved, bike)[1:]] == ["Zvoleněves", "Mělník", "Kokořín", "Doksy"]


# ───────────────────────── Swift drift guards ────────────────────────


def _from_plan_body() -> str:
    return strip_comments(decl_body(SAVED_ROUTE.read_text(), "static func fromPlan"))


def test_swift_from_plan_keeps_live_origin():
    body = _from_plan_body()
    assert "!$0.isCurrentLocation }" not in body.replace("contains(where: { !$0.isCurrentLocation })", "")
    assert "waypoints.map { wp in" in body
    assert "wp.isCurrentLocation ? (currentLocation ?? wp.coordinate) : wp.coordinate" in body
    save = strip_comments(decl_body(APPSTATUS.read_text(), "func draftPlanSave"))
    assert "locationService.lastFix?.coordinate ?? origin.coordinate" in save
    assert "reverseGeocodeLocation" in save
    # Review 3 of #151: Start/Cancel during the geocode must not drop the save.
    assert "plannedRoute === plan" not in save


def test_swift_from_plan_saves_waypoints_kind_not_track():
    body = _from_plan_body()
    assert "kind: .waypoints" in body
    assert ".track" not in body


def test_swift_from_plan_keeps_stop_names():
    assert "name.isEmpty ? nil : name" in _from_plan_body()


def test_swift_saved_waypoints_route_is_not_reduced_on_start():
    # The round-trip mirror assumes `.waypoints` skips Douglas–Peucker.
    body = strip_comments(decl_body(APPSTATUS.read_text(), "func beginPlanningFromSavedRoute"))
    assert "route.kind == .track" in body and "GPXGeometry.reduce" in body


def test_empty_stop_name_falls_back_to_coordinates():
    r = from_plan([Waypoint("", 50.4330, 14.5780)], road_distance=None)
    assert r["name"] == "50.4330, 14.5780"
    assert r["points"][0][2] is None


def test_swift_save_current_plan_skips_library_plans_and_overwrites_on_resave():
    body = strip_comments(decl_body(APPSTATUS.read_text(), "func draftPlanSave"))
    assert "!plan.isFromLibrary" in body
    assert "!plan.isTrack" not in body, "a .waypoints plan from the library must be hidden too"
    assert "SavedRoute.fromPlan" in body
    # Suggest the name it was saved under (renamed in the library too).
    assert "$0.id == plan.savedRouteId" in body and "previous?.name ?? route.name" in body
    commit = strip_comments(decl_body(APPSTATUS.read_text(), "func commitPlanSave"))
    assert "savedRoutesStore.save(route, named: name, replacing: plan.savedRouteId)" in commit
    assert "plan.savedRouteId = saved.id" in commit
    store = strip_comments(decl_body(STORE.read_text(), "func save(_ route: SavedRoute, named"))
    assert "if !trimmed.isEmpty { route.name = trimmed }" in store
    assert store.index("replace(id: id, with: route)") < store.index("add(route)")


def test_swift_every_library_start_is_flagged():
    body = strip_comments(decl_body(APPSTATUS.read_text(), "func beginPlanningFromSavedRoute"))
    assert "plan.isFromLibrary = true" in body


def test_swift_from_plan_empty_names_fall_back():
    body = _from_plan_body()
    assert "name.isEmpty ? nil : name" in body
    assert "label(for: points.first)" in body and "label(for: points.last)" in body


def test_swift_planner_toolbar_has_save_button():
    body = strip_comments(decl_body(PICKER.read_text(), "private func planningBody"))
    assert "await status.draftPlanSave()" in body
    assert "showPlanSaveAlert = true" in body
    assert ".disabled(saved || savingPlan)" in body, "no double save while geocoding"
    # The name prompt hangs on the root view, so a Start/Cancel during the
    # geocode (planner gone) still gets it; Cancel saves nothing.
    root = strip_comments(decl_body(PICKER.read_text(), "var body: some View"))
    alert = root[root.index('.alert("Save route"'):]
    alert = alert[:alert.index(".confirmationDialog(")]
    assert 'TextField("Route name", text: $planSaveName)' in alert
    assert 'Button("Cancel", role: .cancel) {}' in alert
    assert "status.commitPlanSave(draft.route, named: planSaveName, for: draft.plan)" in alert
    assert "savedPlanStops = Self.stopsSnapshot(draft.plan)" in alert
    assert "if !plan.isFromLibrary {" in body
    snap = strip_comments(decl_body(PICKER.read_text(), "private static func stopsSnapshot"))
    assert "$0.name" in snap, "a pin renamed by reverse geocoding must re-arm the button"
