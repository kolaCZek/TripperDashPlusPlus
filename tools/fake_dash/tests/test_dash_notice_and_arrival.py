"""
Guard for the universal dash-notice overlay + "free ride after arrival"
behaviour, wired in:

  - TripperDashPP/Map/DashNotice.swift
    (DashNotice model + DashNoticeLevel: info / warning / critical)
  - TripperDashPP/Map/MapViewSource.swift
    (`showNotice(_:)` entry point, `activeNotice` state with time-based
     expiry, `drawNotice` / `drawNoticeGlyph` render path)
  - TripperDashPP/UI/MapPickerView.swift
    (`finishArrival` drops into `startFreeRide()` + raises a "You've arrived"
     info notice — now STANDARD behaviour, no opt-out setting)

Rider feedback (8/2026): after arriving, the dash sat on the blank nav-logo
screen. Fix: keep the live map up via free-ride AND show a centred "You've
arrived" notice for a few seconds. The notice primitive is generic so any
part of the app can surface info/warning/critical messages on the dash.

Static-source guard (no Xcode / MapKit in CI): parse the Swift sources and
assert the wiring is present and correctly gated.
"""

from __future__ import annotations

import re
from pathlib import Path


def _repo_root() -> Path:
    return Path(__file__).resolve().parents[3]


def _read(rel: str) -> str:
    return (_repo_root() / rel).read_text(encoding="utf-8")


def _map_source_src() -> str:
    return _read("TripperDashPP/Map/MapViewSource.swift")


def _map_picker_src() -> str:
    return _read("TripperDashPP/UI/MapPickerView.swift")


def _finish_arrival_body() -> str:
    src = _map_picker_src()
    start = src.index("private func finishArrival()")
    nxt = src.index("private func ", start + 10)
    body = src[start:nxt]
    # Strip // comment tails so prose doesn't get mistaken for code.
    return "\n".join(re.sub(r"//.*$", "", line) for line in body.splitlines())


# --- DashNotice model -------------------------------------------------------


def test_notice_model_has_three_levels():
    src = _read("TripperDashPP/Map/DashNotice.swift")
    for level in ("case info", "case warning", "case critical"):
        assert level in src, f"DashNoticeLevel missing {level!r}"
    assert "struct DashNotice" in src
    # Each level must define an accent colour.
    assert "var accent: CGColor" in src


# --- MapViewSource wiring ---------------------------------------------------


def test_show_notice_entry_point_exists():
    src = _map_source_src()
    assert "func showNotice(_ notice: DashNotice?)" in src, (
        "MapViewSource must expose showNotice(_:) as the universal entry point"
    )


def test_notice_is_drawn_in_composite_path():
    """drawNotice must be called in the frame composite, AFTER the map/pill
    overlays so it sits on top."""
    src = _map_source_src()
    assert "drawNotice(into: ctx)" in src, "composite path must call drawNotice"
    # Ordering: drawNotice must come after drawProgressBar (drawn last of the
    # map overlays) so the notice is on top.
    prog = src.index("drawProgressBar(into: ctx)\n\n        // Centred dash notice")
    assert prog != -1, "drawNotice must be sequenced right after drawProgressBar"


def test_notice_auto_expires():
    """The notice must self-clear on expiry (time-based, no timer)."""
    src = _map_source_src()
    # showNotice stamps an expiry; drawNotice clears once past it.
    assert "expiresAt" in src
    assert "activeNotice = nil" in src


def test_notice_duration_is_clamped():
    src = _map_source_src()
    assert re.search(r"max\(1, min\(15, notice\.duration\)\)", src), (
        "showNotice must clamp duration to a sane band"
    )


# --- Arrival wiring ---------------------------------------------------------


def test_finish_arrival_starts_free_ride_unconditionally():
    """Free-ride after arrival is now STANDARD — gated only on the dash link
    being up, NOT on any setting."""
    body = _finish_arrival_body()
    assert "startFreeRide()" in body
    assert ".connected" in body
    # The removed opt-out setting must not reappear.
    assert "resumeFreeRideAfterArrival" not in body, (
        "free-ride after arrival is standard now — no opt-out setting"
    )


def test_finish_arrival_shows_arrived_notice():
    body = _finish_arrival_body()
    assert "showNotice(" in body, "arrival must raise a dash notice"
    assert "arrived" in body.lower(), "the notice should say the rider arrived"
    assert ".info" in body, "arrival notice should be info level"


def test_setting_fully_removed():
    """The reverted opt-out setting must be gone from the settings model+UI."""
    assert "resumeFreeRideAfterArrival" not in _read(
        "TripperDashPP/Navigation/Models/DashNavSettings.swift"
    )
    assert "resumeFreeRideAfterArrival" not in _read(
        "TripperDashPP/UI/StreamingView.swift"
    )
    # Store key must be back to v11 (never shipped v12).
    assert 'storeKey = "dashNavSettings.v11"' in _read(
        "TripperDashPP/Navigation/Models/DashNavSettings.swift"
    )


def test_dash_notice_is_in_pbxproj():
    """DashNotice.swift is a NEW source file — in a manual (non-synchronized)
    Xcode project it must be wired into the build phase or it compiles nowhere
    and every showNotice call site fails on the macOS CI build."""
    pbx = _read("TripperDashPP/TripperDashPP.xcodeproj/project.pbxproj")
    assert "PBXFileSystemSynchronizedRootGroup" not in pbx, (
        "project migrated to synchronized groups — drop this manual check"
    )
    assert "DashNotice.swift in Sources" in pbx, (
        "DashNotice.swift missing from PBXSourcesBuildPhase (won't compile)"
    )
    assert "path = DashNotice.swift" in pbx, (
        "DashNotice.swift has no PBXFileReference"
    )


# --- Arrival overshoot detection --------------------------------------------
#
# Rider feedback (8/2026): on a real ride, arriving at the destination did
# nothing and continuing on spun the navigation back toward the target — the
# 25 m radius was too tight for a ~1 Hz fix at speed and a roadside
# destination was overshot without ever landing inside the radius, so the
# fix fell through to the off-route/reroute path. Fix in ActiveNavigator:
# a wider capture zone that arms arrival, plus an overshoot check (remaining
# climbs back up after the closest approach).


def _active_navigator_src() -> str:
    return _read("TripperDashPP/Navigation/ActiveNavigator.swift")


def test_arrival_radius_stays_tight():
    """Radius stays tight at 25 m — the overshoot guard, not a wider radius,
    handles a fix skipping past it at speed."""
    src = _active_navigator_src()
    assert "destinationArrivalThreshold: CLLocationDistance = 25" in src, (
        "final-destination arrival radius should stay at 25 m"
    )


def test_arrival_has_capture_zone_and_overshoot():
    """Arrival must arm on a wider capture zone and also fire on overshoot."""
    src = _active_navigator_src()
    assert "arrivalCaptureRadius" in src, "missing wider capture zone"
    assert "arrivalArmed" in src, "missing arrival arming flag"
    assert "minRemainingSinceArmed" in src, "missing closest-approach tracker"
    # The overshoot branch must exist alongside the inside-radius branch.
    assert "let overshot" in src and "insideRadius || overshot" in src, (
        "arrival must fire on EITHER inside-radius OR overshoot"
    )


def test_arrival_state_is_reset_with_underway_guard():
    """The new arrival state must be reset everywhere hasBeenUnderway is,
    or a stale closest-approach floor would leak into the next ride."""
    src = _active_navigator_src()
    assert src.count("arrivalArmed = false") == src.count("hasBeenUnderway = false"), (
        "arrivalArmed must be reset wherever hasBeenUnderway is reset"
    )
    assert src.count("minRemainingSinceArmed = .greatestFiniteMagnitude") >= 3, (
        "minRemainingSinceArmed must be reset on seed/leg-seed/stop"
    )


def test_underway_arms_on_movement_for_short_routes():
    """A route that starts already inside the arrival radius (destination at
    the end of the street) never crosses the distance-based arm gate, so
    hasBeenUnderway must also arm on physical movement from the start."""
    src = _active_navigator_src()
    assert "rideStartCoordinate" in src, "missing ride-start tracker"
    assert "underwayMovementThreshold" in src, "missing movement-based arm threshold"
    assert "PolylineMath.haversine(start, coord) > underwayMovementThreshold" in src, (
        "hasBeenUnderway must arm on movement past the jitter threshold"
    )
    # Must be reset wherever the other arrival state is.
    assert src.count("rideStartCoordinate = nil") >= 3, (
        "rideStartCoordinate must be reset on seed/leg-seed/stop"
    )



