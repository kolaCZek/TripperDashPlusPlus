"""Baked composites far behind the rider are evicted (review C2).

`RouteTileCache` never pruned: every composite baked on a ride (0.2-0.5 MB
PNG each, three layers) stayed in `bakedTileByIndex` / `tiles` until the
route changed. `bakeAnchors` now drops anchors more than `evictBehindMeters`
behind `lastRiderRouteOffset` before its route-order rebuild, so `tiles`,
`tileRowKind` and `tileAnchorIndex` (all rebuilt from `bakedTileByIndex`)
stay parallel, and it drops their decoded images from `imageCache`.

Python mirror of the eviction + rebuild, plus a drift guard pinning the
Swift to it.
"""

from __future__ import annotations

import pathlib
import re

from tests.swift_source import decl_body, strip_comments

CACHE = pathlib.Path(__file__).resolve().parents[3] / "TripperDashPP/Map/RouteTileCache.swift"


def _src() -> str:
    return strip_comments(CACHE.read_text(encoding="utf-8"))


def _const(name: str) -> float:
    m = re.search(rf"static let {name}: CLLocationDistance = ([\d_]+)", _src())
    assert m, name
    return float(m.group(1).replace("_", ""))


def evict_and_rebuild(baked, anchors, image_cache, rider_offset):
    """Mirror of the tail of `bakeAnchors`. `anchors[i]` = (routeOffset,
    lateralRow); `baked` = {anchor index: tile}; `image_cache` = set of
    anchor indices with a decoded image."""
    evict_before = rider_offset - _const("evictBehindMeters")
    evicted = [i for i in baked if anchors[i][0] < evict_before]
    for i in evicted:
        del baked[i]
        image_cache.discard(i)
    order = sorted(baked, key=lambda i: (anchors[i][0], anchors[i][1]))
    tiles = [baked[i] for i in order]
    row_kind = [anchors[i][1] for i in order]
    return evicted, tiles, row_kind, order


def _corridor(km: float):
    anchors = []
    for k in range(int(km * 1000 / 700) + 1):
        for row in (0, -1, 1):
            anchors.append((k * 700.0, row))
    return anchors


def test_eviction_drops_only_far_behind_and_keeps_arrays_parallel():
    anchors = _corridor(20)
    baked = {i: f"tile{i}" for i in range(len(anchors))}
    image_cache = set(baked)
    rider = 10_000.0

    evicted, tiles, row_kind, anchor_index = evict_and_rebuild(baked, anchors, image_cache, rider)

    assert evicted, "a rider 10 km in must shed the start of the route"
    keep_from = rider - _const("evictBehindMeters")
    assert all(anchors[i][0] < keep_from for i in evicted)
    assert all(anchors[i][0] >= keep_from for i in anchor_index)
    assert not image_cache & set(evicted)
    assert len(tiles) == len(row_kind) == len(anchor_index) == len(baked)
    assert tiles == [f"tile{i}" for i in anchor_index]
    assert row_kind == [anchors[i][1] for i in anchor_index]


def test_nothing_the_renderer_can_still_pick_is_evicted():
    """The snap can put the rider up to `snapBackwardWindow` back, and a drawn
    tile can be up to `maxTileCentreDistance` away; `extend` re-bakes from
    `rollingTrailMeters` back. All must sit inside the kept window, or a tile
    is evicted while still in use (or evicted and re-baked every pass)."""
    for name in ("snapBackwardWindow", "maxTileCentreDistance", "rollingTrailMeters"):
        assert _const(name) < _const("evictBehindMeters"), name

    anchors = _corridor(20)
    baked = {i: i for i in range(len(anchors))}
    rider = 0.0
    evicted, *_ = evict_and_rebuild(baked, anchors, set(), rider)
    assert evicted == [], "the start of a ride evicts nothing"


def test_swift_bake_anchors_matches_mirror():
    body = decl_body(_src(), "private func bakeAnchors(")
    evict = body.index("let evictBefore = lastRiderRouteOffset - Self.evictBehindMeters")
    rebuild = body.index("let sortedIdxs = bakedTileByIndex.keys.sorted")
    assert evict < rebuild
    block = body[evict:rebuild]
    assert "allAnchors[$0].routeOffsetMeters < evictBefore" in block
    assert "bakedTileByIndex.removeValue(forKey: idx)" in block
    assert "imageCache.removeObject(forKey: NSNumber(value: idx))" in block
    # The three parallel arrays still all come from the same sorted keys.
    tail = body[rebuild:]
    assert "tiles = sortedIdxs.map { bakedTileByIndex[$0]! }" in tail
    assert "tileRowKind = sortedIdxs.map { allAnchors[$0].lateralRow }" in tail
    assert "tileAnchorIndex = sortedIdxs" in tail
    assert "tiles.reduce(0) { $0 + $1.jpeg.count }" in tail
