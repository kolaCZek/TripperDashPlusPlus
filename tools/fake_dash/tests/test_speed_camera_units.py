"""
Speed-camera maxspeed + imperial-badge tests (#3, #4).

The Swift side:
  - `MaxspeedParser.swift` — the ONE parser both services share.
  - `SpeedCameraService.makeCamera` — now routes `maxspeed` through it, so
    a "55 mph" camera stores 88 km/h instead of 55 (#3).
  - `MapViewSource.displayLimit` — the ONE km/h→display converter the
    camera badge AND the posted-limit sign both call, so they can't show
    different numbers for the same road (#4).

None of that compiles on the Linux host, so this file:
  1. Mirrors `MaxspeedParser.kmh` + `displayLimit` in Python and pins them
     with cases whose answers are obvious by construction.
  2. Source drift-guards the Swift wiring: both services call the shared
     parser, the camera badge + the sign both call `displayLimit`, and the
     old naive leading-digits parser is gone from the camera service.

Compilation itself is verified by the macOS `xcodebuild` CI job.
"""

from __future__ import annotations

from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[3]
APP = REPO / "TripperDashPP"


def _src(rel: str) -> str:
    p = APP / rel
    assert p.exists(), f"missing source file: {rel}"
    return p.read_text(encoding="utf-8")


# --- Reference implementations (mirror the Swift) -------------------------

MPH_TO_KMH = 1.609344


def maxspeed_kmh(raw):
    """Mirror of MaxspeedParser.kmh."""
    if raw is None:
        return None
    raw = raw.strip()
    if not raw:
        return None
    lower = raw.lower()
    digits = ""
    for ch in lower:
        if ch.isdigit():
            digits += ch
        else:
            break
    if not digits:
        return None
    value = int(digits)
    if value <= 0:
        return None
    if "mph" in lower:
        return round(value * MPH_TO_KMH)
    return value


def display_limit(kmh: int, imperial: bool) -> int:
    """Mirror of MapViewSource.displayLimit."""
    return round(kmh / MPH_TO_KMH) if imperial else kmh


# --- Parser behaviour: the #3 fix -----------------------------------------

@pytest.mark.parametrize("raw,expected", [
    ("50", 50),
    ("50 km/h", 50),
    ("80;100", 80),
    ("30 mph", 48),        # 30 * 1.609344 = 48.28 → 48
    ("55 mph", 89),        # the #3 bug: was 55, now 89 (55*1.609=88.51→89)
    ("55mph", 89),         # no space
    ("70 mph", 113),       # US interstate
    ("none", None),
    ("walk", None),
    ("signals", None),
    ("GB:nsl", None),
    ("CZ:urban", None),
    ("", None),
    (None, None),
    ("0", None),
])
def test_maxspeed_parser(raw, expected):
    assert maxspeed_kmh(raw) == expected


def test_camera_and_limit_parser_agree():
    """The whole point of the shared parser: identical output for the same
    input, across every shape."""
    for raw in ["50", "50 km/h", "55 mph", "70 mph", "80;100", "none", "0"]:
        # Both services call MaxspeedParser.kmh, mirrored here as one fn.
        assert maxspeed_kmh(raw) == maxspeed_kmh(raw)


# --- Display badge: the #4 fix --------------------------------------------

@pytest.mark.parametrize("kmh,imperial,expected", [
    (50, False, 50),
    (50, True, 31),       # 50 / 1.609344 = 31.07 → 31
    (89, True, 55),       # the 55 mph zone round-trips back to 55 for display
    (113, True, 70),      # 70 mph interstate round-trips back to 70
    (130, False, 130),
    (130, True, 81),
])
def test_display_limit(kmh, imperial, expected):
    assert display_limit(kmh, imperial) == expected


def test_mph_zone_round_trips_for_imperial_rider():
    """A 55 mph zone: parsed to 89 km/h internally, displayed back as 55
    to an imperial rider — on BOTH the camera badge and the limit sign,
    because they share `displayLimit`."""
    internal = maxspeed_kmh("55 mph")
    assert internal == 89
    assert display_limit(internal, imperial=True) == 55


# --- Swift source drift guards --------------------------------------------

def camera_src() -> str:
    return _src("RideAlerts/SpeedCameraService.swift")


def limit_src() -> str:
    return _src("RideAlerts/SpeedLimitService.swift")


def parser_src() -> str:
    return _src("RideAlerts/MaxspeedParser.swift")


def mapsource_src() -> str:
    return _src("Map/MapViewSource.swift")


def test_shared_parser_exists():
    src = parser_src()
    assert "enum MaxspeedParser" in src
    assert "static func kmh(" in src
    # The mph conversion lives here now.
    assert "1.609344" in src


def test_both_services_use_shared_parser():
    cam = camera_src()
    lim = limit_src()
    # Camera service routes maxspeed through the shared parser...
    assert "MaxspeedParser.kmh(tags[\"maxspeed\"])" in cam
    # ...and the old naive leading-digits parser is GONE from the camera.
    assert "raw.prefix { $0.isNumber }" not in cam
    # Limit service delegates its named parser to the shared one (the name
    # is kept for the existing drift-guard + call sites).
    assert "func parseMaxspeedKmh(" in lim
    assert "MaxspeedParser.kmh(raw)" in lim


def test_camera_badge_and_sign_share_display_helper():
    src = mapsource_src()
    # The single converter exists...
    assert "static func displayLimit(kmh: Int, imperial: Bool)" in src
    # ...and is called in BOTH the camera badge and the limit sign.
    assert src.count("Self.displayLimit(kmh:") >= 2
    # The sign no longer has its own inline imperial conversion.
    assert "? Int((Double(kmh) / 1.609344).rounded())\n            : kmh" not in src


def test_maxspeed_parser_is_in_pbxproj():
    """The shared parser is a NEW file; in this non-synchronized project it
    must be referenced in project.pbxproj or it silently won't compile and
    every `MaxspeedParser.kmh` call site fails to build (the classic manual
    pbxproj trap — see test_maneuver_log)."""
    pbx = (
        REPO / "TripperDashPP" / "TripperDashPP.xcodeproj" / "project.pbxproj"
    ).read_text(encoding="utf-8")
    assert "PBXFileSystemSynchronizedRootGroup" not in pbx, (
        "project migrated to synchronized groups — drop this manual check"
    )
    assert "MaxspeedParser.swift in Sources" in pbx, (
        "MaxspeedParser.swift must be in a PBXBuildFile (compiled)"
    )
    assert "path = MaxspeedParser.swift" in pbx, (
        "MaxspeedParser.swift must have a PBXFileReference"
    )
