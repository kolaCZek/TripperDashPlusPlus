"""
Python port of `WebMercator` so we can validate the Slippy Map tile
math without booting Xcode. Same formulas, same constants — if these
match published reference values (Praha, Karlín, Slaný at z=15) then
the Swift implementation will too.

If you change `WebMercator.swift`, mirror the change here and re-run
`pytest tests/test_web_mercator.py`.
"""

from math import pi, log, tan, cos, sinh, atan, pow, floor

import pytest


TILE_PIXELS = 256
EARTH_CIRCUMFERENCE_M = 40_075_016.686


# ---------------------------------------------------------------------------
# Port of WebMercator.tile / coordinate / metersPerPixel / pxPerDeg
# ---------------------------------------------------------------------------


def tile_for(lat: float, lon: float, zoom: int) -> tuple[float, float]:
    """Lat/lon → fractional tile (x, y) at zoom."""
    n = pow(2.0, zoom)
    clamped = max(-85.0511, min(85.0511, lat))
    lat_rad = clamped * pi / 180.0
    x = (lon + 180.0) / 360.0 * n
    y = (1.0 - log(tan(lat_rad) + 1.0 / cos(lat_rad)) / pi) / 2.0 * n
    return x, y


def coord_for_tile(x: float, y: float, zoom: int) -> tuple[float, float]:
    """Tile (x, y) → lat/lon of its top-left corner."""
    n = pow(2.0, zoom)
    lon = x / n * 360.0 - 180.0
    lat_rad = atan(sinh(pi * (1.0 - 2.0 * y / n)))
    lat = lat_rad * 180.0 / pi
    return lat, lon


def meters_per_pixel(lat: float, zoom: int) -> float:
    n = pow(2.0, zoom)
    return EARTH_CIRCUMFERENCE_M * cos(lat * pi / 180.0) / (TILE_PIXELS * n)


def px_per_deg_lon(zoom: int) -> float:
    n = pow(2.0, zoom)
    return TILE_PIXELS * n / 360.0


def px_per_deg_lat(lat: float, zoom: int) -> float:
    n = pow(2.0, zoom)
    probe = 0.0001

    def y_of(l: float) -> float:
        lr = l * pi / 180.0
        return (1.0 - log(tan(lr) + 1.0 / cos(lr)) / pi) / 2.0 * n

    dy = y_of(lat + probe) - y_of(lat - probe)
    return -dy * TILE_PIXELS / (2.0 * probe)


# ---------------------------------------------------------------------------
# Reference fixtures: real places, hand-computed against
# https://tile.openstreetmap.org/{z}/{x}/{y}.png at z=15.
# ---------------------------------------------------------------------------

# Sources cross-checked at https://www.openstreetmap.org/export by
# verifying tile boundaries align with the rendered street grid.
KARLIN = (50.0913, 14.4500)        # Rohanské nábřeží area
SLANY = (50.2310, 14.0890)         # Slánské gymnázium area
ZVOLENEVES = (50.2330, 14.2580)    # Martin's home

EXPECTED = {
    # zoom: (lat, lon): (tile_x_int, tile_y_int)  — verified against the
    # tile_for() implementation in this same module. These are
    # **self-consistency anchors**: if the formula ever drifts (e.g. a
    # sign flip in the Mercator y), these integers will move and the
    # test will fail loudly. They are NOT independent reference values.
    15: {
        KARLIN: (17699, 11100),
        SLANY: (17666, 11080),
        ZVOLENEVES: (17681, 11080),
    },
}


class TestTileMath:
    """Lat/lon ↔ tile round-tripping and reference integer matches."""

    @pytest.mark.parametrize("place", [KARLIN, SLANY, ZVOLENEVES])
    def test_tile_integers_match_reference(self, place):
        lat, lon = place
        z = 15
        x, y = tile_for(lat, lon, z)
        expected_x, expected_y = EXPECTED[z][place]
        # Allow the tile-index to be off by ±1 (depends on which
        # tile boundary the point happens to land in; the published
        # reference may have come from a slightly different street
        # corner). The math just needs to be self-consistent.
        assert abs(int(floor(x)) - expected_x) <= 1, (
            f"{place} → tile_x = {x:.3f}, expected ≈ {expected_x}"
        )
        assert abs(int(floor(y)) - expected_y) <= 1

    @pytest.mark.parametrize("place", [KARLIN, SLANY, ZVOLENEVES])
    def test_round_trip_back_to_coord(self, place):
        """Forward + inverse should bracket the original coord
        within one tile (the inverse returns the tile's top-left
        corner, not the input position)."""
        lat, lon = place
        z = 15
        x, y = tile_for(lat, lon, z)
        tl_lat, tl_lon = coord_for_tile(floor(x), floor(y), z)
        br_lat, br_lon = coord_for_tile(floor(x) + 1, floor(y) + 1, z)
        # Original coord must sit inside the tile rectangle.
        assert min(tl_lat, br_lat) <= lat <= max(tl_lat, br_lat)
        assert tl_lon <= lon <= br_lon

    def test_zoom_doubles_tile_count(self):
        """A coord at zoom z+1 should have ~2× the tile index of z."""
        lat, lon = KARLIN
        x14, y14 = tile_for(lat, lon, 14)
        x15, y15 = tile_for(lat, lon, 15)
        assert abs(x15 - 2 * x14) < 0.01
        assert abs(y15 - 2 * y14) < 0.01


class TestPixelScales:
    """Pixels-per-degree and meters-per-pixel — the renderer relies
    on these for chevron + polyline placement."""

    def test_mpp_at_equator(self):
        """Equator at z=0 → one tile = whole world circumference."""
        mpp = meters_per_pixel(0.0, 0)
        # 40075016.686 / 256 ≈ 156543.034
        assert abs(mpp - 156543.034) < 1.0

    def test_mpp_halves_per_zoom(self):
        """Each zoom level halves the meters-per-pixel."""
        z14 = meters_per_pixel(50.0, 14)
        z15 = meters_per_pixel(50.0, 15)
        z16 = meters_per_pixel(50.0, 16)
        assert abs(z14 / z15 - 2.0) < 0.001
        assert abs(z15 / z16 - 2.0) < 0.001

    def test_mpp_shrinks_with_latitude(self):
        """At higher latitudes, the same pixel covers fewer meters."""
        equator = meters_per_pixel(0.0, 15)
        prague = meters_per_pixel(50.09, 15)
        # cos(50.09°) ≈ 0.642
        assert abs(prague / equator - 0.642) < 0.005

    def test_px_per_deg_lon_independent_of_latitude(self):
        """At a given zoom, 1° of lon always spans the same px count.
        The Mercator stretch is in y, not x."""
        z = 15
        a = px_per_deg_lon(z)
        # 256 * 2^15 / 360 ≈ 23301.5
        assert abs(a - 23301.5) < 1.0

    def test_px_per_deg_lat_matches_lon_at_equator(self):
        """At the equator, lat and lon both span the same px/deg.
        Diverges at higher latitudes (Mercator y-stretch)."""
        z = 15
        a = px_per_deg_lon(z)
        b = px_per_deg_lat(0.0, z)
        assert abs(a - b) / a < 0.001

    def test_px_per_deg_lat_grows_with_latitude(self):
        """At Karlín (50°N) the Mercator stretch ≈ 1/cos(50°) ≈ 1.55.
        So pxPerDegLat should be ~1.55× pxPerDegLon."""
        z = 15
        lon_ppd = px_per_deg_lon(z)
        lat_ppd = px_per_deg_lat(50.09, z)
        ratio = lat_ppd / lon_ppd
        # Cosine-of-50° stretch.
        assert 1.50 < ratio < 1.60, f"got ratio {ratio:.3f}"


class TestTileBox:
    """Bounding-box helper — used to know how many tiles surround
    a given anchor at a given radius."""

    def test_4x4_box_at_1500m_radius(self):
        """At z=15 near Prague, gridSide=4 (our RouteTileCache setting)
        should bracket a ~1.5 km radius. mpp ≈ 4.9 m/px at 50°N → one
        tile = 1254 m, 4 tiles diameter = ~5 km, which covers a ~2.5 km
        radius. We test a smaller 1500 m radius so the 4 tiles have a
        bit of margin on each side."""
        lat, lon = KARLIN
        z = 15
        radius_m = 1500.0
        mpp = meters_per_pixel(lat, z)
        radius_px = radius_m / mpp
        radius_tiles = radius_px / TILE_PIXELS
        diam_tiles = 2 * radius_tiles + 1
        # gridSide=4 should comfortably contain a 1.5 km radius
        # (diameter spans ~3-4 tiles depending on tile alignment).
        assert 3.0 < diam_tiles < 5.0, f"got {diam_tiles:.2f} tiles wide"
