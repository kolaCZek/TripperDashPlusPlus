"""
Python mirror of `TripperDashPP/Navigation/Models/ManeuverGeometry.swift`.

fake_dash can't run Swift, but the geometry that decides turn direction
is pure math — we mirror it here and table-test it so a future edit to
the Swift thresholds / bearing math that would flip a turn direction is
caught here instead of by Martin squinting at a dash on a moving bike.

This is the SAME discipline used for the roundabout parser and the
secondary-maneuver gate: keep a faithful Python twin of the pure logic,
pin it with tests, and add a Swift-source sync assertion so the two
can't drift.

Kept LOCAL to the tests package (not shipped in fake_dash proper) — it
exists only to validate the Swift port.
"""

from __future__ import annotations

import math

# Must match `ManeuverGeometry.anchorDistanceMeters` in Swift (LONG anchor).
ANCHOR_DISTANCE_M = 18.0

# Must match `ManeuverGeometry.shortAnchorDistanceMeters` in Swift.
SHORT_ANCHOR_DISTANCE_M = 8.0

# Must match `ManeuverGeometry.anchorDisagreementDeg` in Swift.
ANCHOR_DISAGREEMENT_DEG = 15.0


def bearing(a: tuple[float, float], b: tuple[float, float]) -> float:
    """Initial great-circle bearing a->b, degrees, 0=N, 90=E, clockwise."""
    lat1, lat2 = math.radians(a[0]), math.radians(b[0])
    dlon = math.radians(b[1] - a[1])
    y = math.sin(dlon) * math.cos(lat2)
    x = math.cos(lat1) * math.sin(lat2) - math.sin(lat1) * math.cos(lat2) * math.cos(dlon)
    return (math.degrees(math.atan2(y, x)) + 360) % 360


def haversine(a: tuple[float, float], b: tuple[float, float]) -> float:
    R = 6_371_000.0
    lat1, lat2 = math.radians(a[0]), math.radians(b[0])
    dlat = math.radians(b[0] - a[0])
    dlon = math.radians(b[1] - a[1])
    h = math.sin(dlat / 2) ** 2 + math.cos(lat1) * math.cos(lat2) * math.sin(dlon / 2) ** 2
    return 2 * R * math.asin(min(1.0, math.sqrt(h)))


def signed_delta(i: float, o: float) -> float:
    """Signed smallest delta i->o in (-180, 180]. + = right, - = left."""
    return (o - i + 540) % 360 - 180


def incoming_bearing(prev_pts: list[tuple[float, float]],
                     min_dist: float = ANCHOR_DISTANCE_M) -> float | None:
    """Walk BACKWARD from the node (last vertex) until min_dist covered."""
    node = prev_pts[-1]
    acc = 0.0
    anchor = prev_pts[0]
    i = len(prev_pts) - 1
    while i > 0:
        acc += haversine(prev_pts[i], prev_pts[i - 1])
        anchor = prev_pts[i - 1]
        if acc >= min_dist:
            break
        i -= 1
    if haversine(anchor, node) < 1.0:
        return None
    return bearing(anchor, node)


def outgoing_bearing(cur_pts: list[tuple[float, float]],
                     min_dist: float = ANCHOR_DISTANCE_M) -> float | None:
    """Walk FORWARD from the node (first vertex) until min_dist covered."""
    node = cur_pts[0]
    acc = 0.0
    anchor = cur_pts[-1]
    i = 0
    while i < len(cur_pts) - 1:
        acc += haversine(cur_pts[i], cur_pts[i + 1])
        anchor = cur_pts[i + 1]
        if acc >= min_dist:
            break
        i += 1
    if haversine(node, anchor) < 1.0:
        return None
    return bearing(node, anchor)


def _signed_angle_at(prev_pts: list[tuple[float, float]],
                     cur_pts: list[tuple[float, float]],
                     anchor: float) -> float | None:
    """Signed turn angle for ONE anchor distance, or None if either side
    lacks enough geometry. Mirrors `ManeuverGeometry.signedAngle`."""
    ib = incoming_bearing(prev_pts, anchor)
    ob = outgoing_bearing(cur_pts, anchor)
    if ib is None or ob is None:
        return None
    return signed_delta(ib, ob)


def signed_turn_angle(prev_pts: list[tuple[float, float]] | None,
                      cur_pts: list[tuple[float, float]]) -> float | None:
    """Adaptive short/long anchor scheme — mirrors
    `ManeuverGeometry.signedTurnAngle`.

    Sample at both the long (jitter-robust) and short (turn-in) anchors.
    Keep the long read when they agree; fall back to the sharper short
    read when the long anchor has reached past the corner into the next
    road's curvature (disagreement > ANCHOR_DISAGREEMENT_DEG). On clean
    maneuvers both reads are identical, so this is a strict superset of
    the old fixed-18 m behaviour.
    """
    if not prev_pts or len(prev_pts) < 2 or len(cur_pts) < 2:
        return None
    long = _signed_angle_at(prev_pts, cur_pts, ANCHOR_DISTANCE_M)
    short = _signed_angle_at(prev_pts, cur_pts, SHORT_ANCHOR_DISTANCE_M)
    if long is not None and short is not None:
        return short if abs(signed_delta(long, short)) > ANCHOR_DISAGREEMENT_DEG else long
    return long if long is not None else short


# Turn buckets — must match `ManeuverGeometry.turn(forSignedAngle:)`.
def turn_for_angle(angle: float | None) -> str | None:
    if angle is None:
        return None
    a = angle
    mag = abs(a)
    if mag >= 160:
        return "uTurnRight" if a > 0 else "uTurnLeft"
    if mag >= 110:
        return "sharpRight" if a > 0 else "sharpLeft"
    if mag >= 35:
        return "right" if a > 0 else "left"
    if mag >= 12:
        return "slightRight" if a > 0 else "slightLeft"
    return "straight"


def turn(prev_pts: list[tuple[float, float]] | None,
         cur_pts: list[tuple[float, float]]) -> str | None:
    return turn_for_angle(signed_turn_angle(prev_pts, cur_pts))


# ----------------------------------------------------------------------
# Synthetic-coordinate helper for tests.
# ----------------------------------------------------------------------

def offset(lat: float, lon: float, brg_deg: float, dist_m: float) -> tuple[float, float]:
    """Point `dist_m` from (lat,lon) along bearing `brg_deg`."""
    R = 6_371_000.0
    br = math.radians(brg_deg)
    la = math.radians(lat)
    lo = math.radians(lon)
    la2 = math.asin(math.sin(la) * math.cos(dist_m / R)
                    + math.cos(la) * math.sin(dist_m / R) * math.cos(br))
    lo2 = lo + math.atan2(
        math.sin(br) * math.sin(dist_m / R) * math.cos(la),
        math.cos(dist_m / R) - math.sin(la) * math.sin(la2),
    )
    return (math.degrees(la2), math.degrees(lo2))
