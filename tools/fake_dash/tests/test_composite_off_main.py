"""Tile composites must be stitched off the main actor (review A3), from a
shared decoded-tile cache (review B8).

With SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor, `RouteTileCache.composite`
ran on the main actor: CGContext setup, ~25-49 PNG decodes and blits, the
dark recolour and the PNG encode, for every anchor of every bake — the
1.7-2.5 s main-actor hops of the 2026-09-02 ride. Swift can't be compiled
on Linux, so pin the isolation (and the UIKit-free callees) in source.
"""

from __future__ import annotations

import pathlib
import re

from tests.swift_source import decl_body, strip_comments

APP = pathlib.Path(__file__).resolve().parents[3] / "TripperDashPP"

STATIC_COMPOSITE = "@concurrent nonisolated private static func composite("
STITCH = "nonisolated private static func stitch("
ATTRIBUTION = "nonisolated private static func drawAttribution("


def _src(rel: str) -> str:
    return strip_comments((APP / rel).read_text(encoding="utf-8"))


def test_composite_runs_off_main_and_touches_no_cache_state():
    src = _src("Map/RouteTileCache.swift")
    body = decl_body(src, STATIC_COMPOSITE) + decl_body(src, STITCH)
    # A static takes no `self`, so it cannot reach the cache state.
    assert "self." not in body
    # No UIKit off the main actor: ImageIO encode, CoreText attribution.
    attribution = decl_body(src, ATTRIBUTION)
    for banned in (r"\bUIImage\b", r"\.pngData\(\)", r"\bUIFont\b", r"\bUIColor\b"):
        assert not re.search(banned, body), banned
        assert not re.search(banned, attribution), banned
    assert "CGImageDestinationFinalize(dest)" in body
    # The bake's children call the static with Sendable snapshots, not a
    # `@MainActor` closure over `self`.
    bake = decl_body(src, "private func bakeAnchors(")
    assert "group.addTask { @MainActor" not in bake
    assert bake.count("await RouteTileCache.composite(center: center, zoom: z, gridSide: g, style: style)") == 2
    # Results are still installed on the main actor, one batch at a time.
    assert "bakedTileByIndex[idx] = tile" in bake
    assert "await Task.yield()" in bake
    assert "min(Self.parallelism, total)" in bake


def test_composite_callees_are_nonisolated():
    assert "nonisolated enum WebMercator {" in _src("Map/WebMercator.swift")
    cache = _src("Map/RouteTileCache.swift")
    assert "nonisolated struct RouteTile: Sendable {" in cache
    assert "nonisolated static let parallelism = 3" in cache


def test_stitch_uses_shared_decoded_tile_cache_keyed_without_style():
    """Neighbouring composites share most source tiles; decode each once.
    The key is (z, x, y) only — the dark recolour runs on the whole stitched
    bitmap afterwards, so a raw decoded tile is palette-independent."""
    src = _src("Map/RouteTileCache.swift")
    assert "nonisolated final class DecodedTileCache: @unchecked Sendable {" in src
    cls = decl_body(src, "nonisolated final class DecodedTileCache")
    assert "static let maxTiles = 64" in cls
    assert "func image(z: Int, x: Int, y: Int) -> CGImage?" in cls
    assert "style" not in cls
    stitch = decl_body(src, STITCH)
    lookup = stitch.index("DecodedTileCache.shared.image(z: z, x: absX, y: absY)")
    recolour = stitch.index("style.colorTransform?.applyInPlace(to: ctx)")
    assert lookup < recolour
    assert "DecodedTileCache.shared.insert(decoded, z: z, x: absX, y: absY)" in stitch
