"""
Regression for the "black wedge at the edge of the screen" bug
(field-reported 2026-06, route Zvoleneves → Slany).

Root cause: `RouteTileCache.gridSide` was EVEN (4). The composite block
is centred on the anchor's tile via

    tlx = floor(fx) - gridSide / 2          (integer division)
    paintOffsetX = bitmap/2 - (fx - tlx) * 256

With an even gridSide the `floor(fx) - gridSide/2 … floor(fx) + gridSide/2 - 1`
bracket is ASYMMETRIC — two tiles of margin on the left/top, only one on
the right/bottom. When the anchor's fractional tile position lands near
the right/bottom edge of its central tile, the painted region of the
composite stops up to a full tile (~785 m at z=15) short of the bitmap
edge on those two sides. At the wide highway zoom (0.8x) the dash frame
reaches past the painted data → the rider sees a black wedge, most
visibly at the end of a route where the last anchor sits offset from
centre.

Fix: gridSide must be ODD (now 5) so the bracket is symmetric (±N) and
every side carries equal margin.

fake_dash can't run Swift / Quartz, so this mirrors the composite
coverage math + the renderer's inverse frame->bitmap mapping in Python
and proves NO frame corner ever lands outside the painted region along a
real captured route. It also greps the Swift source so a future edit
back to an even gridSide fails loudly here.

See `osm-tile-cache-rendering-pitfalls.md` Pitfall 11.
"""

from __future__ import annotations

import math
import re
from pathlib import Path

import pytest


# ---------------------------------------------------------------------------
# Swift constants we mirror. Keep in sync with RouteTileCache.swift /
# MapViewSource.swift; the *_source_sync tests below assert they still match.
# ---------------------------------------------------------------------------

TILE_PIXELS = 256
ZOOM = 15
STRIDE_M = 700.0
LATERAL_OFFSET_M = 1500.0

# MapViewSource render frame + tunables.
FRAME_W, FRAME_H = 526.0, 300.0
FORWARD_BIAS_FRACTION = 0.28
# Widest zoom the renderer ever uses (highway floor). This is the worst
# case for coverage: the frame covers the most ground, so it reaches
# furthest toward the unpainted composite edge.
MIN_ZOOM = 0.8

EARTH_R = 6_371_000.0


def _repo_root() -> Path:
    return Path(__file__).resolve().parents[3]


def _route_cache_src() -> str:
    return (_repo_root() / "TripperDashPP" / "Map" / "RouteTileCache.swift").read_text(
        encoding="utf-8"
    )


def _map_source_src() -> str:
    return (_repo_root() / "TripperDashPP" / "Map" / "MapViewSource.swift").read_text(
        encoding="utf-8"
    )


def _grid_side_from_swift() -> int:
    m = re.search(r"static let gridSide:\s*Int\s*=\s*(\d+)", _route_cache_src())
    assert m, "could not find gridSide in RouteTileCache.swift"
    return int(m.group(1))


# ---------------------------------------------------------------------------
# Web Mercator mirror (subset of WebMercator.swift).
# ---------------------------------------------------------------------------

def tile_for(lat: float, lon: float, zoom: int = ZOOM) -> tuple[float, float]:
    n = 2.0**zoom
    clamped = max(-85.0511, min(85.0511, lat))
    lr = math.radians(clamped)
    x = (lon + 180.0) / 360.0 * n
    y = (1.0 - math.log(math.tan(lr) + 1.0 / math.cos(lr)) / math.pi) / 2.0 * n
    return x, y


def px_per_deg_lon(zoom: int = ZOOM) -> float:
    return TILE_PIXELS * (2.0**zoom) / 360.0


def px_per_deg_lat(lat: float, zoom: int = ZOOM) -> float:
    n = 2.0**zoom
    probe = 0.0001

    def y(l: float) -> float:
        lr = math.radians(l)
        return (1.0 - math.log(math.tan(lr) + 1.0 / math.cos(lr)) / math.pi) / 2.0 * n

    return -(y(lat + probe) - y(lat - probe)) * TILE_PIXELS / (2.0 * probe)


def haversine(a, b) -> float:
    lat1, lon1 = math.radians(a[0]), math.radians(a[1])
    lat2, lon2 = math.radians(b[0]), math.radians(b[1])
    dlat, dlon = lat2 - lat1, lon2 - lon1
    h = math.sin(dlat / 2) ** 2 + math.cos(lat1) * math.cos(lat2) * math.sin(dlon / 2) ** 2
    return 2 * EARTH_R * math.asin(math.sqrt(h))


def bearing(a, b) -> float:
    lat1, lat2 = math.radians(a[0]), math.radians(b[0])
    dlon = math.radians(b[1] - a[1])
    x = math.sin(dlon) * math.cos(lat2)
    y = math.cos(lat1) * math.sin(lat2) - math.sin(lat1) * math.cos(lat2) * math.cos(dlon)
    return (math.degrees(math.atan2(x, y)) + 360.0) % 360.0


# ---------------------------------------------------------------------------
# Mirror of RouteTileCache.composite() coverage geometry.
# ---------------------------------------------------------------------------

def painted_region(anchor, grid_side: int):
    """Return (xlo, xhi, ylo, yhi, center_px) — the sub-rect of the
    grid*256 bitmap that actually has tile data painted into it, exactly
    as `composite()` lays it out:

        tlx = floor(fx) - grid_side // 2
        paintOffsetX = bitmap/2 - (fx - tlx) * 256
        data spans [paintOffsetX, paintOffsetX + grid_side*256], clipped
        to the bitmap [0, grid_side*256].
    """
    fx, fy = tile_for(*anchor)
    bs = grid_side * TILE_PIXELS
    half = grid_side // 2
    tlx = math.floor(fx) - half
    tly = math.floor(fy) - half
    po_x = bs / 2 - (fx - tlx) * TILE_PIXELS
    po_y = bs / 2 - (fy - tly) * TILE_PIXELS
    xlo, xhi = max(0.0, po_x), min(bs, po_x + bs)
    ylo, yhi = max(0.0, po_y), min(bs, po_y + bs)
    return xlo, xhi, ylo, yhi, bs / 2.0


def frame_corner_black_count(rider, heading_deg, zoom, anchor, grid_side: int) -> int:
    """Mirror of MapViewSource.drawTileCacheFrame's inverse mapping:
    walk the four frame corners back into composite-bitmap pixel space
    and count how many land OUTSIDE the painted region (= black)."""
    xlo, xhi, ylo, yhi, ctr = painted_region(anchor, grid_side)
    pplon = px_per_deg_lon()
    pplat = px_per_deg_lat(rider[0])
    # tile.center - rider, in bitmap px (Y-DOWN: north = -y).
    dx = (anchor[1] - rider[1]) * pplon
    dy = -(anchor[0] - rider[0]) * pplat
    th = math.radians(heading_deg)
    cos_, sin_ = math.cos(th), math.sin(th)
    puck = (FRAME_W / 2, FRAME_H / 2 + FRAME_H * FORWARD_BIAS_FRACTION)
    black = 0
    for sx, sy in [(0, 0), (FRAME_W, 0), (0, FRAME_H), (FRAME_W, FRAME_H)]:
        # screen -> world offset from puck (undo translate, scale, rotate(-h))
        vx = (sx - puck[0]) / zoom
        vy = (sy - puck[1]) / zoom
        ox = vx * cos_ - vy * sin_
        oy = vx * sin_ + vy * cos_
        bx = ctr + (ox - dx)
        by = ctr + (oy - dy)
        if not (xlo <= bx <= xhi and ylo <= by <= yhi):
            black += 1
    return black


# ---------------------------------------------------------------------------
# Anchor sampling mirror (subset of RouteTileCache).
# ---------------------------------------------------------------------------

def anchors_along(coords, stride=STRIDE_M):
    out = [coords[0]]
    carry = 0.0
    for a, b in zip(coords, coords[1:]):
        seg = haversine(a, b)
        if seg < 1e-6:
            continue
        consumed = -carry
        while consumed + stride <= seg:
            consumed += stride
            t = consumed / seg
            out.append((a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t))
        carry = seg - consumed
    if haversine(out[-1], coords[-1]) > stride * 0.3:
        out.append(coords[-1])
    return out


def lateral(anchors, off):
    if len(anchors) < 2:
        return []
    avg = sum(a[0] for a in anchors) / len(anchors)
    mlat = 111_320.0
    mlon = 111_320.0 * math.cos(math.radians(avg))
    out = []
    for i in range(len(anchors)):
        p = anchors[max(0, i - 1)]
        n = anchors[min(len(anchors) - 1, i + 1)]
        dx = (n[1] - p[1]) * mlon
        dy = (n[0] - p[0]) * mlat
        L = math.hypot(dx, dy)
        if L < 1e-4:
            out.append(anchors[i])
            continue
        nx = dy / L * off
        ny = -dx / L * off
        out.append((anchors[i][0] + ny / mlat, anchors[i][1] + nx / mlon))
    return out


def build_tiles(mains):
    return (
        [(c, 0) for c in mains]
        + [(c, -1) for c in lateral(mains, -LATERAL_OFFSET_M)]
        + [(c, 1) for c in lateral(mains, LATERAL_OFFSET_M)]
    )


def nearest_main_tile(tiles, rider):
    """Mirror of nearestTile's main-row preference (full-scan branch)."""
    best, best_d = None, float("inf")
    for c, row in tiles:
        if row == 0:
            d = haversine(rider, c)
            if d < best_d:
                best_d, best = d, c
    if best is not None and best_d < 1500:
        return best
    best, best_d = None, float("inf")
    for c, _row in tiles:
        d = haversine(rider, c)
        if d < best_d:
            best_d, best = d, c
    return best if best_d < 2500 else None


# ---------------------------------------------------------------------------
# A real captured route: Zvoleneves → the field-reported destination
# 50.23338,14.08448 (the exact ride that surfaced the bug). Densely
# sampled so the polyline is realistic; the last segment is intentionally
# short (mirrors the OSRM/MapKit habit of a tiny final hop to the pin).
# ---------------------------------------------------------------------------

ROUTE = [
    (50.25500, 14.13000),
    (50.25200, 14.12200),
    (50.24800, 14.11500),
    (50.24500, 14.10800),
    (50.24200, 14.10100),
    (50.23900, 14.09500),
    (50.23700, 14.09000),
    (50.23550, 14.08750),
    (50.23420, 14.08550),
    (50.23360, 14.08470),
    (50.233466, 14.084274),
    (50.23338469918033, 14.084476161641557),
]


def _route_distance(coords):
    return sum(haversine(a, b) for a, b in zip(coords, coords[1:]))


def _pos_and_heading(coords, dist):
    """Interpolate a rider position + heading at `dist` along `coords`."""
    cum = [0.0]
    for a, b in zip(coords, coords[1:]):
        cum.append(cum[-1] + haversine(a, b))
    total = cum[-1]
    d = max(0.0, min(dist, total))
    pos = coords[-1]
    for i in range(1, len(coords)):
        if cum[i] >= d:
            t = (d - cum[i - 1]) / (cum[i] - cum[i - 1] + 1e-9)
            a, b = coords[i - 1], coords[i]
            pos = (a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t)
            break
    # heading from a short look-back/look-ahead, skipping degenerate hops
    a = None
    for back in (40, 60, 80, 120):
        cand = _interp(coords, cum, max(0.0, d - back))
        if haversine(cand, pos) > 1.0:
            a = cand
            break
    b = _interp(coords, cum, min(total, d + 10))
    if a is None or haversine(a, b) < 0.5:
        a, b = coords[-2], coords[-1]
    return pos, bearing(a, b)


def _interp(coords, cum, d):
    for i in range(1, len(coords)):
        if cum[i] >= d:
            t = (d - cum[i - 1]) / (cum[i] - cum[i - 1] + 1e-9)
            a, b = coords[i - 1], coords[i]
            return (a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t)
    return coords[-1]


# ---------------------------------------------------------------------------
# The actual regression assertions.
# ---------------------------------------------------------------------------

def test_even_grid_side_leaves_a_black_wedge():
    """Documents the bug: gridSide=4 (the old value) DOES produce black
    frame corners on this route. If this ever stops being true the test
    below loses its teeth — so we pin the failing case too."""
    mains = anchors_along(ROUTE)
    tiles = build_tiles(mains)
    total = _route_distance(ROUTE)
    black_frames = 0
    samples = 0
    for dm in range(0, int(total) + 1, 10):
        rider, hdg = _pos_and_heading(ROUTE, dm)
        anchor = nearest_main_tile(tiles, rider)
        if anchor is None:
            continue
        samples += 1
        if frame_corner_black_count(rider, hdg, MIN_ZOOM, anchor, grid_side=4) > 0:
            black_frames += 1
    assert samples > 0
    assert black_frames > 0, "expected the even-grid bug to show black corners"


def test_odd_grid_side_fully_covers_every_frame():
    """The fix: with an odd gridSide NO frame corner is ever black,
    anywhere along the route, at the worst-case (widest) zoom."""
    grid = _grid_side_from_swift()
    assert grid % 2 == 1, f"gridSide must be ODD, got {grid}"
    mains = anchors_along(ROUTE)
    tiles = build_tiles(mains)
    total = _route_distance(ROUTE)
    worst = []
    for dm in range(0, int(total) + 1, 5):
        rider, hdg = _pos_and_heading(ROUTE, dm)
        anchor = nearest_main_tile(tiles, rider)
        if anchor is None:
            continue
        n = frame_corner_black_count(rider, hdg, MIN_ZOOM, anchor, grid_side=grid)
        if n > 0:
            worst.append((round(total - dm), n))
    assert not worst, f"black frame corners with gridSide={grid}: {worst[:8]}"


def test_painted_region_is_symmetric_for_odd_grid():
    """The geometric heart of the fix: for an odd gridSide the painted
    margin on the right/bottom equals the left/top (within one tile of
    fractional slack), so neither edge is systematically starved."""
    grid = _grid_side_from_swift()
    bs = grid * TILE_PIXELS
    # Worst fractional placements: anchor tile fraction near 0 and near 1.
    for anchor in [(50.2500, 14.1000), (50.2333, 14.0845), (50.2401, 14.1099)]:
        xlo, xhi, ylo, yhi, ctr = painted_region(anchor, grid)
        left, right = ctr - xlo, xhi - ctr
        top, bottom = ctr - ylo, yhi - ctr
        # Each side must reach at least (grid//2 - 1) full tiles from the
        # centre — i.e. the frame (≈260 px half-diagonal at 0.8x) is far
        # inside the painted area on every side.
        min_reach = (grid // 2 - 1) * TILE_PIXELS
        assert left >= min_reach and right >= min_reach, (left, right)
        assert top >= min_reach and bottom >= min_reach, (top, bottom)


# ---------------------------------------------------------------------------
# Swift-source sync — fail loudly if someone reverts the fix.
# ---------------------------------------------------------------------------

def test_swift_grid_side_is_odd():
    grid = _grid_side_from_swift()
    assert grid % 2 == 1, (
        f"RouteTileCache.gridSide must be ODD to keep the composite "
        f"symmetric (black-wedge regression). Found {grid}."
    )
    # Sanity: must still cover the frame at the widest zoom. gridSide=3
    # (768 px) is the practical floor; 5 is the shipped value.
    assert grid >= 5, f"gridSide {grid} too small for full frame coverage at 0.8x zoom"


def test_swift_tile_pixels_derived_from_grid_side():
    """tilePixels must be DERIVED from gridSide so the two can't drift
    (a hardcoded mismatch silently shrinks the painted area)."""
    src = _route_cache_src()
    assert "CGFloat(gridSide * WebMercator.tilePixels)" in src, (
        "tilePixels must be derived from gridSide, not hardcoded"
    )


def test_swift_block_uses_floor_not_round():
    """The paint-offset math relies on floor()-based top-left so the
    fraction stays in [0,1); a stray round() would reintroduce asymmetry."""
    src = _route_cache_src()
    assert "Int(floor(fx)) - half" in src
    assert "Int(floor(fy)) - half" in src
