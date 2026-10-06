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
    ax = math.remainder(a[1] - p[1], 360) * m_per_deg_lon
    ay = (a[0] - p[0]) * m_per_deg_lat
    bx = math.remainder(b[1] - p[1], 360) * m_per_deg_lon
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
    # (Also by the progress-bar zone — whichever is taller; see
    # test_overlay_layout.py.)
    assert re.search(r"originY\s*=\s*frameSize\.height\s*-\s*margin\s*-\s*pillH\s*-\s*max\(signBump, barBump\)", src)


def test_section_panel_lifts_weather_pill_even_without_sign():
    # The average-speed panel sits in the sign's row. With the sign hidden
    # ("overOnly" under the limit / "off") the pill used to drop onto that
    # row and cover the panel — the bump must fire for EITHER element, and
    # for neither must stay 0 (pill back in the corner, as before).
    from tests.swift_source import decl_body, strip_comments
    body = strip_comments(decl_body(mapsource_src(), "fileprivate func drawWeatherAlert(into ctx: CGContext)"))
    assert re.search(
        r"let signBump: CGFloat = \(shouldDrawSpeedLimit \|\| speedSection != nil\)\s*"
        r"\? Self\.speedLimitSignDiameter \+ 8\s*: 0", body)


def test_section_panel_drawn_in_sign_row():
    from tests.swift_source import decl_body, strip_comments
    src = mapsource_src()
    assert src.index("drawSpeedLimitSign(into: ctx)") < src.index("drawSpeedSectionPanel(into: ctx)")
    body = strip_comments(decl_body(src, "fileprivate func drawSpeedSectionPanel(into ctx: CGContext)"))
    assert "guard let r = speedSection else { return }" in body
    # Left of the sign's slot, top-aligned with the sign (not above it —
    # the space above the sign's right side is outside the round glass).
    assert "frameSize.width - margin - Self.speedLimitSignDiameter - Self.sectionPanelGap - size.width" in body
    assert "y: signTop - 2," in body


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


def test_section_panel_geometry_fits_round_glass():
    # Recompute the panel rect from the Swift constants and check it against
    # the visible circle measured on a real dash photo (centre ~(263, 267),
    # r ~265 px in 526x300 frame pixels) and the progress-bar chevron.
    import math
    src = mapsource_src()
    w, h = map(int, re.search(r"sectionPanelSize = CGSize\(width: (\d+), height: (\d+)\)", src).groups())
    gap = int(re.search(r"sectionPanelGap: CGFloat = (\d+)", src).group(1))
    sign = int(re.search(r"speedLimitSignDiameter: CGFloat = (\d+)", src).group(1))
    margin = int(re.search(r"speedLimitSignMargin: CGFloat = (\d+)", src).group(1))
    x0 = 526 - margin - sign - gap - w
    y0 = 300 - margin - sign - 2
    corners = [(x0, y0), (x0 + w, y0), (x0, y0 + h), (x0 + w, y0 + h)]
    assert all(math.hypot(x - 263, y - 267) < 265 - 30 for x, y in corners)
    chevron_top = 300 - 12 - 6 + 3 - 9          # bar y + h/2 - arrowHalfH
    assert y0 + h < chevron_top
    assert x0 + w + gap <= 526 - margin - sign   # clear of the sign disc


# --- Average-speed section wiring ------------------------------------------

def test_new_nav_loop_is_seeded_with_last_camera_prefetch():
    # The prefetch usually lands (disk-cache hit) before startStreaming
    # creates the loop — the loop must be seeded on creation, not only
    # from the prefetch completion.
    from tests.swift_source import strip_comments
    src = strip_comments(_src("App/AppStatus.swift"))
    m = re.search(r"private var activeNavLoop: ActiveNavLoop\? \{\s*didSet \{(.*?)\}\s*\}", src, re.S)
    assert m, "activeNavLoop lost its seeding didSet"
    assert "activeNavLoop?.setSpeedSections(speedCameraData.sections)" in m.group(1)
    assert "activeNavLoop?.setSpeedCameras(speedCameraData.cameras)" in m.group(1)
    assert "self.speedCameraData = effective" in src


def test_section_panel_follows_camera_toggle():
    from tests.swift_source import decl_body, strip_comments
    body = strip_comments(decl_body(_src("Navigation/ActiveNavLoop.swift"),
                                    "private func updateSpeedSection()"))
    assert re.search(r"guard settings\.speedCamerasEnabled, !speedSections\.isEmpty,", body)


def test_route_changes_extend_camera_and_section_prefetch():
    # Reroute, leg advance and alternative switch all funnel through the
    # route-changed hook — it must extend the camera/section set, or a new
    # road / the next leg never gets its sections (or cameras).
    from tests.swift_source import strip_comments
    picker = strip_comments(_src("UI/MapPickerView.swift"))
    hook = picker[picker.index("onActiveRouteChanged = { [weak status] newRoute in"):]
    hook = hook[:hook.index("onAlternativesChanged")]
    assert "status.prefetchSpeedCameras(for: newRoute, extending: true)" in hook
    app = strip_comments(_src("App/AppStatus.swift"))
    body = app[app.index("func prefetchSpeedCameras(for route: MKRoute, extending: Bool = false)"):]
    body = body[:body.index("func prefetchSpeedLimits")]
    # Skip when already covered, merge (not replace) the result.
    assert "if extending, speedCameraCoverage.contains(where: { $0.contains(routeBox) })" in body
    assert "self.speedCameraData.merged(with: fetched)" in body


def test_route_changes_refetch_speed_limits():
    # Field logs 2026-09-28: the start fetch timed out (Overpass busy) and
    # limits never came back for the rest of either ride — cameras did, on
    # the first reroute. Route changes must refetch limits too (skipped when
    # the loaded box already covers the new route), and a failed fetch is
    # retried every 60 s while navigating.
    from tests.swift_source import decl_body, strip_comments
    picker = strip_comments(_src("UI/MapPickerView.swift"))
    hook = picker[picker.index("onActiveRouteChanged = { [weak status] newRoute in"):]
    hook = hook[:hook.index("onAlternativesChanged")]
    assert "status.prefetchSpeedLimits(for: newRoute, extending: true)" in hook
    app = strip_comments(_src("App/AppStatus.swift"))
    body = decl_body(app, "func prefetchSpeedLimits(for route: MKRoute, extending: Bool = false)")
    skip = body.index("covered.contains(SpeedLimitService.boundingBox(of: coords, bufferMeters: 0))")
    assert skip < body.index("speedLimitPrefetchTask?.cancel()")
    assert "bufferMeters: SpeedLimitService.corridorBufferMeters)" in body
    assert "speedLimitCoverage = box" in body
    # Failure = no limits AND no roads (an untagged region still has roads).
    assert "let failed = data.limits.isEmpty && data.roads.isEmpty" in body
    assert "if !(failed && extending) {" in body
    assert "var retryDelay = AppStatus.speedLimitRetrySeconds" in body
    retry = body.index("try? await Task.sleep(for: .seconds(retryDelay))")
    assert retry < body.index("retryDelay = min(retryDelay * 2, AppStatus.speedLimitRetryMaxSeconds)")
    assert body.index("guard failed else { return }") < retry
    assert retry < body.index("guard !Task.isCancelled, self.activeNavigator.isNavigating else { return }")
    assert "static let speedLimitRetrySeconds: Double = 60" in app
    assert "static let speedLimitRetryMaxSeconds: Double = 600" in app
    svc = strip_comments(_src("RideAlerts/SpeedLimitService.swift"))
    assert "o.south >= south && o.north <= north && o.west >= west && o.east <= east" in svc


class _LimitPrefetchModel:
    """Python mirror of AppStatus.prefetchSpeedLimits: claim (buffered box)
    on the call, fetch in flight, resolve later; retry 60 s after a failure
    while navigating. Boxes are (south, west, north, east) in metres."""

    BUFFER = 300
    RETRY = 60
    RETRY_MAX = 600
    EMPTY = ("no-limits", "no-roads")

    def __init__(self):
        self.coverage = None
        self.task = None
        self.installed = None
        self.fetches = 0
        self.navigating = True

    @staticmethod
    def _contains(o, i):
        return i[0] >= o[0] and i[2] <= o[2] and i[1] >= o[1] and i[3] <= o[3]

    def prefetch(self, route_box, extending=False):
        if extending and self.coverage and self._contains(self.coverage, route_box):
            return None                                   # skipped
        if self.task:
            self.task["cancelled"] = True
        b = self.BUFFER
        self.coverage = (route_box[0] - b, route_box[1] - b, route_box[2] + b, route_box[3] + b)
        self.task = {"extending": extending, "cancelled": False, "retry_at": None,
                     "delay": self.RETRY}
        self.fetches += 1
        return self.task

    def resolve(self, task, result, now):
        """result: None = failed (no limits, no roads); ([], roads) = untagged
        region; (limits, roads) = normal."""
        if task["cancelled"]:
            return
        failed = result is None
        if not (failed and task["extending"]):
            self.installed = self.EMPTY if failed else result
        if failed:
            task["retry_at"] = now + task["delay"]
            task["delay"] = min(task["delay"] * 2, self.RETRY_MAX)
        else:
            task["retry_at"] = None

    def tick(self, now):
        t = self.task
        if t and t["retry_at"] is not None and now >= t["retry_at"]:
            t["retry_at"] = None
            if not t["cancelled"] and self.navigating:
                self.fetches += 1                         # same task, next attempt
                return t
        return None


ROUTE = (0, 0, 10_000, 10_000)
INSIDE = (1_000, 1_000, 9_000, 10_200)                    # detour < 300 m: in box
OUTSIDE = (0, 0, 10_000, 12_000)


def test_failed_start_retries_after_60s_not_on_the_hook():
    m = _LimitPrefetchModel()
    start = m.prefetch(ROUTE)                             # installRouteGeometrySync
    assert m.prefetch(ROUTE, extending=True) is None      # hook: start still in flight
    m.resolve(start, None, now=30)                        # Overpass timed out
    assert m.installed == m.EMPTY and m.fetches == 1
    assert m.prefetch(INSIDE, extending=True) is None     # reroute inside: claim held
    assert m.tick(now=60) is None                         # not yet
    again = m.tick(now=90)
    assert again is start and m.fetches == 2
    m.resolve(again, (["50"], ["road"]), now=95)
    assert m.installed == (["50"], ["road"]) and m.tick(now=500) is None


def test_untagged_region_is_a_success_not_a_refetch_loop():
    m = _LimitPrefetchModel()
    m.resolve(m.prefetch(ROUTE), ([], ["road"]), now=5)   # no maxspeed tags, roads ok
    assert m.installed == ([], ["road"])
    assert m.tick(now=1_000) is None
    assert m.prefetch(INSIDE, extending=True) is None and m.fetches == 1


def test_outside_reroute_cancels_the_start_fetch():
    m = _LimitPrefetchModel()
    start = m.prefetch(ROUTE)
    reroute = m.prefetch(OUTSIDE, extending=True)
    assert reroute is not None and m.fetches == 2
    m.resolve(start, (["90"], ["old"]), now=20)           # late start result: dropped
    assert m.installed is None
    m.resolve(reroute, (["50"], ["new"]), now=21)
    assert m.installed == (["50"], ["new"])


def test_failed_reroute_keeps_old_ways_and_retries():
    m = _LimitPrefetchModel()
    m.resolve(m.prefetch(ROUTE), (["50"], ["road"]), now=5)
    reroute = m.prefetch(OUTSIDE, extending=True)
    m.resolve(reroute, None, now=40)
    assert m.installed == (["50"], ["road"])
    assert m.tick(now=100) is reroute and m.fetches == 3


def test_no_retry_after_navigation_stops():
    m = _LimitPrefetchModel()
    m.resolve(m.prefetch(ROUTE), None, now=30)
    m.navigating = False
    assert m.tick(now=90) is None and m.fetches == 1


def test_free_ride_retires_route_camera_fetches():
    # Reroute fetches aren't cancellable; a late one must not overwrite the
    # free-ride markers after arrival / manual stop.
    from tests.swift_source import decl_body, strip_comments
    body = strip_comments(decl_body(_src("App/AppStatus.swift"),
                                    "private func prefetchFreeRideCameras(around center: CLLocationCoordinate2D)"))
    assert "speedCameraGeneration += 1" in body
    assert "speedCameraData = .empty" in body


def test_free_ride_fetches_limits_and_cameras_around_rider():
    # Free ride had no speed-limit sign at all (limits were only fetched
    # along a nav route) and fetched cameras once, at start. Both are now
    # fetched around the rider on the first fix and again after 3 km.
    from tests.swift_source import decl_body, strip_comments
    app = strip_comments(_src("App/AppStatus.swift"))
    install = decl_body(app, "private func installFreeRideContent()")
    assert "freeRideFixSubscription = locationService.subscribeFixes" in install
    assert "self?.refreshFreeRideAlerts(near: fix.coordinate)" in install
    assert "freeRideAlertCenter = nil" in install
    # A nav-route limit fetch still in flight must not land on free ride.
    assert "speedLimitPrefetchTask?.cancel()" in install
    refresh = decl_body(app, "private func refreshFreeRideAlerts(near coord: CLLocationCoordinate2D)")
    assert "guard isFreeRiding, !activeNavigator.isNavigating else { return }" in refresh
    assert "if moved < Self.freeRideAlertRefetchMeters {" in refresh
    assert "prefetchFreeRideCameras(around: center)" in refresh
    assert refresh.count("prefetchFreeRideSpeedLimits(around: center)") == 2   # retry + refetch
    limits = decl_body(app, "private func prefetchFreeRideSpeedLimits(around center: CLLocationCoordinate2D)")
    assert "SpeedLimitService.shared.limitsAround(" in limits
    # Late / failed / off results never overwrite: a failed refetch keeps
    # the loaded layer, a nav start owns it.
    for cond in ("!Task.isCancelled", "self.isFreeRiding",
                 "!self.activeNavigator.isNavigating",
                 "self.dashNavSettings.speedLimitDisplay != .off"):
        assert cond in limits, cond
    assert "freeRideAlertRadiusMeters: Double = 6_000" in app
    assert "freeRideAlertRefetchMeters: Double = 3_000" in app
    assert "freeRideFixSubscription = nil" in decl_body(app, "func stopFreeRide()")
    svc = strip_comments(_src("RideAlerts/SpeedLimitService.swift"))
    around = decl_body(svc, "func limitsAround(center: CLLocationCoordinate2D, radiusMeters: Double)")
    assert "Self.boundingBox(of: [center], bufferMeters: radiusMeters)" in around


def _free_ride_model(radius=6000, refetch=3000, retry_s=60, retry_max=600):
    """Python mirror of AppStatus.refreshFreeRideAlerts + the free-ride limit
    task (1-D positions in metres along the ride). `result` of a fetch:
    "ok" (limits + roads), "roads_only" (untagged region), "fail" (no roads)."""
    st = {"center": None, "at": -1e9, "fetches": [], "retries": [], "failed": False,
          "delay": retry_s, "loaded": None}

    def fix(pos, t, result="ok"):
        if st["center"] is not None and abs(pos - st["center"]) < refetch:
            if st["failed"] and t - st["at"] >= st["delay"]:
                st["at"] = t
                st["delay"] = min(st["delay"] * 2, retry_max)
                st["retries"].append((st["center"], t))   # limits only, same box
                _land(result)
            return
        st["center"], st["at"] = pos, t                   # (snap: see the Swift)
        st["fetches"].append(pos)                         # cameras + limits
        _land(result)

    def _land(result):
        st["failed"] = result == "fail"
        if not st["failed"]:
            st["delay"] = retry_s
            st["loaded"] = result

    return st, fix


def test_free_ride_refetch_keeps_rider_inside_loaded_square():
    st, fix = _free_ride_model()
    for i in range(0, 200):              # 20 km at 100 m per fix, 1 fix/s
        fix(i * 100, i)
        # The rider never gets closer than 3 km to the loaded edge.
        assert abs(i * 100 - st["center"]) < 6000 - 2999
    assert st["fetches"][0] == 0 and len(st["fetches"]) == 7   # every 3 km
    assert st["retries"] == []


def test_free_ride_retries_limits_after_failed_start():
    st, fix = _free_ride_model()
    fix(0, 0, "fail")                    # Overpass timed out
    fix(50, 30)                          # <60 s: nothing
    assert st["fetches"] == [0] and st["retries"] == []
    fix(80, 61)                          # 60 s later: limits only, same box
    assert st["fetches"] == [0] and st["retries"] == [(0, 61)] and st["loaded"] == "ok"
    fix(120, 500)                        # loaded now: no timed retry
    assert st["retries"] == [(0, 61)]


def test_free_ride_untagged_region_is_not_a_retry_loop():
    # Review of #145 (M1): roads but no maxspeed tags used to leave the sign
    # layer empty, so the "limits missing" retry re-queried Overpass (limits
    # AND cameras, on a new box each minute) for the whole ride.
    st, fix = _free_ride_model()
    for i in range(0, 25):               # 25 min, crawling 100 m / min
        fix(i * 100, i * 60, "roads_only")
    assert st["fetches"] == [0] and st["retries"] == [] and st["loaded"] == "roads_only"


def test_free_ride_retry_backs_off():
    st, fix = _free_ride_model()
    fix(0, 0, "fail")
    for t in range(1, 3000):             # parked-ish, Overpass keeps failing
        fix(0, t, "fail")
    gaps = [b[1] - a[1] for a, b in zip([(0, 0)] + st["retries"], st["retries"])]
    assert gaps[:6] == [60, 120, 240, 480, 600, 600]


def test_free_ride_hardening_from_review():
    from tests.swift_source import decl_body, strip_comments
    app = strip_comments(_src("App/AppStatus.swift"))
    refresh = decl_body(app, "private func refreshFreeRideAlerts(near coord: CLLocationCoordinate2D)")
    # M1: retry only a failed fetch, limits only, same box, with backoff.
    assert "if freeRideLimitsFailed, dashNavSettings.speedLimitDisplay != .off," in refresh
    assert "freeRideLimitRetryDelay = min(freeRideLimitRetryDelay * 2," in refresh
    assert "speedLimitWaysEmpty" not in refresh
    limits = decl_body(app, "private func prefetchFreeRideSpeedLimits(around center: CLLocationCoordinate2D)")
    assert "self.freeRideLimitsFailed = data.roads.isEmpty" in limits
    assert "!data.limits.isEmpty" not in limits
    # M2: centre snapped to the 0.01° cache-key grid.
    assert "(coord.latitude * 100).rounded() / 100" in refresh
    assert "(coord.longitude * 100).rounded() / 100" in refresh
    # L2: no fetching once the link has given up.
    assert "guard bikeLink.state == .connected || bikeLink.state == .reconnecting else { return }" in refresh
    # L4: free-ride markers don't linger onto a later nav map.
    assert "mapViewSource.setSpeedCameras([])" in decl_body(app, "func stopFreeRide()")
    install = decl_body(app, "private func installFreeRideContent()")
    assert "freeRideLimitsFailed = false" in install
    # Round 2: backoff timed from the failure; toggles go through the gated
    # per-fix path instead of fetching directly.
    assert "guard !data.roads.isEmpty else { self.freeRideAlertAt = Date(); return }" in limits
    for fn in ("private func observeSpeedCameraToggle()", "private func observeSpeedLimitMode()"):
        body = decl_body(app, fn)
        assert "self.freeRideAlertCenter = nil" in body and "prefetchFreeRide" not in body, fn


def test_overpass_runtime_error_remark_is_a_failure():
    # A timeout / out-of-memory mid-query is HTTP 200 + some (or no)
    # elements + a runtime-error remark: never use or cache it (30-day TTL),
    # try the next mirror. Cameras too: an empty camera set is legit, so
    # the remark is the only tell there.
    from tests.swift_source import decl_body, strip_comments
    for path, fn, ret in (
        ("RideAlerts/SpeedLimitService.swift", "private func fetch(box: BBox) async throws -> SpeedLimitData",
         "return Self.split(decoded.elements)"),
        ("RideAlerts/SpeedCameraService.swift", "private func overpass(_ query: String) async throws -> OverpassResponse",
         "return decoded"),
    ):
        svc = strip_comments(_src(path))
        assert "let remark: String?" in svc, path
        body = decl_body(svc, fn)
        check = body.index('if let remark = decoded.remark, remark.contains("runtime error") {')
    if "SpeedLimit" in path:
        assert 'remark: \\(remark, privacy: .public)")' in body
        assert check < body.index(ret) and "continue" in body[check:body.index(ret)], path


def test_empty_overpass_answer_is_never_cached():
    # Review of the 60 s retry: a busy Overpass can answer HTTP 200 with a
    # "Query timed out" remark and no elements. Cached, that empty set
    # would be re-read by every retry (and every ride through the box) for
    # the 30-day TTL instead of asking Overpass again.
    from tests.swift_source import decl_body, strip_comments
    svc = strip_comments(_src("RideAlerts/SpeedLimitService.swift"))
    body = decl_body(svc, "private func limits(in box: BBox) async -> SpeedLimitData")
    assert "if let cached = loadCache(key: key), !cached.roads.isEmpty {" in body
    assert "if !data.roads.isEmpty { saveCache(key: key, data: data) }" in body
    # One definition + this one call each, file-wide: a new caller
    # elsewhere would bypass the guard.
    assert svc.count("saveCache(") == 2 and svc.count("loadCache(") == 2


def test_retry_backs_off_to_ten_minutes():
    # Review round 3: a whole-route box too big for Overpass fails every
    # time; a flat 60 s retry would send ~240 heavy queries on a 4 h ride.
    m = _LimitPrefetchModel()
    t = m.prefetch(ROUTE)
    m.resolve(t, None, now=0)
    now, waits = 0, []
    for _ in range(6):
        wait = t["retry_at"] - now
        waits.append(wait)
        now = t["retry_at"]
        assert m.tick(now) is t
        m.resolve(t, None, now=now)
    assert waits == [60, 120, 240, 480, 600, 600]


def test_nav_camera_fetch_retries_after_total_failure():
    # Field log 2026-09-28 21:11: both mirrors failed on the nav start
    # camera fetch and cameras never came for the rest of the ride — only
    # a route change outside the box retried. Now the same backoff as the
    # speed limits (60 s doubling to 600 s) while navigating, toggle on.
    from tests.swift_source import decl_body, strip_comments
    app = strip_comments(_src("App/AppStatus.swift"))
    body = decl_body(app, "func prefetchSpeedCameras(for route: MKRoute, extending: Bool = false)")
    assert "var retryDelay = AppStatus.speedLimitRetrySeconds" in body
    loop = body[body.index("while true {"):]
    fetch = loop.index("SpeedCameraService.shared.camerasAlong(route: coords)")
    gen = loop.index("guard let self, !Task.isCancelled, generation == self.speedCameraGeneration else { return }")
    ok = loop.index("if let fetched {")
    sleep = loop.index("try? await Task.sleep(for: .seconds(retryDelay))")
    back = loop.index("retryDelay = min(retryDelay * 2, AppStatus.speedLimitRetryMaxSeconds)")
    stop = loop.index("self.activeNavigator.isNavigating,")
    assert fetch < gen < ok < sleep < back < stop
    assert "self.dashNavSettings.speedCamerasEnabled else { return }" in loop[stop:]
    assert "guard !Task.isCancelled, generation == self.speedCameraGeneration," in loop[back:]
    # Success returns; the claim is no longer released on failure.
    assert "return" in loop[ok:sleep]
    assert "speedCameraCoverage.removeAll" not in body


def test_overpass_logs_every_mirror_failure():
    # Field log 2026-09-28 21:10: overpass-api.de failed silently for ~40 s;
    # only the fallback mirror's error reached the log.
    from tests.swift_source import strip_comments
    for path, tag in (("RideAlerts/SpeedLimitService.swift", "Speed limits"),
                      ("RideAlerts/SpeedCameraService.swift", "Speed cameras")):
        svc = strip_comments(_src(path))
        assert f'log.warning("{tag}: \\(endpoint, privacy: .public) HTTP \\(http.statusCode, privacy: .public)")' in svc, path
        assert f'log.warning("{tag}: \\(endpoint, privacy: .public) failed: \\(ns.domain, privacy: .public) \\(ns.code, privacy: .public)")' in svc, path
        assert f'log.warning("{tag}: \\(endpoint, privacy: .public) remark: \\(remark, privacy: .public)")' in svc, path
