"""
Driving-side lookup tests.

Two layers, same discipline as the roundabout-parser and maneuver-geometry
mirrors:

1. **Behavioural** — a set of well-known city / landmark coordinates whose
   driving side is unambiguous, asserted against the Python lookup. This is
   what actually guards the roundabout-winding fix: get the side wrong and
   the dash draws the arc the wrong way.

2. **Swift ↔ Python sync** — parse the bounding-box table out of
   `DrivingSide.swift` and assert it matches `LEFT_HAND_REGIONS` box-for-box
   (same count, same order, same numbers), so the iOS app and the tooling
   can't drift apart silently.
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest

from tests.driving_side import LEFT_HAND_REGIONS, driving_side, roundabout_clockwise


# -----------------------------------------------------------------------
# Behavioural fixtures: (name, lat, lon, expected_side).
# -----------------------------------------------------------------------

CITY_FIXTURES: list[tuple[str, float, float, str]] = [
    # --- Left-hand traffic ------------------------------------------
    ("London", 51.5074, -0.1278, "left"),
    ("Edinburgh", 55.9533, -3.1883, "left"),
    ("Dublin", 53.3498, -6.2603, "left"),
    ("Tokyo", 35.6762, 139.6503, "left"),
    ("Sydney", -33.8688, 151.2093, "left"),
    ("Perth AU", -31.9523, 115.8613, "left"),
    ("Auckland", -36.8485, 174.7633, "left"),
    ("New Delhi", 28.6139, 77.2090, "left"),
    ("Mumbai", 19.0760, 72.8777, "left"),
    ("Karachi", 24.8607, 67.0011, "left"),
    ("Dhaka", 23.8103, 90.4125, "left"),
    ("Colombo", 6.9271, 79.8612, "left"),
    ("Bangkok", 13.7563, 100.5018, "left"),
    ("Kuala Lumpur", 3.1390, 101.6869, "left"),
    ("Singapore", 1.3521, 103.8198, "left"),
    ("Jakarta", -6.2088, 106.8456, "left"),
    ("Johannesburg", -26.2041, 28.0473, "left"),
    ("Cape Town", -33.9249, 18.4241, "left"),
    ("Nairobi", -1.2921, 36.8219, "left"),
    ("Dar es Salaam", -6.7924, 39.2083, "left"),
    ("Valletta", 35.8989, 14.5146, "left"),
    ("Nicosia", 35.1856, 33.3823, "left"),
    ("Georgetown GY", 6.8013, -58.1551, "left"),

    # --- Right-hand traffic (the global default) --------------------
    ("Prague", 50.0755, 14.4378, "right"),
    ("Paris", 48.8566, 2.3522, "right"),
    ("Berlin", 52.5200, 13.4050, "right"),
    ("Madrid", 40.4168, -3.7038, "right"),
    ("Rome", 41.9028, 12.4964, "right"),
    ("New York", 40.7128, -74.0060, "right"),
    ("Los Angeles", 34.0522, -118.2437, "right"),
    ("Mexico City", 19.4326, -99.1332, "right"),
    ("Sao Paulo", -23.5505, -46.6333, "right"),
    ("Beijing", 39.9042, 116.4074, "right"),
    ("Shanghai", 31.2304, 121.4737, "right"),
    ("Seoul", 37.5665, 126.9780, "right"),
    ("Moscow", 55.7558, 37.6173, "right"),
    ("Cairo", 30.0444, 31.2357, "right"),
    ("Lagos", 6.5244, 3.3792, "right"),
    ("Hanoi", 21.0278, 105.8342, "right"),
    ("Manila", 14.5995, 120.9842, "right"),
    # Continental-Europe edge near the UK box: must stay RHT.
    ("Cherbourg FR", 49.6337, -1.6221, "right"),
    ("Calais FR", 50.9513, 1.8587, "right"),
]


@pytest.mark.parametrize("name,lat,lon,expected", CITY_FIXTURES)
def test_driving_side_for_cities(name, lat, lon, expected):
    got = driving_side(lat, lon)
    assert got == expected, f"{name} ({lat},{lon}): expected {expected}, got {got}"


@pytest.mark.parametrize("name,lat,lon,expected", CITY_FIXTURES)
def test_roundabout_winding_matches_side(name, lat, lon, expected):
    # CW iff left-hand traffic.
    assert roundabout_clockwise(lat, lon) == (expected == "left")


# -----------------------------------------------------------------------
# Swift ↔ Python sync test.
# -----------------------------------------------------------------------

def _swift_source() -> str:
    here = Path(__file__).resolve()
    repo_root = here.parents[3]
    swift = (repo_root / "TripperDashPP" / "Navigation" / "Models"
             / "DrivingSide.swift")
    return swift.read_text(encoding="utf-8")


# Match `GeoBox(minLat: 49.9, maxLat: 60.9, minLon: -10.7, maxLon: 1.9)`,
# tolerant of whitespace and negative / decimal numbers.
_SWIFT_BOX_RE = re.compile(
    r"GeoBox\(\s*minLat:\s*(-?\d+(?:\.\d+)?)\s*,"
    r"\s*maxLat:\s*(-?\d+(?:\.\d+)?)\s*,"
    r"\s*minLon:\s*(-?\d+(?:\.\d+)?)\s*,"
    r"\s*maxLon:\s*(-?\d+(?:\.\d+)?)\s*\)"
)


def _parse_swift_boxes() -> list[tuple[float, float, float, float]]:
    src = _swift_source()
    # Narrow to the leftHandRegions array literal so we don't catch the
    # GeoBox struct definition or doc-comment examples.
    block = re.search(
        r"leftHandRegions:\s*\[GeoBox\]\s*=\s*\[(.*?)^\s*\]",
        src,
        flags=re.DOTALL | re.MULTILINE,
    )
    assert block, "Could not locate `leftHandRegions` array in DrivingSide.swift"
    body = block.group(1)
    boxes: list[tuple[float, float, float, float]] = []
    for m in _SWIFT_BOX_RE.finditer(body):
        a, b, c, d = (float(g) for g in m.groups())
        boxes.append((a, b, c, d))
    return boxes


def test_swift_boxes_match_python():
    swift_boxes = _parse_swift_boxes()
    python_boxes = [(b.min_lat, b.max_lat, b.min_lon, b.max_lon)
                    for b in LEFT_HAND_REGIONS]

    assert len(swift_boxes) == len(python_boxes), (
        f"Box count drift: Swift has {len(swift_boxes)}, "
        f"Python has {len(python_boxes)}"
    )
    diffs = [
        f"  box {i}: Swift {s} vs Python {p}"
        for i, (s, p) in enumerate(zip(swift_boxes, python_boxes))
        if s != p
    ]
    assert not diffs, "Swift and Python LHT box tables out of sync:\n" + "\n".join(diffs)


def test_driving_side_is_in_pbxproj():
    """`DrivingSide.swift` is a NEW file. This project does not use Xcode-16
    synchronized groups, so a new source must be wired into project.pbxproj
    by hand or it silently won't compile — and then the roundabout-winding
    fix that depends on it never ships. Guards that manual edit (mirrors
    test_maneuver_log's pbxproj check)."""
    pbx = (
        Path(__file__).resolve().parents[3]
        / "TripperDashPP" / "TripperDashPP.xcodeproj" / "project.pbxproj"
    ).read_text(encoding="utf-8")
    assert "PBXFileSystemSynchronizedRootGroup" not in pbx, (
        "project migrated to synchronized groups — drop this manual check"
    )
    assert "DrivingSide.swift in Sources" in pbx, (
        "DrivingSide.swift must be in a PBXBuildFile (compiled)"
    )
    assert "path = DrivingSide.swift" in pbx, (
        "DrivingSide.swift must have a PBXFileReference"
    )
