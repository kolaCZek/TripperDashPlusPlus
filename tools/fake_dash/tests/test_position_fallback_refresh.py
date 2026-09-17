"""Guards for the position-fallback tile's refresh-before-expiry ring.

The position-fallback tile is the off-corridor rescue map, and in FREE RIDE
it is the only source of map imagery at all — there is no baked route
corridor to fall back to. That makes one detail load-bearing: the tile must
be re-baked BEFORE it stops covering the rider.

Originally both the "does this tile still cover me?" query and the "should I
bake a new one?" trigger used the same 800 m radius, so the bake only began
at the exact moment the render path had already fallen through to the bare
vector frame. The rider watched an empty background until the composite
landed, then the map reappeared — every 800 m on a free ride.

These guards pin the two radii apart and pin each call site to the right
one. Getting either backwards silently restores the blanking.
"""

from pathlib import Path

import pytest

from tests.swift_source import decl_body, strip_comments

REPO = Path(__file__).resolve().parents[3]
CACHE = REPO / "TripperDashPP/Map/RouteTileCache.swift"
MAPVIEW = REPO / "TripperDashPP/Map/MapViewSource.swift"


@pytest.fixture(scope="module")
def cache_src():
    return strip_comments(CACHE.read_text(encoding="utf-8"))


def _radius(src: str, name: str) -> float:
    marker = f"static let {name}: CLLocationDistance = "
    start = src.index(marker) + len(marker)
    end = src.index("\n", start)
    return float(src[start:end].strip())


def test_both_radii_exist(cache_src):
    for name in ("positionFallbackValidRadius", "positionFallbackRefreshRadius"):
        assert f"static let {name}: CLLocationDistance = " in cache_src, (
            f"{name} is missing — the refresh-before-expiry behaviour "
            f"depends on both radii existing"
        )


def test_refresh_ring_is_strictly_inside_the_validity_ring(cache_src):
    """Equal radii is the original bug: bake starts only once it's too late."""
    valid = _radius(cache_src, "positionFallbackValidRadius")
    refresh = _radius(cache_src, "positionFallbackRefreshRadius")
    assert refresh < valid, (
        f"refresh radius ({refresh} m) must be strictly SMALLER than the "
        f"validity radius ({valid} m). Equal or larger means the next tile "
        f"is only requested once the current one has already stopped "
        f"covering the rider — which is exactly the blank-then-return "
        f"the free-ride tester reported"
    )


def test_refresh_lead_is_big_enough_to_hide_a_bake(cache_src):
    """The gap is travel time for the fetch; too small and it still blanks."""
    valid = _radius(cache_src, "positionFallbackValidRadius")
    refresh = _radius(cache_src, "positionFallbackRefreshRadius")
    lead = valid - refresh
    assert lead >= 200, (
        f"only {lead} m of lead between the refresh ring and expiry. A "
        f"composite is ~25 tile fetches; at town speeds this needs a couple "
        f"of hundred metres of travel to land before the old tile expires"
    )


def test_bake_trigger_uses_the_refresh_radius(cache_src):
    """This is the fix: bake early, while the current tile still covers."""
    fn = decl_body(cache_src, "func ensurePositionFallback(near coord: CLLocationCoordinate2D) async")
    assert fn is not None, "ensurePositionFallback not found"
    assert "positionFallbackRefreshRadius" in fn, (
        "the bake trigger must compare against the REFRESH radius; using "
        "the validity radius here is the original bug"
    )
    assert "positionFallbackValidRadius" not in fn, (
        "the bake trigger must not also consult the validity radius — one "
        "ring, one job, or the early-bake window closes again"
    )


def test_cover_query_uses_the_validity_radius(cache_src):
    """The drawable window must stay wide; narrowing it re-creates the gap."""
    fn = decl_body(cache_src, "func coveringPositionFallbackTile(for coord: CLLocationCoordinate2D) -> RouteTile?")
    assert fn is not None, "coveringPositionFallbackTile not found"
    assert "positionFallbackValidRadius" in fn, (
        "the cover query must use the VALIDITY radius — this is how long "
        "the existing tile keeps being drawn while the next one bakes"
    )
    assert "positionFallbackRefreshRadius" not in fn, (
        "the cover query must not use the refresh radius: that would stop "
        "drawing the tile at the very moment the replacement is requested, "
        "restoring the blank frame this change removes"
    )


def test_render_path_requests_a_bake_before_drawing():
    """Order matters: ask first, so the miss starts a fetch immediately."""
    body = strip_comments(MAPVIEW.read_text(encoding="utf-8"))
    fn = decl_body(body, "private func drawOffCorridorFallbackFrame(into ctx: CGContext)")
    assert fn is not None, "drawOffCorridorFallbackFrame not found"
    kick = fn.index("ensurePositionFallbackTile")
    draw = fn.index("coveringPositionFallbackTile")
    assert kick < draw, (
        "the bake kick must come BEFORE the covering-tile query, so a miss "
        "has already started a fetch rather than waiting for the next frame"
    )
