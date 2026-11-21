"""
No weather pill outlives its navigation.

Bug (Martin, 11/2026): plan a route with rain ahead, the pill says
"Rain 10 km"; stop navigation and start a free ride, and the pill kept
saying "Rain 10 km". Weather is sampled along the route during navigation
only, but nothing cleared the pill or the service's cached alert when the
navigation ended, and the one fix that still reached `navigatorIngest`
after Stop re-painted the throttled cached alert.

Drift guards on the Swift source:
- `AppStatus.clearWeather()` drops the pill AND resets the service
  (cached alert + throttle, so the next navigation polls at once);
- it runs when navigation stops, when it arrives, and when a free ride
  starts;
- weather is polled only while navigating, and a poll that lands after
  Stop is not painted.
"""

from __future__ import annotations

from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
APP = REPO / "TripperDashPP/App/AppStatus.swift"
PICKER = REPO / "TripperDashPP/UI/MapPickerView.swift"


def _body(src: str, decl: str) -> str:
    start = src.index(decl)
    ends = [e for e in (src.find("\n    func ", start + 1),
                        src.find("\n    private func ", start + 1)) if e != -1]
    return src[start:min(ends)]


def test_clear_weather_drops_pill_and_resets_service():
    body = _body(APP.read_text(), "func clearWeather()")
    assert "mapViewSource.setWeatherAlert(nil)" in body
    assert "weatherService.reset()" in body


def test_every_navigation_end_and_free_ride_start_clears_weather():
    picker = PICKER.read_text()
    for decl in ("private func stopNavigation()", "private func finishArrival() async"):
        body = _body(picker, decl)
        assert "status.clearWeather()" in body, decl
    free = _body(APP.read_text(), "private func installFreeRideContent()")
    assert "clearWeather()" in free


def test_weather_polled_and_painted_only_while_navigating():
    body = _body(APP.read_text(), "private func refreshWeather(at position:")
    guard = body[:body.index("let ahead")]
    assert "guard dashNavSettings.weatherAlertsEnabled, activeNavigator.isNavigating else" in guard
    assert "&& self.activeNavigator.isNavigating" in body
    assert "paint ? alert : nil" in body
