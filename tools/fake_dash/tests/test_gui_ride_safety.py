"""
Drift guards for the GUI ride-safety fixes (audit of main 6b73ac3).

SwiftUI wiring can't be unit-tested without Xcode, so each test pins the
specific fixed code shape in the Swift source:

  - H1  the 4 s arrival auto-dismiss is a held, cancellable Task, cancelled
        by stopNavigation(), so Stop inside the window can't start a free ride
  - H2  the tile-download cover can be dismissed, and stopNavigation()
        clears it
  - M5  the bike in use can't be swipe-deleted
  - M7  orphaned Live Activities are ended at app launch
  - L1  the error banner no longer promises a tap action it doesn't have
  - L2  the route-preferences button has a VoiceOver label
  - L3  the Settings footer no longer claims light/dark tiles cache apart
"""

from __future__ import annotations

from pathlib import Path

from tests.swift_source import decl_body, strip_comments

APP = Path(__file__).resolve().parents[3] / "TripperDashPP"


def _src(rel: str) -> str:
    return strip_comments((APP / rel).read_text(encoding="utf-8"))


def _picker() -> str:
    return _src("UI/MapPickerView.swift")


def test_arrival_dismiss_is_cancelled_by_stop_navigation():
    src = _picker()
    nav = decl_body(src, "private var navigatingBody")
    assert "arrivalTask = Task" in nav, "arrival auto-dismiss Task must be held"
    sleep = nav.index("Task.sleep(for: .seconds(4))")
    guard = nav.index("guard !Task.isCancelled else { return }")
    assert sleep < guard < nav.index("await finishArrival()")
    stop = decl_body(src, "private func stopNavigation(")
    assert "arrivalTask?.cancel()" in stop


def test_prerender_cover_is_dismissable_and_cleared_on_stop():
    stop = decl_body(_picker(), "private func stopNavigation(")
    assert "prerenderActive = false" in stop
    cover = decl_body(_src("UI/Navigation/PrerenderProgressView.swift"),
                      "var body: some View")
    assert 'Button("Continue") { dismiss() }' in cover


def test_active_bike_cannot_be_deleted():
    body = decl_body(_src("UI/StreamingView.swift"), "var body: some View")
    row = body.index("bikeRow(bike)")
    assert body.index(".deleteDisabled(!isEditableState)", row) < body.index(".onDelete", row)


def test_orphaned_live_activities_ended_at_launch():
    app = _src("App/TripperDashPPApp.swift")
    assert "LiveActivityController.endOrphanedActivities()" in decl_body(app, "init()")
    ctl = decl_body(_src("LiveActivity/LiveActivityController.swift"),
                    "static func endOrphanedActivities()")
    assert "Activity<RideActivityAttributes>.activities" in ctl
    assert "dismissalPolicy: .immediate" in ctl


def test_error_banner_does_not_promise_tap_to_retry():
    banner = decl_body(_picker(), "private var label: String")
    assert "tap to retry" not in banner
    assert '"Connection failed"' in banner


def test_route_preferences_button_has_accessibility_label():
    src = _picker()
    icon = src.index('Image(systemName: "slider.horizontal.3")')
    assert src.index('.accessibilityLabel("Route preferences")', icon) - icon < 120


def test_settings_footer_does_not_claim_separate_tile_caches():
    assert "cached separately" not in _src("UI/StreamingView.swift")
