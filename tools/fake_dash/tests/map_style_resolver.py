"""
Python mirror of `TripperDashPP/Map/MapStyleResolver.swift`.

The resolver maps (user mode, GPS, time, current palette, last-switch
time) → effective palette, with sun-elevation hysteresis + a dwell lock
so Auto can't strobe at dusk/dawn. We mirror it here so the behaviour is
pinned without booting Xcode. Solar elevation comes from the same
`solar.py` mirror the SolarClock tests use, so these rest on real
geometry, not a hand-waved sun.

Keep in sync with `MapStyleResolver.swift`.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timedelta, timezone

from tests.solar import elevation

# Mirror of MapStyleResolver constants.
DARK_BELOW_DEG = -6.0
LIGHT_ABOVE_DEG = 0.0
MIN_DWELL_S = 600.0  # 10 minutes

LIGHT = "light"
DARK = "dark"


@dataclass
class Coord:
    lat: float
    lon: float


def resolve(
    mode: str,
    coord: Coord | None,
    date: datetime,
    current: str,
    last_switch: datetime | None,
) -> str:
    if mode == "light":
        return LIGHT
    if mode == "dark":
        return DARK
    # auto
    if coord is None:
        return current
    if last_switch is not None and (date - last_switch).total_seconds() < MIN_DWELL_S:
        return current
    elev = elevation(coord.lat, coord.lon, date)
    if current == LIGHT and elev < DARK_BELOW_DEG:
        return DARK
    if current == DARK and elev > LIGHT_ABOVE_DEG:
        return LIGHT
    return current
