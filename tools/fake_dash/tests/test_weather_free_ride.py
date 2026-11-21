"""
Free ride must not show a weather hazard found along a route that is gone.

Bug (Martin, 11/2026): plan a route with rain ahead, the pill says
"Rain 10 km"; stop navigation and start a free ride, and the pill kept
saying "Rain 10 km". `WeatherAlertService.refresh` returned its cached
along-route alert until the 5 min / ~1 km throttle opened, and free ride
has no "ahead" at all.

Weather is polled along the route during navigation only (free ride has
no weather poll). Drift guards on the Swift source:
- free ride clears the pill when it starts;
- a poll result is painted only while navigating (a fetch that lands
  after Stop must not repaint the old route's pill);
- in the service, with no route an along-route alert is dropped before the
  throttle can return it, and a change between "route" and "no route"
  bypasses the throttle (a new navigation polls along its own route).
"""

from __future__ import annotations

from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
SRC = REPO / "TripperDashPP/RideAlerts/WeatherAlertService.swift"
APP = REPO / "TripperDashPP/App/AppStatus.swift"


def _body(src: str, decl: str) -> str:
    start = src.index(decl)
    end = src.find("\n    func ", start + 1)
    end2 = src.find("\n    private func ", start + 1)
    ends = [e for e in (end, end2) if e != -1]
    return src[start:min(ends)]


def test_free_ride_start_clears_the_pill():
    body = _body(APP.read_text(), "private func installFreeRideContent()")
    assert "mapViewSource.setWeatherAlert(nil)" in body


def test_poll_result_painted_only_while_navigating():
    body = _body(APP.read_text(), "private func refreshWeather(at position:")
    assert "&& self.activeNavigator.isNavigating" in body
    assert "paint ? alert : nil" in body


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
