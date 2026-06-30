"""
Tests for the posted-speed-limit sign feature.

The Swift side spans four files:
  - `SpeedLimitService.swift` — Overpass fetch + the pure map-match math
    (`distancePointToSegment`, `nearestLimit`, `parseMaxspeedKmh`).
  - `MapViewSource.swift` — the renderer: `recomputeSpeedLimit` (snap +
    hysteresis + over-limit), `drawSpeedLimitSign` (the traffic-sign disc),
    and the weather-pill collision bump.
  - `DashNavSettings.swift` — the 3-way `SpeedLimitDisplay` enum + persist.
  - `AppStatus.swift` / `ActiveNavLoop.swift` — prefetch + per-tick config.

None of that compiles on the Linux dev host, so this file does two things:

  1. Mirrors the map-match geometry + the maxspeed parser + the over-limit
     and snap/hysteresis decision in Python and pins them with cases whose
     answers are obvious by construction. If the Swift math drifts, the
     mirror (kept identical) and these assertions disagree.

  2. Source drift-guards: greps the Swift so the wiring that makes the
     feature actually reach the screen can't be silently deleted — the
     traffic-sign colours/geometry, the bottom-right anchor, the weather
     collision bump, the draw call in the compose pipeline, the 3 display
     modes, and the settings persistence keys.

Compilation itself is verified by the macOS `xcodebuild` CI job, not here.
"""

from __future__ import annotations

import math
import re
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[3]
APP = REPO / "TripperDashPP"


# --- Source loaders -------------------------------------------------------

def _src(rel: str) -> str:
    p = APP / rel
    assert p.exists(), f"missing source file: {rel}"
    return p.read_text(encoding="utf-8")


def service_src() -> str:
    return _src("RideAlerts/SpeedLimitService.swift")


def mapsource_src() -> str:
    return _src("Map/MapViewSource.swift")


def settings_src() -> str:
    return _src("Navigation/Models/DashNavSettings.swift")


def appstatus_src() -> str:
    return _src("App/AppStatus.swift")


def navloop_src() -> str:
    return _src("Navigation/ActiveNavLoop.swift")


# --- Reference implementation (mirrors SpeedLimitService.swift) -----------

def distance_point_to_segment(p, a, b) -> float:
    """Mirror of SpeedLimitService.distancePointToSegment — local
    equirectangular projection with p at the origin, clamp t to [0,1]."""
    m_per_deg_lat = 111_320.0
    m_per_deg_lon = 111_320.0 * math.cos(math.radians(p[0]))
    ax = (a[1] - p[1]) * m_per_deg_lon
    ay = (a[0] - p[0]) * m_per_deg_lat
    bx = (b[1] - p[1]) * m_per_deg_lon
    by = (b[0] - p[0]) * m_per_deg_lat
    dx, dy = bx - ax, by - ay
    seg_len_sq = dx * dx + dy * dy
    if seg_len_sq < 1e-9:
        return math.hypot(-ax, -ay)
    t = ((-ax) * dx + (-ay) * dy) / seg_len_sq
    t = max(0.0, min(1.0, t))
    proj_x = ax + t * dx
    proj_y = ay + t * dy
    return math.hypot(-proj_x, -proj_y)


def nearest_limit(point, ways):
    """Mirror of SpeedLimitService.nearestLimit. `ways` is a list of
    (kmh, [coords]). Returns (kmh, distance) or None."""
    best = None
    for kmh, coords in ways:
        if len(coords) < 2:
            continue
        for i in range(len(coords) - 1):
            d = distance_point_to_segment(point, coords[i], coords[i + 1])
            if best is None or d < best[1]:
                best = (kmh, d)
    return best


def nearest_road_distance(point, roads):
    """Mirror of SpeedLimitService.nearestRoadDistance. `roads` is a list
    of coord-lists (bare geometry, no limit). Returns the min distance or
    None."""
    best = None
    for coords in roads:
        if len(coords) < 2:
            continue
        for i in range(len(coords) - 1):
            d = distance_point_to_segment(point, coords[i], coords[i + 1])
            if best is None or d < best:
                best = d
    return best


# Shadow-guard thresholds — mirror MapViewSource.
SHADOW_ABS_M = 12.0
SHADOW_RATIO = 2.0


def is_shadowed(match_distance, nearest_road):
    """Mirror of MapViewSource.isShadowed. The tagged match is a
    parallel-road artefact when a road is closer by >= SHADOW_ABS_M AND by
    a factor >= SHADOW_RATIO. None nearest_road never shadows."""
    if nearest_road is None:
        return False
    if not (nearest_road < match_distance - SHADOW_ABS_M):
        return False
    return match_distance >= nearest_road * SHADOW_RATIO


def parse_maxspeed_kmh(raw):
    """Mirror of SpeedLimitService.parseMaxspeedKmh."""
    if raw is None:
        return None
    raw = raw.strip()
    if not raw:
        return None
    lower = raw.lower()
    digits = ""
    for ch in lower:
        if ch.isdigit():
            digits += ch
        else:
            break
    if not digits:
        return None
    value = int(digits)
    if value <= 0:
        return None
    if "mph" in lower:
        return round(value * 1.609344)
    return value


# Snap / hysteresis constants — mirror MapViewSource.
SNAP_M = 35.0
RELEASE_M = 80.0


def acquire_decision(have_sign: bool, distance: float) -> bool:
    """Mirror of the snap/hysteresis branch in recomputeSpeedLimit:
    threshold is RELEASE when a sign is already shown, else SNAP."""
    threshold = RELEASE_M if have_sign else SNAP_M
    return distance <= threshold


def is_over_limit(speed_mps: float, limit_kmh: int, tol_kmh: float) -> bool:
    """Mirror of the over-limit check. speed -1 (unknown) → not over."""
    if speed_mps < 0:
        return False
    return speed_mps * 3.6 > limit_kmh + tol_kmh


# --- Geometry tests -------------------------------------------------------

def test_point_on_segment_is_zero_distance():
    # Point exactly on a horizontal segment.
    a = (50.0000, 14.0000)
    b = (50.0000, 14.0020)
    p = (50.0000, 14.0010)
    assert distance_point_to_segment(p, a, b) < 0.5


def test_perpendicular_distance_matches_offset():
    # Point offset ~? north of an east-west segment. 0.0009° lat ≈ 100 m.
    a = (50.0000, 14.0000)
    b = (50.0000, 14.0020)
    p = (50.0009, 14.0010)
    d = distance_point_to_segment(p, a, b)
    assert abs(d - 0.0009 * 111_320.0) < 2.0  # ~100 m, within 2 m


def test_distance_clamps_to_endpoint():
    # Point beyond the segment's end projects onto the endpoint, not the
    # infinite line.
    a = (50.0000, 14.0000)
    b = (50.0000, 14.0010)
    p = (50.0000, 14.0030)  # well past b
    d = distance_point_to_segment(p, a, b)
    # Distance to b (the nearer endpoint), ~0.0020° lon east.
    expect = 0.0020 * 111_320.0 * math.cos(math.radians(50.0))
    assert abs(d - expect) < 2.0


def test_nearest_limit_picks_closest_way():
    here = (50.0000, 14.0010)
    near = (50, [(50.00005, 14.0000), (50.00005, 14.0020)])   # ~5.5 m away
    far = (90, [(50.0050, 14.0000), (50.0050, 14.0020)])      # ~550 m away
    match = nearest_limit(here, [far, near])
    assert match is not None
    assert match[0] == 50           # picks the near way's limit
    assert match[1] < 10            # and reports the small distance


def test_nearest_limit_empty_is_none():
    assert nearest_limit((50.0, 14.0), []) is None


# --- maxspeed parser tests ------------------------------------------------

@pytest.mark.parametrize("raw,expected", [
    ("50", 50),
    ("50 km/h", 50),
    ("80;100", 80),       # multiple → leading value
    ("30 mph", 48),       # 30 * 1.609344 = 48.28 → 48
    ("none", None),
    ("walk", None),
    ("CZ:urban", None),   # implied zone, not a numeric limit
    ("", None),
    (None, None),
    ("0", None),          # zero is not a real limit
])
def test_parse_maxspeed(raw, expected):
    assert parse_maxspeed_kmh(raw) == expected


# --- Hysteresis + over-limit tests ----------------------------------------

def test_hysteresis_acquire_needs_snap():
    # No sign yet: must be within 35 m to acquire.
    assert acquire_decision(have_sign=False, distance=30) is True
    assert acquire_decision(have_sign=False, distance=40) is False


def test_hysteresis_holds_until_release():
    # Sign already shown: holds out to 80 m before dropping.
    assert acquire_decision(have_sign=True, distance=60) is True
    assert acquire_decision(have_sign=True, distance=90) is False


def test_hysteresis_band_prevents_flicker():
    # In the 35–80 m band the decision depends on the prior state — that's
    # the whole anti-flicker point.
    assert acquire_decision(have_sign=False, distance=50) is False
    assert acquire_decision(have_sign=True, distance=50) is True


def test_over_limit_tolerance():
    # 50 km/h limit, 3 km/h tolerance → must exceed 53 to count as over.
    assert is_over_limit(speed_mps=50 / 3.6, limit_kmh=50, tol_kmh=3) is False  # exactly 50
    assert is_over_limit(speed_mps=52 / 3.6, limit_kmh=50, tol_kmh=3) is False  # +2, within tol
    assert is_over_limit(speed_mps=54 / 3.6, limit_kmh=50, tol_kmh=3) is True   # +4, over
    assert is_over_limit(speed_mps=-1, limit_kmh=50, tol_kmh=3) is False        # unknown speed


# --- Swift source drift guards --------------------------------------------

def test_service_queries_ways_with_geometry():
    src = service_src()
    # Must query drivable WAYS (limits live on roads, not nodes) with inline
    # geometry. As of the shadow guard we fetch ALL drivable highways (not
    # just maxspeed-tagged ones) so the map-match can tell which road the
    # rider is really on, so the query is a `highway` regex, and the
    # `maxspeed` read happens in the split/parse step instead.
    assert 'way["highway"' in src
    assert "residential" in src and "tertiary" in src   # drivable classes
    assert "out geom;" in src
    assert 'parseMaxspeedKmh(e.tags?["maxspeed"])' in src  # limit still read per-way
    # Pure, testable map-match entry points exist with the names the
    # renderer calls.
    assert "func nearestLimit(" in src
    assert "func nearestRoadDistance(" in src            # shadow guard input
    assert "func distancePointToSegment(" in src
    assert "func parseMaxspeedKmh(" in src


def test_sign_is_a_traffic_sign_bottom_right():
    src = mapsource_src()
    assert "func drawSpeedLimitSign(" in src
    # White field + red ring + black number = a European limit sign.
    assert "setStrokeColor(CGColor(red: 0.86" in src   # red ring
    assert "strokeEllipse(in:" in src                  # ring is a stroked circle
    assert "UIColor.black" in src                       # black number
    # Bottom-right anchor: x and y both subtract from the frame extent.
    assert "frameSize.width - margin - r" in src
    assert "frameSize.height - margin - r" in src


def test_sign_drawn_in_compose_pipeline():
    src = mapsource_src()
    # The draw call must actually be invoked, AFTER the weather pill so the
    # sign owns the corner.
    assert "drawSpeedLimitSign(into: ctx)" in src
    weather_at = src.index("drawWeatherAlert(into: ctx)")
    sign_at = src.index("drawSpeedLimitSign(into: ctx)")
    assert weather_at < sign_at, "sign must be composed after the weather pill"


def test_weather_pill_collision_bump():
    src = mapsource_src()
    # When the sign shows, the weather pill is lifted by the sign height.
    assert "signBump" in src
    assert "shouldDrawSpeedLimit" in src
    assert "speedLimitSignDiameter" in src
    # The bump is applied to the weather pill's vertical origin.
    assert re.search(r"originY\s*=\s*frameSize\.height\s*-\s*margin\s*-\s*pillH\s*-\s*signBump", src)


def test_three_display_modes_wired():
    src = mapsource_src()
    # shouldDrawSpeedLimit honours all three modes.
    assert '"always"' in src
    assert '"overOnly"' in src
    assert "isOverSpeedLimit" in src
    # off → never draws (the default branch).
    assert "shouldDrawSpeedLimit" in src


def test_snap_release_constants_present():
    src = mapsource_src()
    # The mirror's constants must match the Swift ones.
    assert "limitSnapMeters: Double = 35" in src
    assert "limitReleaseMeters: Double = 80" in src


def test_settings_enum_and_persist():
    src = settings_src()
    assert "enum SpeedLimitDisplay" in src
    for case in ("case off", "case always", "case overOnly"):
        assert case in src
    # Default is .always and tolerance defaults to 3.
    assert "speedLimitDisplay: SpeedLimitDisplay = .always" in src
    assert "speedLimitOverToleranceKmh: Double = 3" in src
    # Persisted (optional for forward-compat) + restored with defaults.
    assert "speedLimitDisplay: SpeedLimitDisplay?" in src
    assert "p.speedLimitDisplay ?? .always" in src
    assert "p.speedLimitOverToleranceKmh ?? 3" in src


def test_prefetch_and_per_tick_plumbing():
    appsrc = appstatus_src()
    # Prefetch on route install + a config push that survives an empty
    # fetch.
    assert "func prefetchSpeedLimits(" in appsrc
    assert "SpeedLimitService.shared.limitsAlong(" in appsrc
    assert "func pushSpeedLimitConfig(" in appsrc
    # Mode observer clears the sign when off.
    assert "observeSpeedLimitMode" in appsrc

    navsrc = navloop_src()
    # Per-tick config push keeps the mode/units live mid-ride.
    assert "setSpeedLimitConfig(" in navsrc


def test_picker_in_settings_ui():
    src = _src("UI/StreamingView.swift")
    assert 'Picker("Speed limit"' in src
    assert "SpeedLimitDisplay.allCases" in src


# --- Sign number fit (rider feedback: "90 leze do červeného kruhu") -------

def _sign_number_corner_clears_ring(label: str, d: float) -> tuple[float, float]:
    """Mirror of drawSpeedLimitSign's width-fit number sizing. Returns
    (corner_radius_of_text_box, inner_white_field_radius). The number's
    bounding-box corner must stay inside the white field (< field radius)
    so the glyphs never touch the red ring, for any value.

    SF Pro bold metrics as em fractions (predikce z typografie, ne HW
    měření — the real glyph box is verified by the macOS xcodebuild CI).
    """
    ring_w = d * 0.16
    inner_field_d = d - 2 * ring_w
    max_text_w = inner_field_d * 0.72
    font_size = d * 0.50

    # Per-glyph advance: '1' is narrow, other digits ~0.58 em; cap height
    # ~0.714 em for SF Pro bold.
    def text_w(fs: float) -> float:
        return sum((0.33 if ch == "1" else 0.58) * fs for ch in label)

    w = text_w(font_size)
    if w > max_text_w:               # width-fit shrink, mirrors the Swift
        font_size *= max_text_w / w
        w = text_w(font_size)
    cap_h = 0.714 * font_size
    corner = math.hypot(w / 2, cap_h / 2)
    field_r = inner_field_d / 2
    return corner, field_r


@pytest.mark.parametrize("label", ["30", "50", "90", "120", "130", "31", "70"])
def test_sign_number_stays_inside_ring(label):
    # At the shipped diameter (62), every realistic limit's number box must
    # clear the white field with a little margin — no kissing the red ring.
    corner, field_r = _sign_number_corner_clears_ring(label, d=62)
    assert corner < field_r, f"'{label}' number box ({corner:.1f}) overruns field ({field_r:.1f})"
    assert field_r - corner >= 1.5, f"'{label}' too tight to the ring (gap {field_r - corner:.1f}px)"


def test_sign_uses_width_fit_not_fixed_fraction():
    """The renderer must width-fit the number to the inner field, not use
    the old fixed `d * 0.48 / 0.40` fraction that scaled with the disc and
    so always kept the same ring overlap (the '90 kisses the ring' bug)."""
    src = mapsource_src()
    assert "let innerFieldD = d - 2 * ringW" in src, "inner white-field width not derived"
    assert "let maxTextWidth = innerFieldD" in src, "number not width-fit to the field"
    assert "fontSize *= maxTextWidth / textSize.width" in src, "missing shrink-to-fit step"
    # The old fixed-fraction sizing must be gone so it can't regress.
    assert "label.count >= 3 ? d * 0.40 : d * 0.48" not in src, "old fixed-fraction sizing still present"


# --- Shadow guard: don't show a parallel road's limit -----------------
# Bug report: at 50.23286244880771, 14.17603391165378 (a 50 km/h obec)
# the dash showed 90. Overpass shows the rider sits 0.3 m from an UNTAGGED
# residential street, while a `maxspeed=90` tertiary (III/10142) runs 28 m
# away. The old map-match could only see tagged ways, so it snapped to the
# 90 (28 m < 35 m snap). The shadow guard suppresses that: a much closer
# road means you're on a different road than the tagged one.

def test_isShadowed_unit_thresholds():
    # Closer road must beat the match by >= 12 m AND >= 2x to shadow it.
    assert is_shadowed(28.0, 0.3) is True       # the real bug: 28 vs 0.3
    assert is_shadowed(30.0, 5.0) is True        # 5 < 18 and 30 >= 10
    # Not shadowed: gap too small (roads side by side) ...
    assert is_shadowed(20.0, 10.0) is False      # 10 is not < 20-12=8
    # ... or ratio too small even with a big absolute gap is impossible
    # here, but a near-equal pair (rider on the tagged road) never shadows:
    assert is_shadowed(15.0, 15.0) is False
    assert is_shadowed(40.0, 39.0) is False
    # No road geometry loaded → guard is a no-op (never suppress).
    assert is_shadowed(28.0, None) is False


def test_isShadowed_rider_on_the_tagged_road():
    # When the rider is genuinely on the tagged road, nearestRoad ≈
    # matchDistance (the tagged way IS a road), so it must never shadow.
    for d in (2.0, 8.0, 15.0, 30.0):
        assert is_shadowed(d, d) is False
        assert is_shadowed(d, d - 0.5) is False


def test_real_bug_point_50_2328_14_1760_is_suppressed():
    """End-to-end mirror at the reported coordinates using OSM-derived
    geometry: a 90 tertiary 28 m away, an untagged residential 0.3 m away.
    The match finds 90; the shadow guard must then suppress it."""
    p = (50.23286244880771, 14.17603391165378)

    # A short segment of the untagged residential running ~0.3 m off the
    # point (roughly E-W through the point's latitude).
    residential = [
        (50.232862, 14.175800),
        (50.232863, 14.176400),
    ]
    # The tertiary III/10142 with maxspeed=90, offset ~28 m north.
    # 28 m ≈ 0.000251° latitude.
    tertiary_90 = [
        (50.233114, 14.175700),
        (50.233115, 14.176400),
    ]

    match = nearest_limit(p, [(90, tertiary_90)])
    assert match is not None
    assert match[0] == 90                       # the wrong number it would show
    assert 24 <= match[1] <= 32, f"tertiary ~28 m, got {match[1]:.1f}"

    nearest_road = nearest_road_distance(p, [residential, tertiary_90])
    assert nearest_road is not None
    assert nearest_road < 2.0, f"on the residential (~0.3 m), got {nearest_road:.1f}"

    # The guard must fire → no false 90.
    assert is_shadowed(match[1], nearest_road) is True


def test_genuine_tagged_road_still_shows():
    """Inverse: when the rider is on a tagged 50 road (no closer untagged
    road), the limit must still display — the guard mustn't over-suppress."""
    p = (50.0, 14.0)
    road_50 = [(49.99995, 14.0), (50.00005, 14.0)]   # passes through point
    match = nearest_limit(p, [(50, road_50)])
    assert match is not None and match[0] == 50
    # Only roads present is the tagged one itself → nearestRoad == match dist.
    nearest_road = nearest_road_distance(p, [road_50])
    assert is_shadowed(match[1], nearest_road) is False


def test_mapsource_wires_shadow_guard():
    """The renderer must actually call the guard in recomputeSpeedLimit and
    bail when shadowed — not just define it."""
    src = mapsource_src()
    assert "func isShadowed(" in src
    assert "nearestRoadDistance(" in src
    assert "Self.isShadowed(matchDistance:" in src
    # Stored road geometry the guard reads.
    assert "speedLimitRoads" in src


def test_service_shadow_plumbing():
    """Service must return roads alongside limits and split them out."""
    src = service_src()
    assert "struct SpeedLimitData" in src
    assert "struct RoadShape" in src
    assert "func split(" in src
    assert "func nearestRoadDistance(" in src
