"""
Tests for the speed-camera map marker in `MapViewSource.swift`.

The marker draws a camera pictograph at each mapped `highway=speed_camera`
POI along the route, with the posted speed limit beside it. fake_dash
can't run Swift / CoreGraphics, so this is a two-part guard:

  1. A pure-Python mirror of the km/h → mph conversion + label format,
     so the unit math itself is pinned.
  2. Swift-source drift guards asserting the renderer still carries the
     enlarged icon geometry, the speed label POSITIONED BESIDE the icon
     (not beneath it), and the units-toggle plumbing.

Rider feedback driving these (2026-06):
  - "make the icon bigger" → marker disc r 11 → 15, body 14×9 → 20×13.
  - "write the speed beside it" → label moved from below the disc to a
    pill on its RIGHT.
  - "careful, settings can switch km/h ↔ mph" → label honours
    DashNavSettings.units; OSM maxspeed is always km/h so we convert.
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest


def _repo_root() -> Path:
    return Path(__file__).resolve().parents[3]


def _map_source_src() -> str:
    return (_repo_root() / "TripperDashPP" / "Map" / "MapViewSource.swift").read_text(
        encoding="utf-8"
    )


def _app_status_src() -> str:
    return (_repo_root() / "TripperDashPP" / "App" / "AppStatus.swift").read_text(
        encoding="utf-8"
    )


def _active_nav_loop_src() -> str:
    return (_repo_root() / "TripperDashPP" / "Navigation" / "ActiveNavLoop.swift").read_text(
        encoding="utf-8"
    )


# ----------------------------------------------------------------------
# Mirror of the Swift speed-label math.
# ----------------------------------------------------------------------

KMH_PER_MPH = 1.609344


def camera_label(maxspeed_kmh: int, imperial: bool) -> str:
    """Mirror of drawCameraMarker's label construction.

    OSM `maxspeed` is always km/h (European dataset). Metric shows it
    verbatim; imperial converts to mph (rounded). The numeric conversion
    goes through the shared `displayLimit` helper in Swift (same one the
    posted-limit sign uses) so the pill and the sign can never disagree.
    The pill shows the BARE NUMBER — no unit suffix (rider feedback
    8/2026: "50" not "50 km/h"; the camera pictograph already frames it
    as a speed).
    """
    if imperial:
        return f"{round(maxspeed_kmh / KMH_PER_MPH)}"
    return f"{maxspeed_kmh}"


@pytest.mark.parametrize("kmh,expected", [
    (50, "50"),
    (90, "90"),
    (130, "130"),
    (30, "30"),
])
def test_metric_label_is_bare_kmh_number(kmh, expected):
    assert camera_label(kmh, imperial=False) == expected


@pytest.mark.parametrize("kmh,expected_mph", [
    (50, 31),     # 31.07 → 31
    (90, 56),     # 55.92 → 56
    (130, 81),    # 80.78 → 81
    (30, 19),     # 18.64 → 19
    (100, 62),    # 62.14 → 62
])
def test_imperial_label_converts_kmh_to_mph(kmh, expected_mph):
    assert camera_label(kmh, imperial=True) == f"{expected_mph}"


def test_imperial_is_always_lower_number_than_metric():
    """mph value is always a smaller number than the same km/h speed —
    a quick sanity net that the conversion isn't inverted."""
    for kmh in (30, 50, 80, 130):
        mph = int(camera_label(kmh, imperial=True))
        assert mph < kmh


# ----------------------------------------------------------------------
# Swift-source drift: enlarged icon geometry.
# ----------------------------------------------------------------------

def test_marker_disc_is_enlarged():
    """The disc radius must be the enlarged 15 (was 11). Catches a
    refactor that reverts the rider-requested bigger icon."""
    src = _map_source_src()
    m = re.search(r"let r:\s*CGFloat\s*=\s*(\d+)\s*\n", src)
    assert m, "marker disc radius constant not found"
    assert int(m.group(1)) == 15, "camera marker disc radius must be 15 (enlarged)"


def test_marker_body_is_enlarged():
    """Camera body rect grew with the disc: 14×9 → 20×13."""
    src = _map_source_src()
    assert "CGRect(x: -10, y: -6.5, width: 20, height: 13)" in src, (
        "camera body rect must be the enlarged 20×13"
    )
    # The old small body must be gone so it can't silently come back.
    assert "width: 14, height: 9)" not in src, "old 14×9 camera body still present"


# ----------------------------------------------------------------------
# Swift-source drift: the speed number was REMOVED from the camera marker.
#
# Rider feedback (on-dash, 8/2026): the speed number on a pill next to the
# camera pictograph looked cluttered/ugly on the small TFT after H.264
# subsampling, clashing with the dedicated speed-limit roundel. The marker
# is now the pictograph ALONE; the posted limit still shows on the
# speed-limit sign. These guards keep the pill from silently drifting back.
# ----------------------------------------------------------------------

def test_camera_marker_has_no_speed_pill():
    """The camera marker must NOT draw a speed pill/number beside it.
    The whole `pillX = p.x + r ...` right-side placement was removed."""
    src = _map_source_src()
    assert "let pillX = p.x + r + 2 + gap" not in src, (
        "speed pill beside the camera marker is back — it was removed 8/2026"
    )
    # The old beneath-the-icon placement must also stay gone.
    assert "p.x - approxW / 2" not in src, "old beneath-the-icon label placement is back"


def test_camera_marker_draws_no_number_label():
    """No speed-number label is rendered on the camera marker at all."""
    src = _map_source_src()
    assert 'let label = "\\(Self.displayLimit(kmh: limit, imperial: speedLimitImperial))"' not in src, (
        "camera marker is drawing a speed-number label again — removed 8/2026"
    )
    # A comment documenting the removal should be present so the intent is
    # obvious to the next reader (and this test's reason is discoverable).
    assert "speed number" in src.lower() and "removed" in src.lower(), (
        "the removal rationale comment vanished from drawCameraMarker"
    )


# ----------------------------------------------------------------------
# Swift-source drift: units-toggle plumbing.
#
# The shared `displayLimit` helper and the `speedLimitImperial` flag stay —
# they are still used by the posted-limit SIGN (the camera marker no longer
# uses them since its number was removed). One source of truth for the sign.
# ----------------------------------------------------------------------

def test_shared_display_helper_and_units_flag_remain():
    src = _map_source_src()
    assert "speedLimitImperial" in src, "shared units flag missing on MapViewSource"
    assert "static func displayLimit(kmh: Int, imperial: Bool)" in src, (
        "shared displayLimit helper missing — the speed-limit sign needs it"
    )
    # The km/h → mph conversion still lives in the shared helper.
    assert "Double(kmh) / 1.609344" in src, "km/h → mph conversion factor drifted"
    # The retired per-camera flag must stay gone.
    assert "speedCameraImperial" not in src, (
        "retired speedCameraImperial flag still present — should use speedLimitImperial"
    )


def test_units_flag_is_driven_from_settings():
    """The units flag must be fed from DashNavSettings.units in BOTH the
    prefetch path (initial, via pushSpeedLimitConfig) and the per-tick nav
    loop (mid-ride toggle), through the shared speed-limit config."""
    app = _app_status_src()
    assert "setSpeedLimitConfig(" in app, (
        "prefetch path must push the speed-limit/units config"
    )
    assert "imperial: dashNavSettings.units == .imperial" in app, (
        "config must derive imperial from DashNavSettings.units"
    )
    nav = _active_nav_loop_src()
    assert "setSpeedLimitConfig(" in nav, (
        "nav loop must keep units/limit config in sync each tick (mid-ride toggle)"
    )
    assert "imperial: settings.units == .imperial" in nav, (
        "nav loop must derive imperial from settings.units each tick"
    )


def test_cull_margin_is_generous_on_x():
    """The off-frame cull margin must stay wide on the X axis so a marker
    near the edge isn't culled too early (kept generous even though the
    side speed pill was removed 8/2026)."""
    src = _map_source_src()
    m = re.search(r"sx > -(\d+),\s*sx < w \+ (\d+)", src)
    assert m, "camera cull guard not found"
    assert int(m.group(1)) >= 20 and int(m.group(2)) >= 20, (
        "cull margin must stay generous enough to keep edge markers"
    )
