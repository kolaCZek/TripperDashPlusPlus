"""
Free ride must not show a weather hazard found along a route that is gone.

Bug (Martin, 11/2026): plan a route with rain ahead, the pill says
"Rain 10 km"; stop navigation and start a free ride, and the pill kept
saying "Rain 10 km". `WeatherAlertService.refresh` returned its cached
along-route alert until the 5 min / ~1 km throttle opened, and free ride
has no "ahead" at all.

Drift guard on the Swift source: with no route, an along-route alert is
dropped before the throttle can return it, and a change between "route"
and "no route" bypasses the throttle.
"""

from __future__ import annotations

from pathlib import Path

SRC = (Path(__file__).resolve().parents[3]
       / "TripperDashPP/RideAlerts/WeatherAlertService.swift")


def _refresh_body() -> str:
    src = SRC.read_text()
    start = src.index("func refresh(position: CLLocationCoordinate2D,")
    return src[start:src.index("func reset()", start)]


def test_no_route_drops_an_along_route_alert_before_the_throttle():
    body = _refresh_body()
    drop = body.index("if !hasRoute, current?.isAhead == true { current = nil }")
    assert drop < body.index("return current")
    assert "let hasRoute = !routeAhead.isEmpty" in body


def test_route_presence_change_bypasses_the_throttle():
    body = _refresh_body()
    throttle = body[body.index("if let last = lastPollAt,"):body.index("return current")]
    assert "hasRoute == lastPollHadRoute" in throttle
    assert "lastPollHadRoute = hasRoute" in body
    src = SRC.read_text()
    assert "private var lastPollHadRoute = false" in src
    reset = src[src.index("func reset()"):]
    assert "lastPollHadRoute = false" in reset[:reset.index("}")]
