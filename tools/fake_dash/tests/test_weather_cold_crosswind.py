"""Guards for the cold-road and crosswind weather rules.

The classifier itself is covered by Swift tests (`ColdAndCrosswindTests` in
`WeatherAlongRouteTests.swift`), which only run on the macOS CI runner.
These source guards pin the parts a refactor could quietly break: the
fields we request from Open-Meteo, the rule ORDER inside `classify` (which
decides what the pill says), the thresholds, and the bearing threading.
"""

from __future__ import annotations

import pathlib
import re

import pytest

from tests.swift_source import decl_body, strip_comments

REPO = pathlib.Path(__file__).resolve().parents[3]
SOURCE = REPO / "TripperDashPP" / "RideAlerts" / "WeatherAlertService.swift"

CLASSIFY = "nonisolated static func classify(_ s: Sample, isAhead: Bool) -> WeatherAlert?"
CROSS = "nonisolated static func crosswindKmh(_ s: Sample) -> Double?"
REFRESH = "func refresh(position: CLLocationCoordinate2D,"


@pytest.fixture(scope="module")
def src() -> str:
    return strip_comments(SOURCE.read_text(encoding="utf-8"))


@pytest.fixture(scope="module")
def classify(src: str) -> str:
    return decl_body(src, CLASSIFY)


def test_request_asks_for_temperature_and_wind_direction(src: str):
    m = re.search(r'name: "current", value: "([^"]+)"', src)
    assert m, "current= query item not found"
    fields = m.group(1).split(",")
    assert "temperature_2m" in fields
    assert "wind_direction_10m" in fields


def test_response_decodes_the_new_fields(src: str):
    assert "let temperature_2m: Double?" in src
    assert "let wind_direction_10m: Double?" in src
    assert "temperatureC: r.current.temperature_2m" in src
    assert "windDirectionDeg: r.current.wind_direction_10m" in src


def test_thresholds(src: str):
    assert re.search(r"frostRiskBelowC: Double = 4\.0\b", src)
    assert re.search(r"iceAtOrBelowC: Double = 0\.0\b", src)
    assert re.search(r"crosswindCautionKmh: Double = 40\b", src)
    assert re.search(r"crosswindWarningKmh: Double = 55\b", src)


def test_frost_is_strictly_below_and_ice_is_at_or_below(classify: str):
    assert re.search(r"t < frostRiskBelowC", classify), "4.0 °C itself must not be frost"
    assert re.search(r"t <= iceAtOrBelowC", classify), "0.0 °C itself must be ice"


def test_sub_zero_ice_needs_precipitation(classify: str):
    line = next(l for l in classify.splitlines() if "iceAtOrBelowC" in l)
    assert "hasPrecipitation(s)" in line


def _pos(body: str, needle: str) -> int:
    i = body.find(needle)
    assert i >= 0, f"{needle!r} not in classify"
    return i


@pytest.mark.parametrize(
    "earlier, later, why",
    [
        ("[56, 57, 66, 67]", "iceAtOrBelowC", "freezing rain keeps rule 1"),
        ("iceAtOrBelowC", "[75, 86]", "sub-zero snow must read Ice, not Heavy snow"),
        ("crosswindWarningKmh", "s.gustsKmh >= 65", "crosswind must name itself before Strong wind"),
        ("s.visibilityM < 500", "frostRiskBelowC", "frost is caution tier, after all warnings"),
        ("frostRiskBelowC", "[51, 53, 55, 61, 63, 80, 81]", "a 2 °C drizzle must read Frost risk"),
        ("crosswindCautionKmh", "s.gustsKmh >= 50", "crosswind must name itself before Gusty wind"),
    ],
)
def test_rule_order(classify: str, earlier: str, later: str, why: str):
    assert _pos(classify, earlier) < _pos(classify, later), why


def test_crosswind_is_the_perpendicular_component(src: str):
    body = decl_body(src, CROSS)
    assert re.search(r"s\.gustsKmh \* abs\(sin\(\(wind - travel\) \* \.pi / 180\)\)", body)


def test_refresh_threads_a_bearing_into_every_point(src: str):
    body = decl_body(src, REFRESH)
    assert "bearingDeg: Self.travelBearing(routeAhead" in body
    assert "travelBearingDeg: idx < points.count ? points[idx].bearingDeg : nil" in src
