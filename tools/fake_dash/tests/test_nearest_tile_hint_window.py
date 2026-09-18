"""Guards for the `nearestTile` hint-window crash.

A rider's app died mid-ride on a via-point route:

    Swift runtime failure: Range requires lowerBound <= upperBound
    RouteTileCache.nearestTile(to:hintIndex:)  RouteTileCache.swift:867
    MapViewSource.drawTileCacheFrame(into:)    MapViewSource.swift:1132

`MapViewSource` keeps ONE `lastTileHintIndex` but renders from THREE
sibling cache layers with very different tile counts (base bakes 8 km,
coarse 3 km, fine 2 km). It resets the hint when `activeLayer` changes —
but a sibling layer finishing its bake *installs a shorter `tiles` array
under the same layer*, and a batch bake reorders `tiles` under a live hint
as well. Either way the hint can exceed `tiles.count`, and then:

    lo = max(0, hint - 4)          # 296
    hi = min(tiles.count - 1, ...) # 79
    for i in lo...hi               # 296...79  -> trap

This module checks the arithmetic directly rather than only asserting on
source text, so it fails for the real reason: a window that cannot be
iterated.
"""

from __future__ import annotations

import pathlib

import pytest

from tests.swift_source import decl_body, strip_comments

REPO = pathlib.Path(__file__).resolve().parents[3]
CACHE = REPO / "TripperDashPP" / "Map" / "RouteTileCache.swift"
VIEW_SOURCE = REPO / "TripperDashPP" / "Map" / "MapViewSource.swift"

HINT_SPAN = 4  # the ±4 neighbourhood nearestTile searches around the hint


def hint_window(hint: int, tile_count: int) -> tuple[int, int]:
    """Reimplementation of the Swift window arithmetic."""
    lo = max(0, hint - HINT_SPAN)
    hi = min(tile_count - 1, hint + HINT_SPAN)
    return lo, hi


@pytest.fixture(scope="module")
def cache_src() -> str:
    return strip_comments(CACHE.read_text(encoding="utf-8"))


# ── The arithmetic itself ────────────────────────────────────────────────

@pytest.mark.parametrize(
    "hint,count",
    [
        (300, 80),   # the real crash: base-cache hint, fine-layer array
        (100, 20),   # coarse-layer hint applied to a short array
        (10, 5),     # hint more than HINT_SPAN past the end
    ],
)
def test_far_stale_hint_produces_an_unusable_window(hint, count):
    """A hint more than HINT_SPAN past the end inverts the window.

    Note this is NOT every out-of-range hint: `lo = hint - 4`, so a hint
    only slightly past the end still yields `lo <= hi` and merely searches
    the wrong tiles. The crash needs `hint - 4 > count - 1`.
    """
    assert hint - HINT_SPAN > count - 1, "this case is not far enough past the end"
    lo, hi = hint_window(hint, count)
    assert lo > hi, (
        f"expected an inverted window for hint={hint} count={count}, got "
        f"{lo}...{hi} — the test's model of the Swift code has drifted"
    )


@pytest.mark.parametrize(
    "hint,count",
    [
        (8, 5),      # out of range, but only just
        (5, 5),      # hint == count
        (1, 1),      # single-tile cache
    ],
)
def test_near_stale_hint_does_not_trap_but_is_still_wrong(hint, count):
    """The quieter half of the same bug.

    These hints are out of range yet produce an iterable window, so they
    never crashed — they just searched a neighbourhood the hint had no
    business selecting. The range check rejects these too, which is why it
    is `hint < tiles.count` and not a crash-shaped `lo <= hi` patch.
    """
    assert hint >= count, "this case is supposed to be out of range"
    lo, hi = hint_window(hint, count)
    assert lo <= hi, "expected a usable-looking window for this case"


@pytest.mark.parametrize(
    "hint,count",
    [
        (0, 1),      # single tile, valid hint  -> lo == hi
        (0, 100),    # start of route
        (99, 100),   # end of route
        (50, 100),   # middle
    ],
)
def test_valid_hint_produces_a_usable_window(hint, count):
    lo, hi = hint_window(hint, count)
    assert lo <= hi, f"hint={hint} count={count} gave an empty window {lo}...{hi}"
    assert 0 <= lo < count and 0 <= hi < count, "window escapes the array"


def test_single_tile_cache_is_the_lo_equals_hi_case():
    """`lo == hi` is reachable, so `(lo + 1)...hi` is a second trap.

    This is what makes the closed-range second pass wrong even after the
    out-of-range hint is rejected.
    """
    lo, hi = hint_window(0, 1)
    assert lo == hi == 0
    assert lo + 1 > hi, "the (lo+1)...hi form would trap here"


# ── The Swift code ───────────────────────────────────────────────────────

def test_hint_is_range_checked_before_building_the_window(cache_src):
    body = decl_body(cache_src, "func nearestTile(to coord: CLLocationCoordinate2D")
    assert "if let hint = hintIndex, hint < tiles.count {" in body, (
        "nearestTile must discard a hint that indexes past this cache's "
        "tiles[]. The hint may come from a different sibling layer, so it "
        "cannot be trusted — and it must be DISCARDED, not clamped: a "
        "clamped window still searches the wrong tiles."
    )


def test_out_of_range_hint_falls_through_to_the_full_scan(cache_src):
    """Rejecting the hint must not mean returning nil.

    The full scan below the hint block is the correct answer; skipping it
    would blank the map instead of crashing it, which is not an improvement
    — `nil` sends the renderer to the off-corridor fallback even though a
    perfectly good tile sits in `tiles[]`.
    """
    body = decl_body(cache_src, "func nearestTile(to coord: CLLocationCoordinate2D")
    guard_pos = body.index("if let hint = hintIndex, hint < tiles.count {")
    scan_pos = body.index("for (i, t) in tiles.enumerated() where isMain(i)")
    assert guard_pos < scan_pos, (
        "the full-scan fallback must come after the hint block so a "
        "rejected hint still yields a tile"
    )

    # Ordering alone is not enough: an early return keyed on the hint would
    # keep that ordering while still skipping the scan. The only `return
    # nil` before the scan must be the empty-cache guard.
    before_scan = body[:scan_pos]
    returns_nil = before_scan.count("return nil")
    assert returns_nil == 1, (
        f"expected exactly one `return nil` before the full scan (the "
        f"empty-cache guard), found {returns_nil}. An out-of-range hint "
        f"must fall through to the scan, not bail out early."
    )
    assert "guard !tiles.isEmpty else { return nil }" in before_scan, (
        "the one permitted early return must be the empty-cache guard"
    )


def test_second_pass_does_not_use_a_closed_range_from_lo_plus_one(cache_src):
    """`(lo + 1)...hi` traps when `lo == hi` (single-tile cache)."""
    body = decl_body(cache_src, "func nearestTile(to coord: CLLocationCoordinate2D")
    assert "(lo + 1)...hi" not in body, (
        "the second pass must not use `(lo + 1)...hi` — it traps when "
        "lo == hi, which a single-tile cache with hint 0 produces. Iterate "
        "the whole `lo...hi` window seeded with greatestFiniteMagnitude."
    )
    assert "var bestDist = CLLocationDistance.greatestFiniteMagnitude" in body, (
        "iterating the full window requires seeding bestDist with "
        "greatestFiniteMagnitude rather than tiles[lo]'s distance"
    )


def test_swifts_global_stride_is_not_called_in_this_type(cache_src):
    """`RouteTileCache.stride` shadows the global `stride(from:through:by:)`.

    The type declares `static let stride: CLLocationDistance = 700` (the
    anchor spacing), so inside its own scope a bare `stride(...)` call
    resolves to that Double and fails to compile with

        cannot call value of non-function type 'CLLocationDistance'
        static member 'stride' cannot be used on instance of type 'RouteTileCache'

    Reach for a plain range instead; if a strided sequence is ever truly
    needed here it must be spelled `Swift.stride(...)`.
    """
    assert "static let stride: CLLocationDistance" in cache_src, (
        "this guard assumes RouteTileCache still declares a `stride` "
        "constant — if it was renamed, the shadowing hazard is gone and "
        "this test should be removed"
    )
    body = decl_body(cache_src, "func nearestTile(to coord: CLLocationCoordinate2D")
    assert "stride(from:" not in body or "Swift.stride(from:" in body, (
        "a bare `stride(from:...)` inside RouteTileCache resolves to the "
        "type's own `stride` constant, not Swift's global function. Use a "
        "plain range, or qualify it as `Swift.stride(...)`."
    )


def test_map_view_source_still_resets_the_hint_on_layer_switch(cache_src):
    """The range check is a backstop, not a licence to drop the reset.

    Resetting on a layer switch is what keeps the hint *useful*; the range
    check only stops a missed case from being fatal. Losing the reset would
    silently degrade every frame to a full scan.
    """
    src = strip_comments(VIEW_SOURCE.read_text(encoding="utf-8"))
    assert "if activeLayer != layerBefore { lastTileHintIndex = 0 }" in src, (
        "MapViewSource must still reset lastTileHintIndex when the active "
        "quality layer changes"
    )
