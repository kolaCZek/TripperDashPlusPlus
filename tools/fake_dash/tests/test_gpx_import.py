"""
Tests for GPX import geometry + saved-route start logic.

Mirrors `GPXParser.swift` (GPXGeometry) + `RouteStartPlanner.swift` via
`gpx_geometry_mirror.py`. These pin the behaviour the device relies on,
without booting Xcode:

  - extraction priority (rte > trk > wpt) and kind classification
  - lat/lon tolerance: namespaces, bad coords skipped, name capture
  - haversine path length on the FULL trace (not the reduced one)
  - Douglas–Peucker reduce: endpoints + named points always kept,
    hard cap respected, ordering preserved, idempotent under the cap
  - start-mode analyze: nearest-vs-first selection + prompt threshold
  - navigable_points truncation for from_nearest

The exact metre values come from real geometry (Prague-area coords), so
the asserts double as a regression pin on the haversine/RDP constants.
"""

from __future__ import annotations

import math

import pytest

from tests.gpx_geometry_mirror import (
    NAVIGABLE_CAP,
    PROMPT_THRESHOLD_M,
    ParsedGPX,
    Pt,
    StartDecision,
    analyze,
    douglas_peucker,
    haversine,
    import_route,
    is_valid,
    navigable_points,
    parse,
    path_length,
    perpendicular_distance,
    reduce,
)

# ─────────────────────────── helpers ────────────────────────────────


def gpx(body: str, *, header: bool = True) -> str:
    if header:
        return (
            '<?xml version="1.0" encoding="UTF-8"?>\n'
            '<gpx version="1.1" creator="test" '
            'xmlns="http://www.topografix.com/GPX/1/1">\n'
            f"{body}\n</gpx>"
        )
    return body


# ─────────────────────────── geometry ───────────────────────────────


class TestValidity:
    def test_rejects_nan_and_out_of_range(self):
        assert not is_valid(float("nan"), 14.0)
        assert not is_valid(91.0, 0.0)
        assert not is_valid(0.0, 181.0)
        assert not is_valid(0.0, -181.0)

    def test_accepts_extremes(self):
        assert is_valid(-90.0, -180.0)
        assert is_valid(90.0, 180.0)
        assert is_valid(0.0, 0.0)


class TestHaversine:
    def test_zero_distance(self):
        p = Pt(50.0, 14.0)
        assert haversine(p, p) == pytest.approx(0.0, abs=1e-6)

    def test_known_one_degree_latitude(self):
        # 1° latitude ≈ 111.19 km on a 6371 km sphere.
        d = haversine(Pt(50.0, 14.0), Pt(51.0, 14.0))
        assert d == pytest.approx(111_195, rel=0.001)

    def test_symmetry(self):
        a, b = Pt(50.08, 14.43), Pt(49.19, 16.61)  # Praha → Brno-ish
        assert haversine(a, b) == pytest.approx(haversine(b, a), abs=1e-6)

    def test_path_length_sums_segments(self):
        pts = [Pt(50.0, 14.0), Pt(50.0, 14.01), Pt(50.0, 14.02)]
        seg = haversine(pts[0], pts[1])
        assert path_length(pts) == pytest.approx(2 * seg, rel=1e-9)

    def test_path_length_trivial(self):
        assert path_length([]) == 0.0
        assert path_length([Pt(50, 14)]) == 0.0


class TestPerpendicularDistance:
    def test_point_on_segment_is_zero(self):
        a, b = Pt(50.0, 14.0), Pt(50.0, 14.1)
        mid = Pt(50.0, 14.05)
        assert perpendicular_distance(mid, a, b) == pytest.approx(0.0, abs=0.5)

    def test_offset_point_positive(self):
        a, b = Pt(50.0, 14.0), Pt(50.0, 14.1)
        off = Pt(50.001, 14.05)  # ~111 m north of the line
        d = perpendicular_distance(off, a, b)
        assert d == pytest.approx(111.3, rel=0.05)

    def test_degenerate_segment_falls_back_to_haversine(self):
        a = Pt(50.0, 14.0)
        p = Pt(50.0, 14.01)
        # a == b → distance to the point itself.
        assert perpendicular_distance(p, a, a) == pytest.approx(haversine(p, a), abs=1e-6)


# ─────────────────────── Douglas–Peucker reduce ─────────────────────


def _straightish_line(n: int) -> list[Pt]:
    """n points on a near-straight east-west line, tiny jitter."""
    return [Pt(50.0 + (0.000001 if i % 2 else 0.0), 14.0 + i * 0.001) for i in range(n)]


def _wiggly_line(n: int) -> list[Pt]:
    """n points with a real sawtooth so RDP must keep many vertices."""
    return [Pt(50.0 + (0.01 if i % 2 else -0.01), 14.0 + i * 0.001) for i in range(n)]


class TestReduce:
    def test_under_cap_is_unchanged(self):
        pts = _straightish_line(10)
        out = reduce(pts, NAVIGABLE_CAP)
        assert out == pts  # same objects, same order

    def test_endpoints_always_kept(self):
        pts = _wiggly_line(200)
        out = reduce(pts, NAVIGABLE_CAP)
        assert out[0] is pts[0]
        assert out[-1] is pts[-1]

    def test_respects_hard_cap(self):
        pts = _wiggly_line(500)
        out = reduce(pts, NAVIGABLE_CAP)
        assert len(out) <= NAVIGABLE_CAP

    def test_order_preserved(self):
        pts = _wiggly_line(300)
        out = reduce(pts, NAVIGABLE_CAP)
        lons = [p.lon for p in out]
        assert lons == sorted(lons)

    def test_named_points_are_force_kept(self):
        pts = _straightish_line(100)
        # Name a couple of interior points that RDP would otherwise drop
        # on a near-straight line.
        pts[37].name = "Fuel"
        pts[63].name = "Viewpoint"
        out = reduce(pts, NAVIGABLE_CAP)
        kept_names = {p.name for p in out if p.name}
        assert "Fuel" in kept_names
        assert "Viewpoint" in kept_names

    def test_straight_line_collapses_to_endpoints(self):
        # A perfectly straight line has zero perpendicular deviation, so
        # RDP keeps only the two endpoints.
        pts = [Pt(50.0, 14.0 + i * 0.001) for i in range(50)]
        out = reduce(pts, NAVIGABLE_CAP)
        assert len(out) == 2
        assert out[0] is pts[0] and out[-1] is pts[-1]

    def test_idempotent_once_under_cap(self):
        pts = _wiggly_line(400)
        once = reduce(pts, NAVIGABLE_CAP)
        twice = reduce(once, NAVIGABLE_CAP)
        assert [(p.lat, p.lon) for p in once] == [(p.lat, p.lon) for p in twice]

    def test_many_named_points_exceeding_cap_keeps_forced(self):
        # 40 named points + endpoints > cap → forced-only path; every
        # named point survives even though that's > cap.
        pts = _straightish_line(120)
        for i in range(1, 119, 3):  # ~40 names
            pts[i].name = f"stop{i}"
        out = reduce(pts, NAVIGABLE_CAP)
        named_in = {p.name for p in pts if p.name}
        named_out = {p.name for p in out if p.name}
        assert named_in <= named_out  # all names kept
        assert out[0] is pts[0] and out[-1] is pts[-1]


# ─────────────────────── GPX extraction priority ────────────────────


class TestParsePriority:
    def test_waypoints_only(self):
        body = (
            '<wpt lat="50.0" lon="14.0"><name>A</name></wpt>'
            '<wpt lat="50.1" lon="14.1"><name>B</name></wpt>'
        )
        p = parse(gpx(body))
        assert p.kind == "waypoints"
        assert [pt.name for pt in p.raw_points] == ["A", "B"]

    def test_track_beats_waypoints(self):
        body = (
            '<wpt lat="10.0" lon="10.0"><name>loose</name></wpt>'
            "<trk><name>My Track</name><trkseg>"
            '<trkpt lat="50.0" lon="14.0"/>'
            '<trkpt lat="50.1" lon="14.1"/>'
            "</trkseg></trk>"
        )
        p = parse(gpx(body))
        assert p.kind == "track"
        assert len(p.raw_points) == 2
        # The loose waypoint is ignored when a track exists.
        assert all(pt.lat >= 50.0 for pt in p.raw_points)
        assert p.name == "My Track"

    def test_route_beats_track(self):
        body = (
            "<rte><name>Planned</name>"
            '<rtept lat="50.0" lon="14.0"/><rtept lat="50.2" lon="14.2"/>'
            "</rte>"
            "<trk><trkseg>"
            '<trkpt lat="10.0" lon="10.0"/><trkpt lat="10.1" lon="10.1"/>'
            "</trkseg></trk>"
        )
        p = parse(gpx(body))
        assert p.kind == "track"
        assert p.name == "Planned"
        assert p.raw_points[0].lat == pytest.approx(50.0)

    def test_multiple_track_segments_concatenated(self):
        body = (
            "<trk><trkseg>"
            '<trkpt lat="50.0" lon="14.0"/><trkpt lat="50.1" lon="14.1"/>'
            "</trkseg><trkseg>"
            '<trkpt lat="50.2" lon="14.2"/>'
            "</trkseg></trk>"
        )
        p = parse(gpx(body))
        assert len(p.raw_points) == 3


class TestParseTolerance:
    def test_skips_points_missing_coords(self):
        body = (
            '<wpt lat="50.0"><name>noLon</name></wpt>'
            '<wpt lat="50.1" lon="14.1"><name>ok</name></wpt>'
        )
        p = parse(gpx(body))
        assert [pt.name for pt in p.raw_points] == ["ok"]

    def test_skips_out_of_range_coords(self):
        body = (
            '<wpt lat="999.0" lon="14.0"/>'
            '<wpt lat="50.1" lon="14.1"/>'
        )
        p = parse(gpx(body))
        assert len(p.raw_points) == 1
        assert p.raw_points[0].lat == pytest.approx(50.1)

    def test_namespaced_elements(self):
        # Garmin-style default namespace already in gpx(); add an explicit
        # prefix on the trkpt to prove local-name matching works.
        raw = (
            '<?xml version="1.0"?>'
            '<gpx xmlns:g="http://www.topografix.com/GPX/1/1">'
            "<g:trk><g:trkseg>"
            '<g:trkpt lat="50.0" lon="14.0"/>'
            '<g:trkpt lat="50.1" lon="14.1"/>'
            "</g:trkseg></g:trk></gpx>"
        )
        p = parse(raw)
        assert p.kind == "track"
        assert len(p.raw_points) == 2

    def test_name_fallback_to_metadata_then_filename(self):
        body = (
            "<metadata><name>Meta Route</name></metadata>"
            '<trk><trkseg><trkpt lat="50.0" lon="14.0"/>'
            '<trkpt lat="50.1" lon="14.1"/></trkseg></trk>'
        )
        p = parse(gpx(body))
        assert p.name == "Meta Route"

    def test_name_filename_fallback(self):
        body = (
            '<trk><trkseg><trkpt lat="50.0" lon="14.0"/>'
            '<trkpt lat="50.1" lon="14.1"/></trkseg></trk>'
        )
        p = parse(gpx(body), "alps_day2.gpx")
        assert p.name == "alps day2"


# ─────────────────────────── import_route ───────────────────────────


class TestImportRoute:
    def test_waypoints_kept_in_full(self):
        body = "".join(
            f'<wpt lat="{50.0 + i*0.01}" lon="14.0"><name>w{i}</name></wpt>'
            for i in range(40)
        )
        r = import_route(gpx(body))
        assert r["kind"] == "waypoints"
        assert len(r["points"]) == 40  # NOT reduced

    def test_track_reduced_to_cap(self):
        body = (
            "<trk><trkseg>"
            + "".join(
                f'<trkpt lat="{50.0 + (0.01 if i%2 else -0.01)}" lon="{14.0 + i*0.001}"/>'
                for i in range(400)
            )
            + "</trkseg></trk>"
        )
        r = import_route(gpx(body))
        assert r["kind"] == "track"
        assert len(r["points"]) <= NAVIGABLE_CAP

    def test_distance_measured_on_full_trace(self):
        # Build a wiggly 400-pt track; the reduced point list is much
        # shorter but the reported distance must reflect the FULL trace.
        pts = [Pt(50.0 + (0.01 if i % 2 else -0.01), 14.0 + i * 0.001) for i in range(400)]
        full = path_length(pts)
        body = (
            "<trk><trkseg>"
            + "".join(f'<trkpt lat="{p.lat}" lon="{p.lon}"/>' for p in pts)
            + "</trkseg></trk>"
        )
        r = import_route(gpx(body))
        assert r["total_distance_m"] == pytest.approx(full, rel=1e-9)
        # And the reduced path is strictly shorter (sawtooth collapsed).
        reduced_len = path_length(r["points"])
        assert reduced_len < full

    def test_empty_raises(self):
        with pytest.raises(ValueError):
            import_route(gpx("<metadata><name>empty</name></metadata>"))


# ─────────────────────── start-mode planner ─────────────────────────


def _route_line() -> list[Pt]:
    # 11 points heading east from (50.0, 14.0), ~70 m spacing.
    return [Pt(50.0, 14.0 + i * 0.001) for i in range(11)]


class TestAnalyze:
    def test_no_fix_never_prompts(self):
        d = analyze(_route_line(), None)
        assert d.should_prompt is False
        assert d.nearest_index == 0

    def test_at_start_no_prompt(self):
        route = _route_line()
        d = analyze(route, Pt(50.0, 14.0))  # exactly the first point
        assert d.nearest_index == 0
        assert d.should_prompt is False

    def test_near_start_within_threshold_no_prompt(self):
        route = _route_line()
        # ~100 m north of the first point: nearest is still index 0.
        d = analyze(route, Pt(50.0009, 14.0))
        assert d.nearest_index == 0
        assert d.should_prompt is False

    def test_partway_along_prompts(self):
        route = _route_line()
        # Sit right on point index 5 → far from first (≈ 5×70 m = 350 m),
        # nearest is index 5, saving > threshold → prompt.
        d = analyze(route, Pt(50.0, 14.005))
        assert d.nearest_index == 5
        assert d.distance_to_first > PROMPT_THRESHOLD_M
        assert d.distance_to_nearest == pytest.approx(0.0, abs=1.0)
        assert d.should_prompt is True

    def test_just_over_threshold_boundary(self):
        # Construct a route where nearest is index 1 and the saving is
        # just above 300 m. Spacing 400 m between pt0 and pt1.
        route = [Pt(50.0, 14.0), Pt(50.0, 14.0 + 400 / 111_320 / math.cos(math.radians(50)) )]
        # Rider sits on pt1 → dist_first ≈ 400 m, nearest 0 → saving 400.
        d = analyze(route, route[1])
        assert d.nearest_index == 1
        assert d.should_prompt is True


class TestNavigablePoints:
    def test_from_first_returns_all(self):
        route = _route_line()
        out = navigable_points(route, "from_first", nearest_index=4)
        assert out == route

    def test_from_nearest_truncates_leading(self):
        route = _route_line()
        out = navigable_points(route, "from_nearest", nearest_index=4)
        assert len(out) == len(route) - 4
        assert out[0] is route[4]
        assert out[-1] is route[-1]

    def test_from_nearest_index_zero_returns_all(self):
        route = _route_line()
        out = navigable_points(route, "from_nearest", nearest_index=0)
        assert out == route

    def test_from_nearest_out_of_range_returns_all(self):
        route = _route_line()
        out = navigable_points(route, "from_nearest", nearest_index=999)
        assert out == route

    def test_unknown_mode_raises(self):
        with pytest.raises(ValueError):
            navigable_points(_route_line(), "sideways", 0)
