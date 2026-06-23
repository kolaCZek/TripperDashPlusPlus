"""
Python mirror of `TripperDashPP/Map/SolarClock.swift`.

Sun elevation angle (degrees above horizon, negative below) for a
geographic coordinate at an instant. Pure math, no dependencies —
a simplified NOAA solar-position algorithm:

    Julian day → days since J2000 → mean longitude + mean anomaly →
    ecliptic longitude → declination + right ascension → local hour
    angle (via GMST + longitude) → elevation.

Accuracy: agreed with PyEphem (geometric, refraction disabled) to
within 0.01° at the test fixtures — ample for a light/dark threshold
that switches on a 6°-wide dead-band.

Keep this byte-for-byte equivalent to the Swift `SolarClock.elevation`.
"""

from __future__ import annotations

import math
from datetime import datetime


def _julian_day(dt: datetime) -> float:
    # Unix epoch (1970-01-01T00:00Z) = Julian Day 2440587.5.
    return dt.timestamp() / 86400.0 + 2440587.5


def elevation(lat: float, lon: float, dt: datetime) -> float:
    """Sun elevation in degrees at (lat, lon) for the instant `dt`.

    `dt` must be timezone-aware (its POSIX timestamp is what feeds the
    Julian-day conversion); pass UTC datetimes in tests.
    """
    jd = _julian_day(dt)
    n = jd - 2451545.0                                   # days since J2000.0
    L = (280.460 + 0.9856474 * n) % 360.0                # mean longitude (deg)
    g = math.radians((357.528 + 0.9856003 * n) % 360.0)  # mean anomaly (rad)
    lam = math.radians(L + 1.915 * math.sin(g) + 0.020 * math.sin(2 * g))  # ecliptic lon
    eps = math.radians(23.439)                           # obliquity of ecliptic
    decl = math.asin(math.sin(eps) * math.sin(lam))      # declination
    gmst = (18.697374558 + 24.06570982441908 * n) % 24.0  # Greenwich mean sidereal (hours)
    ra = math.atan2(math.cos(eps) * math.sin(lam), math.cos(lam))  # right ascension (rad)
    lst = math.radians(gmst * 15.0) + math.radians(lon)  # local sidereal (rad)
    ha = lst - ra                                        # hour angle (rad)
    latr = math.radians(lat)
    elev = math.asin(
        math.sin(latr) * math.sin(decl)
        + math.cos(latr) * math.cos(decl) * math.cos(ha)
    )
    return math.degrees(elev)
