"""
Guard against the "map gone black when starting the route" regression.

Field report (external tester, India, iPhone 17 Pro / iOS 27, LTE, 8/2026):
the map turned black the moment navigation started. Root cause: once a
route begins, `routeTileCache` becomes non-nil, so the render path switches
from `drawVectorOnlyFrame` (which paints a coloured background + route line)
to `drawTileCacheFrame`. That function had early `return`s when there was no
GPS fix yet, or when the tile layer wasn't baked yet (still baking, or a
slow/failed OSM fetch on a weak mobile link). Those bare `return`s left the
frame on nothing but `voidColor` — a near-black fill — i.e. a black screen.

The fix: every early-out in `drawTileCacheFrame` must fall back to
`drawVectorOnlyFrame` so the rider ALWAYS sees a coloured map + route line,
never a black frame.

Static-source guard (no Xcode / MapKit in CI): parse MapViewSource.swift and
assert the tile-cache path degrades to the vector frame instead of returning
into the void.
"""

from __future__ import annotations

import re
from pathlib import Path


def _repo_root() -> Path:
    return Path(__file__).resolve().parents[3]


def _map_source_src() -> str:
    return (_repo_root() / "TripperDashPP" / "Map" / "MapViewSource.swift").read_text(
        encoding="utf-8"
    )


def _draw_tile_cache_body() -> str:
    """Isolate the body of `drawTileCacheFrame` up to the next private func."""
    src = _map_source_src()
    start = src.index("private func drawTileCacheFrame(into ctx: CGContext)")
    # End at the next `private func ` after the opening.
    nxt = src.index("private func ", start + 10)
    return src[start:nxt]


def test_tile_cache_frame_exists():
    assert "private func drawTileCacheFrame(into ctx: CGContext)" in _map_source_src()


def test_no_bare_return_leaves_black_frame():
    """No early-out in drawTileCacheFrame may `return` without first drawing
    the vector fallback. A bare `return` there = the void-colour black frame
    the India tester saw."""
    body = _draw_tile_cache_body()
    # Every `return` inside the guard ladder must be immediately preceded
    # (within the same guard block) by a drawVectorOnlyFrame / fallback call.
    # We approximate: there must be NO `else { return }` and NO
    # `else { ... return }` that doesn't mention a fallback draw.
    assert "else { return }" not in body, (
        "bare `else { return }` in drawTileCacheFrame leaves the frame on the "
        "black void colour — fall back to drawVectorOnlyFrame instead"
    )


def test_missing_fix_falls_back_to_vector():
    """The no-GPS-fix guard must draw the vector frame, not return black."""
    body = _draw_tile_cache_body()
    m = re.search(r"guard lastFix != nil else \{(.*?)\}", body, re.DOTALL)
    assert m, "no-fix guard not found in drawTileCacheFrame"
    assert "drawVectorOnlyFrame" in m.group(1), (
        "no-GPS-fix path must fall back to drawVectorOnlyFrame (was a bare "
        "return → black screen)"
    )


def test_missing_tile_layer_falls_back_to_vector():
    """The 'tile layer not ready' guard (still baking / failed fetch) must
    also draw the vector frame instead of returning into the void."""
    body = _draw_tile_cache_body()
    m = re.search(
        r"guard let cache = activeTileCache\(.*?\).*?else \{(.*?)\}",
        body,
        re.DOTALL,
    )
    assert m, "activeTileCache guard not found in drawTileCacheFrame"
    assert "drawVectorOnlyFrame" in m.group(1), (
        "unbaked/failed tile-layer path must fall back to drawVectorOnlyFrame "
        "(was a bare return → black screen the India tester reported)"
    )


def test_vector_background_is_not_black():
    """The fallback background must be a visible map tone, not near-black —
    otherwise the fallback would itself look like the black-screen bug."""
    src = (_repo_root() / "TripperDashPP" / "Map" / "MapStyle.swift").read_text(
        encoding="utf-8"
    )
    m = re.search(
        r"var vectorBackground: CGColor \{.*?case \.light: return CGColor\(red: ([\d.]+)",
        src,
        re.DOTALL,
    )
    assert m, "vectorBackground light value not found"
    assert float(m.group(1)) >= 0.5, (
        "light vectorBackground must be a pale tone (>=0.5), not near-black"
    )
