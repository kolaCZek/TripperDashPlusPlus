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
from datetime import datetime, timezone

import pytest

from tests.solar import elevation


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
