"""Small render-path consistency fixes from the tile pipeline review.

  - C8: `nearestTile` and the renderer's draw-time check use ONE distance
    limit (`RouteTileCache.maxTileCentreDistance`). `nearestTile` used to
    accept tiles up to 2500 m that the renderer then rejected at 1800 m —
    an error log and a full rescan 6×/s in between.
  - B2: the decoded-image memo is keyed by the stable anchor index, not the
    position in `tiles[]`, so a bake batch's reorder no longer purges it
    (which forced a 1280² / 1792² PNG re-decode on main after every batch).
  - C7: the vector-only fallback draws at the base tile layer's ground
    scale (z=15 m/px at the fix latitude), not a fixed 2 m/px that looked
    ~1.5× zoomed in next to the tiles.
"""

from __future__ import annotations

import math
import re
from pathlib import Path

from tests.swift_source import decl_body, strip_comments

MAP = Path(__file__).resolve().parents[3] / "TripperDashPP" / "Map"


def _src(name: str) -> str:
    return strip_comments((MAP / name).read_text(encoding="utf-8"))


# --- C8 ---------------------------------------------------------------------


def test_nearest_tile_and_renderer_share_one_distance_limit():
    cache = _src("RouteTileCache.swift")
    view = _src("MapViewSource.swift")
    limit = float(re.search(
        r"static let maxTileCentreDistance: CLLocationDistance = ([0-9_]+)", cache
    ).group(1).replace("_", ""))
    nearest = decl_body(cache, "func nearestTile(")
    assert "guard bestDist <= Self.maxTileCentreDistance else { return nil }" in nearest
    assert "2500" not in nearest
    frame = decl_body(view, "private func drawTileCacheFrame(")
    assert "if tileDistance > RouteTileCache.maxTileCentreDistance {" in frame

    # Any distance nearestTile accepts, the renderer draws — and vice versa.
    def nearest_accepts(d): return d <= limit
    def renderer_accepts(d): return not d > limit
    for d in [0, 1500, limit - 1, limit, limit + 1, 2000, 2499, 2600]:
        assert nearest_accepts(d) == renderer_accepts(d), d


# --- B2 ---------------------------------------------------------------------


def _bake_order(baked: dict[int, tuple[float, int]]) -> list[int]:
    """Mirror of the bakeAnchors reorder: anchor indices sorted by
    (routeOffset, lateralRow)."""
    return sorted(baked, key=lambda i: baked[i])


def test_image_memo_keys_survive_a_batch_reorder():
    # anchor index -> (routeOffsetMeters, lateralRow)
    baked = {10: (7000.0, 0), 11: (7700.0, 0), 40: (7000.0, -1)}
    order = _bake_order(baked)  # tileAnchorIndex after batch 1
    # The memo holds "the decoded picture of anchor X" under some key.
    by_position = {pos: a for pos, a in enumerate(order)}
    by_anchor = {a: a for a in order}
    # A later batch bakes anchors that sort BEFORE the existing ones (the
    # rider's trail after a hard snap), shifting every position.
    baked.update({8: (5600.0, 0), 9: (6300.0, 0)})
    order2 = _bake_order(baked)  # tileAnchorIndex after batch 2
    for pos, anchor in enumerate(order2):
        if pos in by_position:
            # Old position key: some OTHER anchor's picture (hence the purge).
            assert by_position[pos] != anchor
        if anchor in by_anchor:
            # Anchor key via tileAnchorIndex[pos]: still the right picture.
            assert by_anchor[order2[pos]] == anchor


def test_swift_image_memo_is_keyed_by_anchor_index_and_not_purged():
    cache = _src("RouteTileCache.swift")
    bake = decl_body(cache, "private func bakeAnchors(")
    assert "imageCache.removeAllObjects()" not in bake
    assert "tileAnchorIndex = sortedIdxs" in bake
    image = decl_body(cache, "func image(for tile: RouteTile, atIndex idx: Int)")
    assert "let key = NSNumber(value: tileAnchorIndex[idx])" in image
    assert "NSNumber(value: idx)" not in image
    # A new route on the same instance invalidates anchor indices.
    for anchor in ["func prerender(\n        route: MKRoute,\n        progress:",
                   "func prerender(\n        route: MKRoute,\n        around coord:"]:
        body = decl_body(cache, anchor)
        assert "tileAnchorIndex.removeAll(" in body
        assert "imageCache.removeAllObjects()" in body


# --- C7 ---------------------------------------------------------------------


def metres_per_pixel(lat: float, zoom: int) -> float:
    """Mirror of WebMercator.metersPerPixel."""
    return 40_075_016.686 * math.cos(math.radians(lat)) / (256 * 2 ** zoom)


def test_vector_fallback_uses_the_base_tile_scale():
    view = _src("MapViewSource.swift")
    vec = decl_body(view, "private func drawVectorOnlyFrame(")
    assert "metersPerPx: Double = 2.0" not in vec
    assert ("let metersPerPx = WebMercator.metersPerPixel(latitude: centerLat,\n"
            "                                                     zoom: MapViewSource.baseLayerZoom)") in vec
    # Both paths then scale by currentZoom — the tile path for the base layer
    # draws at layerScale 1.
    assert "ctx.scaleBy(x: currentZoom, y: currentZoom)" in vec
    # The old constant was ~1.5× off at 50°N.
    assert 1.4 < metres_per_pixel(50.0, 15) / 2.0 < 1.6
