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
from datetime import datetime, timedelta


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


HORIZON = -0.833     # standard sunset: half the disc + refraction
CIVIL_DUSK = -6.0    # civil twilight ends: "dark"
PILL_SAMPLES = 64    # route samples for the sunset pill
PILL_HOLD_S = 60     # pill hysteresis around the ETA


def first_crossing(track, below: float) -> datetime | None:
    """Mirror of `SolarClock.firstCrossing`: `track` is [(lat, lon, dt)] in
    time order; the first instant the sun drops below `below`, bisected
    between the bracketing samples (position and time interpolated
    together), or None if it never does."""
    for a, b in zip(track, track[1:]):
        if elevation(*b) >= below:
            continue
        lo, hi = 0.0, 1.0

        def at(f):
            return (a[0] + (b[0] - a[0]) * f, a[1] + (b[1] - a[1]) * f,
                    a[2] + (b[2] - a[2]) * f)
        for _ in range(12):
            mid = (lo + hi) / 2
            if elevation(*at(mid)) < below:
                hi = mid
            else:
                lo = mid
        return at(hi)[2]
    return None


def _haversine(a, b) -> float:
    la1, la2 = math.radians(a[0]), math.radians(b[0])
    dlat, dlon = la2 - la1, math.radians(b[1] - a[1])
    h = math.sin(dlat / 2) ** 2 + math.cos(la1) * math.cos(la2) * math.sin(dlon / 2) ** 2
    return 2 * 6_371_000.0 * math.asin(min(1.0, math.sqrt(h)))


def sunset_pill(route, now: datetime, eta: datetime | None, shown: bool = False) -> datetime | None:
    """Mirror of `ActiveNavLoop.sunsetPillText` (returns the sunset instant
    instead of its text). `route` = [(lat, lon)], rider first; time is
    spread linearly over the distance to the ETA."""
    if eta is None or eta <= now or not route or elevation(*route[0], now) <= HORIZON:
        return None
    cum = [0.0]
    for a, b in zip(route, route[1:]):
        cum.append(cum[-1] + _haversine(a, b))
    total, j, track = cum[-1], 0, []
    for k in range(PILL_SAMPLES + 1):
        f = k / PILL_SAMPLES
        target = total * f
        while j < len(route) - 2 and cum[j + 1] < target:
            j += 1
        if len(route) < 2:
            lat, lon = route[0]
        else:
            seg = cum[j + 1] - cum[j]
            t = min(1.0, max(0.0, (target - cum[j]) / seg)) if seg > 0 else 0.0
            lat = route[j][0] + (route[j + 1][0] - route[j][0]) * t
            lon = route[j][1] + (route[j + 1][1] - route[j][1]) * t
        track.append((lat, lon, now + (eta - now) * f))
    hold = timedelta(seconds=PILL_HOLD_S)
    track.append((*route[-1], eta + hold))
    dusk = first_crossing(track, CIVIL_DUSK)
    if dusk is None or dusk > (eta + hold if shown else eta - hold):
        return None
    return first_crossing(track, HORIZON)
