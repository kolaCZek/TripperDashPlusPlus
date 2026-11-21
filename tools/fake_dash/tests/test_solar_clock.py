"""
Python mirror of `SolarClock.swift` — sun elevation angle for a
coordinate + instant. We don't run Swift in CI, so this encodes the
exact same NOAA-style algorithm in plain Python; if the Swift formula
drifts, mirror the change here and re-run `pytest tests/test_solar_clock.py`.

The fixtures below are cross-checked against PyEphem (an independent
ephemeris) with atmospheric refraction disabled (geometric elevation).
Our simplified algorithm agreed with PyEphem to within 0.01° at every
fixture — far tighter than the −6°/0° light/dark dead-band needs, so we
assert a comfortable ±0.5° tolerance to leave room for the Swift port's
Double rounding without making the test brittle.

If you change `SolarClock.swift`, mirror it in `solar.py` and here.
"""

import math
from datetime import datetime, timedelta, timezone

import pytest

from tests.solar import CIVIL_DUSK, HORIZON, elevation, first_crossing, sunset_pill


# ---------------------------------------------------------------------------
# Reference fixtures — Prague (Karlín-ish) unless noted. The `ref` values
# come from PyEphem (pressure=0 → geometric, no refraction) and are stable
# astronomy, not self-referential.
# ---------------------------------------------------------------------------

PRAHA = (50.08, 14.43)

# (lat, lon, datetime UTC, expected_elevation_deg)
FIXTURES = [
    (*PRAHA, datetime(2026, 6, 21, 11, 5, tzinfo=timezone.utc), 63.36),   # summer solstice solar noon (max)
    (*PRAHA, datetime(2026, 6, 21, 12, 0, tzinfo=timezone.utc), 61.21),
    (*PRAHA, datetime(2026, 12, 21, 16, 30, tzinfo=timezone.utc), -13.13),  # winter dusk, well dark
    (*PRAHA, datetime(2026, 6, 21, 0, 0, tzinfo=timezone.utc), -15.44),    # summer midnight, below horizon
    (*PRAHA, datetime(2026, 3, 20, 6, 0, tzinfo=timezone.utc), 7.90),     # equinox, just after sunrise
    (*PRAHA, datetime(2026, 9, 15, 4, 30, tzinfo=timezone.utc), -2.09),    # near sunrise (civil twilight band)
    (*PRAHA, datetime(2026, 1, 5, 8, 0, tzinfo=timezone.utc), 6.32),      # winter mid-morning, low sun
]


class TestSolarElevation:
    @pytest.mark.parametrize("lat,lon,dt,expected", FIXTURES)
    def test_elevation_matches_ephemeris(self, lat, lon, dt, expected):
        got = elevation(lat, lon, dt)
        assert abs(got - expected) < 0.5, (
            f"{dt} @ ({lat},{lon}) → {got:.2f}°, expected ≈ {expected}°"
        )

    def test_summer_noon_is_the_seasonal_max(self):
        """Solar-noon elevation on the summer solstice equals the
        theoretical maximum 90 − lat + axial_tilt (≈ 63.36° at Prague)."""
        theoretical = 90 - PRAHA[0] + 23.44
        got = elevation(*PRAHA, datetime(2026, 6, 21, 11, 5, tzinfo=timezone.utc))
        assert abs(got - theoretical) < 0.2

    def test_polar_night_never_rises(self):
        """Above the Arctic Circle at winter solstice the sun stays below
        the horizon all day — so Auto would hold Dark regardless of clock
        (no threshold crossing). Sanity-check the math doesn't blow up at
        high latitude."""
        tromso = (69.65, 18.96)
        for hour in range(0, 24, 3):
            dt = datetime(2026, 12, 21, hour, 0, tzinfo=timezone.utc)
            assert elevation(*tromso, dt) < 0.0


class TestDeadBandCrossings:
    """The resolver thresholds on −6° (civil twilight) and 0° (horizon).
    Verify a dusk sweep actually crosses both, so the resolver tests rest
    on real geometry."""

    def test_dusk_sweep_crosses_horizon_then_civil_twilight(self):
        # Walk Prague through a spring evening; elevation must decrease
        # monotonically and pass through 0° then −6°.
        base = datetime(2026, 4, 1, 16, 0, tzinfo=timezone.utc)
        elevs = [
            elevation(*PRAHA, base.replace(hour=h, minute=m))
            for h in range(16, 21)
            for m in (0, 30)
        ]
        # Monotonic decrease across the evening.
        for a, b in zip(elevs, elevs[1:]):
            assert b < a, f"elevation not decreasing: {elevs}"
        assert max(elevs) > 0.0, "sun should start above the horizon"
        assert min(elevs) < -6.0, "sun should drop below civil twilight"


class TestSunsetPill:
    """`sunset_pill` / `first_crossing` mirror `ActiveNavLoop.sunsetPillText`
    / `SolarClock.firstCrossing` (the dash sunset pill); the same cases run
    in Swift in SunsetPillTests.swift. Published Prague sunsets
    (timeanddate.com): 21:15 CEST at the summer solstice, 16:02 CET at the
    winter solstice, 18:15 CET at the March equinox."""

    @pytest.mark.parametrize("day,expected", [
        (datetime(2026, 6, 21, 8, 0, tzinfo=timezone.utc), datetime(2026, 6, 21, 19, 15, tzinfo=timezone.utc)),
        (datetime(2026, 12, 21, 8, 0, tzinfo=timezone.utc), datetime(2026, 12, 21, 15, 2, tzinfo=timezone.utc)),
        (datetime(2026, 3, 20, 8, 0, tzinfo=timezone.utc), datetime(2026, 3, 20, 17, 15, tzinfo=timezone.utc)),
    ])
    def test_matches_published_sunset(self, day, expected):
        track = [(*PRAHA, day + timedelta(minutes=15 * k)) for k in range(61)]
        got = first_crossing(track, HORIZON)
        assert got is not None and abs((got - expected).total_seconds()) < 4 * 60, got

    @staticmethod
    def at(h, m=0, s=0, day=15, month=9):
        return datetime(2026, month, day, h, m, s, tzinfo=timezone.utc)

    def test_prague_eta_after_dusk_shows_sunset(self):
        assert sunset_pill([PRAHA], self.at(15), self.at(18, 30)).strftime("%H:%M") == "17:16"
        assert first_crossing([(*PRAHA, self.at(15)), (*PRAHA, self.at(18, 30))],
                              CIVIL_DUSK).strftime("%H:%M:%S") == "17:48:40"

    def test_eta_after_sunset_before_dusk_hides(self):
        assert sunset_pill([PRAHA], self.at(15), self.at(17, 40)) is None

    def test_hysteresis(self):
        assert sunset_pill([PRAHA], self.at(15), self.at(17, 49, 10)) is None
        assert sunset_pill([PRAHA], self.at(15), self.at(17, 49, 10), shown=True).strftime("%H:%M") == "17:16"

    def test_sun_already_down_or_no_eta_hides(self):
        assert sunset_pill([PRAHA], self.at(18, 30), self.at(19, 30)) is None
        assert sunset_pill([PRAHA], self.at(15), None) is None
        tromso = (69.65, 18.96)
        assert sunset_pill([tromso], self.at(12, day=21, month=12), self.at(22, day=21, month=12)) is None

    def test_white_night_hides(self):
        trondheim = (63.43, 10.39)
        now, eta = self.at(20, day=21, month=6), self.at(23, day=21, month=6)   # 22:00 → 01:00 CEST
        sunset = first_crossing([(*trondheim, now), (*trondheim, eta)], HORIZON)
        assert sunset.strftime("%H:%M") == "21:38"                               # 23:38 CEST
        assert min(elevation(*trondheim, now + timedelta(minutes=m)) for m in range(0, 181, 5)) > CIVIL_DUSK
        assert sunset_pill([trondheim], now, eta) is None

    def test_polar_day_hides(self):
        tromso = (69.65, 18.96)
        assert sunset_pill([tromso], self.at(12, day=21, month=6), self.at(22, day=21, month=6)) is None

    def test_long_route_uses_predicted_position(self):
        chicago, denver = (41.88, -87.63), (39.74, -104.99)
        now = self.at(17)
        eta = now + timedelta(hours=15)
        hm = lambda route: sunset_pill(route, now, eta).strftime("%H:%M")
        assert (hm([chicago, denver]), hm([chicago]), hm([denver])) == ("00:34", "23:59", "01:08")
        on_route = sunset_pill([chicago, denver], now, eta)
        assert (on_route - sunset_pill([chicago], now, eta)).total_seconds() > 15 * 60

    def test_swift_matches_this_mirror(self):
        import pathlib
        from tests.solar import PILL_HOLD_S, PILL_SAMPLES
        app = pathlib.Path(__file__).resolve().parents[3] / "TripperDashPP"
        solar = (app / "Map" / "SolarClock.swift").read_text()
        loop = (app / "Navigation" / "ActiveNavLoop.swift").read_text()
        assert f"static let sunsetElevation = {HORIZON}" in solar
        assert f"static let civilDuskElevation = {CIVIL_DUSK}" in solar
        assert "for _ in 0..<12 {" in solar
        assert "nextSunset" not in solar + loop
        for needle in (f"let n = {PILL_SAMPLES}", f"let hold: TimeInterval = {PILL_HOLD_S}",
                       "dusk <= eta.addingTimeInterval(shown ? hold : -hold)",
                       "SolarClock.elevation(coord: rider, date: now) > SolarClock.sunsetElevation",
                       "route: [fix.coordinate] + nav.routeAheadCoordinates"):
            assert needle in loop, needle
