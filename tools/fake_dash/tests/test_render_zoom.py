"""
Tests for the speed-adaptive + maneuver-approach zoom curve and the
forward-bias / puck-scale render constants in `MapViewSource.swift`.

These are pure-math UX tunables (no wire format), but they drive what the
rider actually sees on the dash, so we pin the curve shape and the Swift
constants here. fake_dash can't run Swift; we mirror the formulas and
assert the Swift source still carries the same numbers (a refactor that
silently reverts the city zoom-in would be caught here).

Rider feedback driving these (2026-06):
  - "city map too zoomed out, hard to see where to go" → wider zoom range,
    tighter at low speed.
  - "zoom in as the turn approaches" → maneuverZoomBoost.
  - "puck too high, push it down so we see more ahead" → forwardBias 0.28.
  - "make the chevron a bit bigger" → puckScale 1.35.
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest


def _map_source_src() -> str:
    here = Path(__file__).resolve()
    repo_root = here.parents[3]
    return (repo_root / "TripperDashPP" / "Map" / "MapViewSource.swift").read_text(encoding="utf-8")


# ----------------------------------------------------------------------
# Mirror of the Swift zoom math.
# ----------------------------------------------------------------------

def speed_zoom(kmh: float) -> float:
    """Mirror of targetZoom's speed term (before the maneuver boost)."""
    raw = 2.0 - kmh * 0.00923
    return min(max(raw, 0.8), 2.0)


def maneuver_boost(dist_next_m: float, *, navigating: bool = True) -> float:
    """Mirror of maneuverZoomBoost()."""
    if not navigating or dist_next_m <= 0:
        return 1.0
    start, full, max_boost = 200.0, 40.0, 1.45
    if dist_next_m >= start:
        return 1.0
    if dist_next_m <= full:
        return max_boost
    t = (start - dist_next_m) / (start - full)
    return 1.0 + (max_boost - 1.0) * t


def target_zoom(kmh: float, dist_next_m: float, navigating: bool = True) -> float:
    return speed_zoom(kmh) * maneuver_boost(dist_next_m, navigating=navigating)


# ----------------------------------------------------------------------
# Speed → zoom curve.
# ----------------------------------------------------------------------

@pytest.mark.parametrize("kmh,expected", [
    (0, 2.0),       # standstill / city — tightest
    (60, 1.4462),   # rural
    (130, 0.8),     # highway — clamped to floor
    (200, 0.8),     # over-fast — still floored
])
def test_speed_zoom_curve(kmh, expected):
    assert speed_zoom(kmh) == pytest.approx(expected, abs=1e-3)


def test_city_is_more_zoomed_in_than_before():
    """Regression for the rider complaint: standstill zoom must be tighter
    than the old 1.5 ceiling."""
    assert speed_zoom(0) > 1.5
    # And monotonically decreasing with speed.
    assert speed_zoom(0) > speed_zoom(50) > speed_zoom(100) >= speed_zoom(130)


# ----------------------------------------------------------------------
# Maneuver-approach boost.
# ----------------------------------------------------------------------

@pytest.mark.parametrize("dist,expected", [
    (500, 1.0),     # far — no boost
    (200, 1.0),     # right at the start of the ramp
    (120, 1.225),   # mid-ramp
    (40, 1.45),     # fully boosted
    (10, 1.45),     # past the turn point — still max
    (0, 1.0),       # zero/invalid distance → no boost
])
def test_maneuver_boost_ramp(dist, expected):
    assert maneuver_boost(dist) == pytest.approx(expected, abs=1e-3)


def test_no_boost_when_not_navigating():
    assert maneuver_boost(50, navigating=False) == 1.0


def test_boost_is_monotonic_as_turn_approaches():
    vals = [maneuver_boost(d) for d in (200, 160, 120, 80, 40)]
    assert vals == sorted(vals)            # non-decreasing
    assert vals[0] == 1.0 and vals[-1] == pytest.approx(1.45)


def test_combined_zoom_in_city_near_turn():
    """City speed + imminent turn = the tightest the map ever gets."""
    z = target_zoom(kmh=15, dist_next_m=30)
    assert z > 2.5                          # ~1.86 speed × 1.45 boost
    # Still bounded — never absurd.
    assert z < 3.0


# ----------------------------------------------------------------------
# Swift-source sync: the constants must match this mirror.
# ----------------------------------------------------------------------

def test_swift_zoom_constants_match_mirror():
    src = _map_source_src()
    # slope and base of the speed ramp
    assert "2.0 - CGFloat(kmh) * 0.00923" in src, "speed-zoom slope/base drifted"
    assert "min(max(raw, 0.8), 2.0)" in src, "speed-zoom clamp drifted"
    # maneuver boost knobs
    assert "boostStartMeters: CGFloat = 200" in src
    assert "boostFullMeters: CGFloat = 40" in src
    assert "maxManeuverBoost: CGFloat = 1.45" in src


def test_swift_forward_bias_and_puck_scale():
    src = _map_source_src()
    m = re.search(r"forwardBiasFraction:\s*CGFloat\s*=\s*([\d.]+)", src)
    assert m and float(m.group(1)) == pytest.approx(0.28), "forward bias must be 0.28"
    m2 = re.search(r"puckScale:\s*CGFloat\s*=\s*([\d.]+)", src)
    assert m2 and float(m2.group(1)) == pytest.approx(1.35), "puck scale must be 1.35"


def test_swift_zoom_in_lerps_faster_than_out():
    """The approach boost must land before the turn — zooming in uses a
    bigger lerp factor than zooming out."""
    src = _map_source_src()
    assert "zoomingIn ? 0.15 : 0.05" in src, "asymmetric zoom lerp drifted"


# ----------------------------------------------------------------------
# Route line thickness — constant on-screen px regardless of zoom.
# ----------------------------------------------------------------------

def route_line_width(screen_px: float, zoom: float) -> float:
    """Mirror of `setLineWidth(routeLineScreenPx / currentZoom)`."""
    return screen_px / zoom


@pytest.mark.parametrize("zoom", [0.8, 1.0, 1.4, 2.0, 2.9])
def test_route_line_constant_on_screen(zoom):
    """Stroked inside the zoom scale, so width/zoom * zoom == constant px."""
    screen_px = 5.0
    on_screen = route_line_width(screen_px, zoom) * zoom
    assert on_screen == pytest.approx(screen_px)


def test_route_line_thinner_than_old_fixed_width():
    """At city zoom the old fixed width 8 rendered ~16 px (as thick as a
    road). The new constant 5 px is well under that."""
    assert 5.0 < 8 * 2.0     # new on-screen vs old at 2.0x


def test_swift_route_line_constant_and_divides_by_zoom():
    src = _map_source_src()
    m = re.search(r"routeLineScreenPx:\s*CGFloat\s*=\s*([\d.]+)", src)
    assert m and float(m.group(1)) == pytest.approx(5.0), "route line px must be 5.0"
    # Both dash render paths must divide by zoom (constant on-screen width).
    assert src.count("routeLineScreenPx / currentZoom") == 2, (
        "both tile-cache and vector-only paths must stroke "
        "routeLineScreenPx / currentZoom"
    )
