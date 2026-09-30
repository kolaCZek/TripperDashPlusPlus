"""
Edit the route while navigation is running (feat/edit-route-mid-ride).

The rider removes, reorders or adds stops — or changes the destination —
from an "Edit route" button in the navigation HUD, without ending the ride.
Contract pinned here, without Xcode:

  - The HUD offers "Edit route" only for an editable plan (not a track, not
    past `RoutePoint.editableListThreshold`).
  - The sheet's flag is in `MapPickerView.anotherModalUp`, and arrival
    closes the sheet.
  - Apply routes the edited stops from the live position and installs them
    with `ActiveNavigator.replacePlan` — never `stopNavigation`,
    `stopStreaming` or `start(plan:)`, which would end the ride (reset stats,
    breadcrumb, `hasBeenUnderway`) or blink the dash.
  - `replacePlan` re-seeds from leg 0 and fires `onActiveRouteChanged` (so
    polyline, tiles, full-route line, cameras and limits follow like after a
    reroute), recomputes the progress baseline, and keeps `isNavigating`
    and the ride-level state.
  The pure Swift helpers are covered by `EditRouteMidRideTests` in
  `SavedRouteFromPlanTests.swift`.
"""

from __future__ import annotations

from pathlib import Path

from tests.swift_source import decl_body, strip_comments

REPO = Path(__file__).resolve().parents[3]
APP = REPO / "TripperDashPP"
HUD = APP / "UI" / "Navigation" / "NavigationHUD.swift"
PICKER = APP / "UI" / "MapPickerView.swift"
SHEET = APP / "UI" / "Navigation" / "EditRouteSheet.swift"
NAV = APP / "Navigation" / "ActiveNavigator.swift"
PLAN = APP / "Navigation" / "Models" / "PlannedRoute.swift"
PBXPROJ = APP / "TripperDashPP.xcodeproj" / "project.pbxproj"


def _src(path: Path) -> str:
    return strip_comments(path.read_text())


def test_hud_has_edit_route_entry_for_editable_plans_only():
    hud = _src(HUD)
    assert "var onEditRoute: (() -> Void)?" in hud
    body = decl_body(hud, "var body: some View")
    assert '"Edit route"' in body
    assert "if let onEditRoute, nav.plan?.isEditableMidRide == true" in body
    # Only under the not-arrived branch.
    assert body.index("arrivedCard") < body.index('"Edit route"')
    gate = decl_body(_src(PLAN), "var isEditableMidRide")
    assert "!isTrack" in gate
    assert "waypoints.count <= RoutePoint.editableListThreshold" in gate


def test_picker_wires_the_sheet_and_counts_it_as_a_modal():
    picker = _src(PICKER)
    modal = decl_body(picker, "private var anotherModalUp")
    assert "showEditRoute" in modal
    nav_body = decl_body(picker, "private var navigatingBody")
    assert "onEditRoute: { showEditRoute = true }" in nav_body
    assert ".sheet(isPresented: $showEditRoute)" in nav_body
    assert "EditRouteSheet()" in nav_body
    on_arrived = nav_body[nav_body.index(".onChange(of: status.activeNavigator.hasArrived)"):]
    assert on_arrived.index("showEditRoute = false") < on_arrived.index("finishArrival()")


def test_sheet_file_is_in_the_app_target():
    pbx = PBXPROJ.read_text()
    assert pbx.count("EditRouteSheet.swift in Sources */ = {isa = PBXBuildFile;") == 1
    assert pbx.count("path = EditRouteSheet.swift;") == 1
    assert pbx.count("/* EditRouteSheet.swift */,") == 1          # group child
    assert pbx.count("/* EditRouteSheet.swift in Sources */,") == 1  # Sources phase


def test_apply_installs_via_replace_plan_and_never_ends_the_ride():
    sheet = _src(SHEET)
    apply = decl_body(sheet, "private func apply()")
    assert "nav.replacePlan(newPlan)" in apply
    assert "status.routingService.recompute(" in apply
    assert "PlannedRoute.replacementWaypoints(currentLocation:" in apply
    for forbidden in ("stopNavigation", "stopStreaming", "start(plan:", ".stop()"):
        assert forbidden not in sheet, f"the editor must not call {forbidden}"
    # Stale edit (a stop reached or skipped while editing) reloads the
    # draft, before AND after the routing await; a failure keeps the old
    # route.
    assert apply.count("guard !isStale else {\n            reloadDraft()") == 1
    assert apply.count("guard !isStale else {\n                reloadDraft()") == 1
    # Round 2: Apply is capped like a reroute.
    assert "timeout: ActiveNavigator.routeRequestTimeout," in apply
    assert apply.index("try await status.routingService.recompute(") < apply.index("nav.replacePlan(newPlan)")
    catch = apply[apply.index("} catch {"):]
    assert "return" in catch[: catch.index("guard !closed")]
    # A stop passed during a failed Apply reloads the list right away.
    failed = catch[: catch.index("return")]
    assert "if !closed, isStale { reloadDraft() }" in failed
    assert failed.index("reloadDraft()") < failed.index("errorText = reason")
    # Arrival / ride end while the sheet is up drops the edit.
    body = decl_body(sheet, "var body: some View")
    assert ".onChange(of: status.activeNavigator.hasArrived)" in body
    assert ".onChange(of: status.activeNavigator.isNavigating)" in body


def test_replace_plan_reseeds_fires_hook_and_keeps_the_ride():
    nav = _src(NAV)
    body = decl_body(nav, "func replacePlan(_ newPlan: PlannedRoute) async -> Bool")
    assert "guard isNavigating" in body
    assert "self.currentLegIndex = 0" in body
    assert "seed(route: route, destination: destWp.asDestination)" in body
    # Round 2: the progress bar keeps the distance already ridden — read
    # against the OLD plan, before it is swapped.
    assert "setProgressBaseline(plan: newPlan, fromLegIndex: 0, alreadyCovered: covered)" in body
    covered = "let covered = plannedTotalDistance - finalDestinationRemainingDistance"
    assert covered in body
    assert body.index(covered) < body.index("self.plan = newPlan")
    assert "routeRecalculations += 1" in body
    assert body.index("seed(route:") < body.index("await onActiveRouteChanged?(route)")
    # Ride-level state a mid-ride swap must keep.
    for kept in ("isNavigating =", "hasBeenUnderway", "traveledCoordinates",
                 "rideStartCoordinate", "hasArrived =", "stop()"):
        assert kept not in body, f"replacePlan must not touch {kept}"
    # `start(plan:)` keeps its baseline through the shared helper.
    start = decl_body(nav, "func start(plan: PlannedRoute, fromLegIndex: Int = 0)")
    assert "setProgressBaseline(plan: plan, fromLegIndex: self.currentLegIndex, alreadyCovered: 0)" in start
    helper = decl_body(nav, "private func setProgressBaseline")
    assert "Self.progressBaseline(alreadyCovered: alreadyCovered, legDistances: legDistances)" in helper
    assert "self.plannedTotalDistance = baseline.total" in helper
    assert "self.plannedWaypointFractions = baseline.fractions" in helper


def test_sheet_reloads_when_the_route_moves_on_instead_of_refusing():
    sheet = _src(SHEET)
    body = decl_body(sheet, "var body: some View")
    assert ".onChange(of: status.activeNavigator.currentLegIndex) { _, _ in reloadIfStale() }" in body
    assert ".onChange(of: status.activeNavigator.plan.map { ObjectIdentifier($0) }) { _, _ in reloadIfStale() }" in body
    reload_if = decl_body(sheet, "private func reloadIfStale()")
    # Not mid-Apply (the post-await check owns that) nor after our own swap.
    assert "guard !applying, !closed, draft != nil, isStale else { return }" in reload_if
    reload = decl_body(sheet, "private func reloadDraft()")
    assert reload.index("draft = nil") < reload.index("\n        loadDraft()")
    assert "noticeText = Self.reloadedNotice" in reload
    assert "The route moved on" in sheet
    assert "You reached a stop while editing" not in sheet
    assert "staleMessage" not in sheet
    apply = decl_body(sheet, "private func apply()")
    swap = apply[apply.index("if await nav.replacePlan(newPlan) {"):]
    assert swap.index("closed = true") < swap.index("dismiss()")


def test_recompute_threads_the_timeout_and_the_planner_keeps_none():
    routing = _src(APP / "Navigation" / "RoutingService.swift")
    sig = routing[routing.index("func recompute(_ plan: PlannedRoute,"):]
    sig = sig[: sig.index("{")]
    assert "timeout: TimeInterval? = nil," in sig
    body = decl_body(routing, "func recompute(_ plan: PlannedRoute,")
    assert "timeout: timeout)" in body
    # A timeout fails the rest at once: one wait, not one per leg.
    timed = body[body.index("} catch RoutingError.timedOut {"):]
    timed = timed[: timed.index("} catch {")]
    assert "failed += dirty.drop(while: { $0 != i })" in timed
    assert "break" in timed
    planner = decl_body(_src(APP / "App" / "AppStatus.swift"), "func recomputeDirtyLegs")
    assert "timeout:" not in planner


def test_live_activity_retitles_after_a_destination_edit():
    attrs = _src(APP / "LiveActivity" / "RideActivityAttributes.swift")
    state = decl_body(attrs, "public struct ContentState: Codable, Hashable")
    assert "var destinationName: String?" in state
    # The immutable attribute stays, after the ContentState block.
    assert "var destinationName: String?" in attrs[attrs.index(state) + len(state):]
    ctrl = _src(APP / "LiveActivity" / "LiveActivityController.swift")
    push = decl_body(ctrl, "nonisolated static func shouldPush(")
    assert "if old.destinationName != new.destinationName { return true }" in push
    update = decl_body(ctrl, "func update(")
    assert "destinationName: destinationName" in update
    loop = _src(APP / "Navigation" / "ActiveNavLoop.swift")
    assert "destinationName: nav.editedDestinationName," in loop
    widget = _src(APP / "TripperDashWidgets" / "RideLiveActivity.swift")
    fallback = "context.state.destinationName ?? context.attributes.destinationName"
    assert widget.count(fallback) == 2
    assert widget.count("context.attributes.destinationName") == 2   # no bare use left
    nav = _src(NAV)
    replace = decl_body(nav, "func replacePlan(_ newPlan: PlannedRoute) async -> Bool")
    retitle = "self.editedDestinationName = newFinal.name"
    assert retitle in replace
    # Compared against the OLD final stop, so an unchanged one keeps the title.
    assert replace.index(retitle) < replace.index("self.plan = newPlan")
    start = decl_body(nav, "func start(plan: PlannedRoute, fromLegIndex: Int = 0)")
    assert "self.editedDestinationName = nil" in start
