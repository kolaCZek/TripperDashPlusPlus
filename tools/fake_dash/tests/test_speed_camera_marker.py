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
    verbatim; imperial converts to mph (rounded) and swaps the unit.
    """
    if imperial:
        value = round(maxspeed_kmh / KMH_PER_MPH)
        unit = "mph"
    else:
        value = maxspeed_kmh
        unit = "km/h"
    return f"{value} {unit}"


@pytest.mark.parametrize("kmh,expected", [
    (50, "50 km/h"),
    (90, "90 km/h"),
    (130, "130 km/h"),
    (30, "30 km/h"),
])
def test_metric_label_is_verbatim_kmh(kmh, expected):
    assert camera_label(kmh, imperial=False) == expected


@pytest.mark.parametrize("kmh,expected_mph", [
    (50, 31),     # 31.07 → 31
    (90, 56),     # 55.92 → 56
    (130, 81),    # 80.78 → 81
    (30, 19),     # 18.64 → 19
    (100, 62),    # 62.14 → 62
])
def test_imperial_label_converts_kmh_to_mph(kmh, expected_mph):
    assert camera_label(kmh, imperial=True) == f"{expected_mph} mph"


def test_imperial_is_always_lower_number_than_metric():
    """mph value is always a smaller number than the same km/h speed —
    a quick sanity net that the conversion isn't inverted."""
    for kmh in (30, 50, 80, 130):
        mph = int(camera_label(kmh, imperial=True).split()[0])
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
# Swift-source drift: speed label BESIDE (to the right of) the icon.
# ----------------------------------------------------------------------

def test_speed_label_is_beside_not_beneath():
    """The label must be positioned to the RIGHT of the disc (pillX uses
    p.x + r), not centred beneath it (the old `p.x - approxW/2`,
    `p.y + r`)."""
    src = _map_source_src()
    assert "let pillX = p.x + r + 2 + gap" in src, (
        "speed pill must sit to the right of the marker (p.x + r ...)"
    )
    # Old beneath-the-icon placement must be gone.
    assert "p.x - approxW / 2" not in src, "old beneath-the-icon label placement still present"


def test_label_carries_unit_string():
    """Both unit strings must be in the renderer so the label reads
    e.g. '50 km/h' / '31 mph', not a bare number."""
    src = _map_source_src()
    assert '"mph"' in src and '"km/h"' in src, "marker label must carry the unit"
    assert "Double(limit) / 1.609344" in src, "km/h → mph conversion factor drifted"


# ----------------------------------------------------------------------
# Swift-source drift: units-toggle plumbing.
# ----------------------------------------------------------------------

def test_units_flag_exists_on_source():
    src = _map_source_src()
    assert "speedCameraImperial" in src, "units flag missing on MapViewSource"
    assert "func setSpeedCameraImperial(" in src, "units setter missing"


def test_units_flag_is_driven_from_settings():
    """The flag must be fed from DashNavSettings.units in BOTH the
    prefetch path (initial) and the per-tick nav loop (mid-ride toggle)."""
    assert "setSpeedCameraImperial(" in _app_status_src(), (
        "prefetch path must seed the camera units flag"
    )
    nav = _active_nav_loop_src()
    assert "setSpeedCameraImperial(settings.units == .imperial)" in nav, (
        "nav loop must keep camera units in sync each tick (mid-ride toggle)"
    )


def test_cull_margin_clears_the_side_pill():
    """The off-frame cull margin must be wide enough on the X axis to keep
    a marker whose right-side speed pill is still partly visible."""
    src = _map_source_src()
    m = re.search(r"sx > -(\d+),\s*sx < w \+ (\d+)", src)
    assert m, "camera cull guard not found"
    assert int(m.group(1)) >= 60 and int(m.group(2)) >= 60, (
        "cull margin must clear the ~66 px side pill"
    )
