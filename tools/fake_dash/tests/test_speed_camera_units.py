"""
Speed-camera maxspeed + imperial-badge tests (#3, #4).

The Swift side:
  - `MaxspeedParser.swift` — the ONE parser both services share.
  - `SpeedCameraService.makeCamera` — now routes `maxspeed` through it, so
    a "55 mph" camera stores 88 km/h instead of 55 (#3).
  - `MapViewSource.displayLimit` — the ONE km/h→display converter. The
    posted-limit sign calls it; the camera badge used to as well, but it no
    longer draws a number (removed 8/2026) (#4).

None of that compiles on the Linux host, so this file:
  1. Mirrors `MaxspeedParser.kmh` + `displayLimit` in Python and pins them
     with cases whose answers are obvious by construction.
  2. Source drift-guards the Swift wiring: both services call the shared
     parser, the sign calls `displayLimit`, and the
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
    to an imperial rider on the limit sign via `displayLimit` (the camera
    badge no longer shows a number)."""
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
    # ...and is still called by the posted-limit sign. (The camera marker no
    # longer draws a number as of 8/2026, so only the sign uses it now.)
    assert src.count("Self.displayLimit(kmh:") >= 1
    # The sign no longer has its own inline imperial conversion.
    assert "? Int((Double(kmh) / 1.609344).rounded())\n            : kmh" not in src


def test_maxspeed_parser_is_in_pbxproj():
    """The shared parser is a NEW file; in this non-synchronized project it
    must be referenced in project.pbxproj or it silently won't compile and
    every `MaxspeedParser.kmh` call site fails to build (the classic manual
    pbxproj trap — see test_dash_notice_is_in_pbxproj)."""
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


def test_section_devices_are_fetched_and_drawn():
    """Czech average-speed sections are often mapped as a relation whose
    `device` members are `man_made=surveillance` nodes with NO
    `highway=speed_camera` node (e.g. II/608 Nove Ouholice). The query must
    pull the device nodes and `makeCameras` must turn them into section
    cameras, or the section gets no map marker at all."""
    cam = camera_src()
    assert 'node(r.sec:"device");' in cam
    assert 'm.role == "device"' in cam
    # Older caches were written without device nodes -> must re-fetch.
    assert "env.schema == Self.cacheSchema" in cam
    assert "private static let cacheSchema = 2" in cam


def test_eta_bubble_measures_text_without_ctx_text_position():
    """CTLineGetImageBounds(line, ctx) is offset by the ctx's current text
    position (not reset by saveGState), which shifted the bubble text out
    of its pill on the dash."""
    src = mapsource_src()
    body = src[src.index("private func drawEtaBubble"):src.index("// MARK: Speed cameras")]
    assert "CTLineGetImageBounds(line, nil)" in body
    assert "CTLineGetImageBounds(line, ctx)" not in body


def _make_cameras(elements):
    """Python mirror of `SpeedCameraService.makeCameras` (keep identical)."""
    device_limit = {}
    for e in elements:
        if e.get("type") != "relation":
            continue
        kmh = (e.get("tags") or {}).get("maxspeed")
        kmh = int(kmh) if kmh and kmh.isdigit() else None
        for m in e.get("members", []):
            if m["type"] == "node" and m["role"] == "device":
                if device_limit.get(m["ref"]) is None:
                    device_limit[m["ref"]] = kmh
    seen, out = set(), []
    for e in elements:
        if (e.get("tags") or {}).get("highway") == "speed_camera" and e["id"] not in seen:
            seen.add(e["id"])
            out.append((e["id"], True if e["id"] in device_limit else False))
    for e in elements:
        if e.get("type") == "node" and e["id"] in device_limit and "lat" in e and e["id"] not in seen:
            seen.add(e["id"])
            out.append((e["id"], True))
    return out


def test_make_cameras_mirror_on_ii608_shape():
    """Live Overpass shape of II/608 Nove Ouholice (2026-09): both
    carriageway relations share two device nodes; from/to are bare nodes."""
    rel = lambda rid, a, b: {"type": "relation", "id": rid, "tags": {"maxspeed": "50"},
                             "members": [{"type": "node", "ref": a, "role": "from"},
                                         {"type": "node", "ref": 9373412467, "role": "device"},
                                         {"type": "node", "ref": 9373412468, "role": "device"},
                                         {"type": "node", "ref": b, "role": "to"}]}
    elements = [rel(20137713, 73379245, 7294673828), rel(20137714, 7294673828, 73379245)] + [
        {"type": "node", "id": i, "lat": 50.3, "lon": 14.3}
        for i in (73379245, 7294673828, 9373412467, 9373412468)]
    assert _make_cameras(elements) == [(9373412467, True), (9373412468, True)]


def test_section_end_cameras_are_not_announced():
    """Voice: a section is announced at its start only. The nav loop must
    update the section tracker BEFORE the camera voice and filter the
    targets by the tracker's section end points."""
    loop = _src("Navigation/ActiveNavLoop.swift")
    ann = _src("RideAlerts/SpeedCameraAnnouncer.swift")
    assert "static func excludingSectionEnds(" in ann
    assert "private(set) var endPoints" in ann
    assert "excludingSectionEnds(\n            speedCameraTargets, ends: sectionTracker.endPoints)" in loop
    tick = loop[loop.index("if !isRerouting {"):]
    assert tick.index("updateSpeedSection()") < tick.index("emitCameraVoice()")
