"""
Python mirror of `TripperDashPP/Navigation/Models/DrivingSide.swift`.

Same coarse left-hand-traffic bounding-box table as the Swift type. Used
by `tests/test_driving_side.py` to (a) behaviourally test the lookup
against known city coordinates and (b) assert — via a Swift-source sync
test — that the box list hasn't drifted from the Swift side, exactly like
the roundabout parser and maneuver-geometry mirrors.

If you change either side, mirror the change here (and vice versa).

Right-hand traffic is the global default; only points inside a listed
region resolve to left-hand traffic. Roundabouts wind counter-clockwise
in RHT and clockwise in LHT, which is the whole reason this table exists
(the dash glyph catalog has separate CCW / CW byte ranges).
"""

from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class GeoBox:
    min_lat: float
    max_lat: float
    min_lon: float
    max_lon: float

    def contains(self, lat: float, lon: float) -> bool:
        return (self.min_lat <= lat <= self.max_lat
                and self.min_lon <= lon <= self.max_lon)


# Coarse bounding boxes for the world's left-hand-traffic regions. Keep
# IDENTICAL (same boxes, same order) to `leftHandRegions` in the Swift
# `DrivingSide` — the sync test asserts each (minLat, maxLat, minLon,
# maxLon) tuple matches.
LEFT_HAND_REGIONS: list[GeoBox] = [
    # British Isles (UK + Ireland). East edge 1.77 keeps Lowestoft Ness
    # (~1.76°E) while excluding RHT Calais (~1.86°E).
    GeoBox(49.9, 60.9, -10.7, 1.77),
    # Malta.
    GeoBox(35.7, 36.1, 14.1, 14.6),
    # Cyprus.
    GeoBox(34.5, 35.8, 32.2, 34.65),
    # Japan — mainland (Kyushu/Shikoku/Honshu/Hokkaido). West edge 129.5
    # excludes the Korean peninsula (RHT; Busan ~129.1°E), keeps Nagasaki.
    GeoBox(29.0, 45.6, 129.5, 146.0),
    # Japan — Ryukyu/Okinawa arc (south of Korea, west of mainland JP).
    GeoBox(24.0, 29.0, 122.8, 131.0),
    # Australia.
    GeoBox(-43.8, -9.0, 112.8, 154.0),
    # New Zealand (mainland; stops west of the antimeridian).
    GeoBox(-47.5, -33.0, 166.0, 179.2),
    # Indian subcontinent: India, Pakistan, Bangladesh, Nepal, Bhutan.
    GeoBox(6.5, 37.1, 62.0, 92.8),
    # Sri Lanka.
    GeoBox(5.8, 9.9, 79.6, 81.95),
    # SE Asia LHT bloc: Thailand, Malaysia, Singapore, Indonesia,
    # Brunei, East Timor.
    GeoBox(-11.0, 20.5, 95.0, 119.5),
    # Southern Africa: South Africa, Lesotho, Eswatini, Namibia,
    # Botswana, Zimbabwe, southern Mozambique.
    GeoBox(-35.0, -16.0, 11.0, 41.0),
    # Eastern Africa LHT: Zambia, Malawi, Tanzania, Kenya, Uganda,
    # northern Mozambique.
    GeoBox(-16.0, 5.2, 28.5, 42.0),
    # Guyana (the only LHT country in mainland South America).
    GeoBox(1.0, 8.7, -61.5, -56.4),
]


def driving_side(lat: float, lon: float) -> str:
    """Return 'left' or 'right' for a coordinate. Right-hand traffic is the
    default; only points inside a known left-hand-traffic region override
    it. Mirrors `DrivingSide.at(_:)` in Swift."""
    for box in LEFT_HAND_REGIONS:
        if box.contains(lat, lon):
            return "left"
    return "right"


def roundabout_clockwise(lat: float, lon: float) -> bool:
    """True where roundabouts circulate clockwise (left-hand traffic).
    Mirrors `DrivingSide.roundaboutClockwise`."""
    return driving_side(lat, lon) == "left"
