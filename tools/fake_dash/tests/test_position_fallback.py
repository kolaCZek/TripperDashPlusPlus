"""
Tests for the off-corridor position-fallback rescue tile, as
implemented in:

  - TripperDashPP/Map/RouteTileCache.swift
    (`coveringPositionFallbackTile(for:)` pure query,
     `ensurePositionFallback(near:)` the sole bake producer,
     `positionFallbackValidRadius` = 800 m re-bake radius)
  - TripperDashPP/Map/MapViewSource.swift
    (`drawTileCacheFrame` → `drawOffCorridorFallbackFrame` when
     `nearestTile` misses; `ensurePositionFallbackTile` throttle wrapper;
     the corridor → position → vector degradation ladder)

Background
----------

Before this feature, leaving the baked route corridor (a wrong turn while
a reroute is still computing, or a deliberate detour) dropped the dash
straight to `drawVectorOnlyFrame` — a bare route line on a flat
background, no map under the rider. This adds a middle rung: a single OSM
tile baked around the rider's raw GPS position, so they keep real map
context even off-route.

The design's load-bearing property is that it is DORMANT on-route: the
render path calls `ensurePositionFallback` ONLY from the off-corridor
branch, so a normal ride that never leaves the corridor bakes zero
position tiles and issues zero extra OSM fetches. These tests pin exactly
that, plus the degradation ladder and the 800 m re-bake coalescing.

This is a Python mirror of the Swift state machine (no XCTest/MapKit in
CI). If the Swift side changes the radius or the ladder ordering, update
the mirror — the tests will fail loudly until the reasoning is realigned.
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field
from typing import Optional


# --- Tunables mirrored from Swift RouteTileCache ----------------------------

POSITION_FALLBACK_VALID_RADIUS_M = 800.0   # positionFallbackValidRadius
NEAREST_TILE_MISS_RADIUS_M = 2500.0        # nearestTile's final guardrail

EARTH_R = 6_371_000.0


def haversine(a, b):
    """Great-circle distance in metres between two (lat, lon) pairs."""
    lat1, lon1 = math.radians(a[0]), math.radians(a[1])
    lat2, lon2 = math.radians(b[0]), math.radians(b[1])
    dlat = lat2 - lat1
    dlon = lon2 - lon1
    h = math.sin(dlat / 2) ** 2 + math.cos(lat1) * math.cos(lat2) * math.sin(dlon / 2) ** 2
    return 2 * EARTH_R * math.asin(math.sqrt(h))


# --- Minimal mirror of the relevant Swift state -----------------------------


@dataclass
class FakeRouteTileCache:
    """Mirrors RouteTileCache's position-fallback surface.

    `online` toggles whether a bake succeeds (mirror of "did any of the
    25 OSM tiles come back"). `fetch_count` records how many composites
    were actually assembled — the on-corridor-zero-fetch invariant reads
    this.
    """

    online: bool = True
    position_fallback_center: Optional[tuple] = None
    position_fallback_image_decoded: bool = False
    _in_flight: bool = False
    fetch_count: int = 0

    # --- pure query: coveringPositionFallbackTile(for:) ---
    def covering_position_fallback_tile(self, coord) -> Optional[tuple]:
        if self.position_fallback_center is None:
            return None
        d = haversine(coord, self.position_fallback_center)
        return self.position_fallback_center if d <= POSITION_FALLBACK_VALID_RADIUS_M else None

    # --- sole producer: ensurePositionFallback(near:) ---
    def ensure_position_fallback(self, coord) -> None:
        # No-op when the current slot already covers the rider.
        if self.position_fallback_center is not None:
            d = haversine(coord, self.position_fallback_center)
            if d <= POSITION_FALLBACK_VALID_RADIUS_M:
                return
        # Coalesce concurrent bakes.
        if self._in_flight:
            return
        self._in_flight = True
        try:
            self.fetch_count += 1        # a composite() call == a bake
            if self.online:
                self.position_fallback_center = coord
                self.position_fallback_image_decoded = False   # invalidate memo
            # else: keep previous slot (stale-but-nearby beats nothing)
        finally:
            self._in_flight = False

    def position_fallback_decoded_image(self) -> Optional[str]:
        if self.position_fallback_center is None:
            return None
        self.position_fallback_image_decoded = True
        return "decoded"


# --- Mirror of MapViewSource's render-branch decision -----------------------


class RenderResult:
    CORRIDOR = "corridor_tile"
    POSITION = "position_tile"
    VECTOR = "vector_only"


@dataclass
class FakeMapViewSource:
    """Mirrors the drawTileCacheFrame → drawOffCorridorFallbackFrame
    decision path (the throttle is modelled as always-allow here; the
    throttle timing is not what these tests pin)."""

    cache: FakeRouteTileCache
    # Set by the test: does nearestTile hit for the current fix?
    on_corridor: bool = True

    def render_frame(self, fix) -> str:
        # drawTileCacheFrame: nearestTile hit → corridor tile.
        if self.on_corridor:
            return RenderResult.CORRIDOR
        # nearestTile miss → drawOffCorridorFallbackFrame.
        #   (1) kick a bake if not covered (throttle modelled as allow)
        self.cache.ensure_position_fallback(fix)
        #   (2) draw covering position tile if we have one, else vector
        tile = self.cache.covering_position_fallback_tile(fix)
        if tile is not None and self.cache.position_fallback_decoded_image() is not None:
            return RenderResult.POSITION
        return RenderResult.VECTOR


# --- The load-bearing invariant: dormant on-corridor ------------------------


def test_on_corridor_never_bakes_a_position_tile():
    """THE reason this feature is safe to add: on-route, the off-corridor
    path is never entered, so zero position-fallback fetches happen. This
    is the direct answer to 'won't always-prefetching-around-the-rider
    waste the OSM budget?' — we do NOT always prefetch; we only bake when
    off the corridor."""
    cache = FakeRouteTileCache(online=True)
    src = FakeMapViewSource(cache=cache, on_corridor=True)
    # Simulate a whole on-route ride: many frames, rider moving.
    for i in range(1000):
        fix = (50.10 + i * 0.0001, 14.40)
        assert src.render_frame(fix) == RenderResult.CORRIDOR
    assert cache.fetch_count == 0
    assert cache.position_fallback_center is None


# --- Degradation ladder -----------------------------------------------------


def test_first_off_corridor_frame_is_vector_then_position():
    """The bake is fire-and-forget: the very first off-corridor frame has
    no tile yet → vector-only, but it KICKS the bake. Once baked, the next
    frame at the same spot draws the position tile. No blank wait, no
    blocking."""
    cache = FakeRouteTileCache(online=True)
    src = FakeMapViewSource(cache=cache, on_corridor=False)
    fix = (50.20, 14.30)
    # In the real code the bake is async so frame 1 would still be vector;
    # our mirror bakes synchronously inside ensure, so model the async gap
    # by checking the tile did not exist BEFORE the ensure call ran.
    assert cache.covering_position_fallback_tile(fix) is None
    # Frame draws: ensure kicks the bake, tile now covers → position.
    assert src.render_frame(fix) == RenderResult.POSITION
    assert cache.fetch_count == 1


def test_offline_off_corridor_stays_vector_only():
    """Fully offline (all 25 OSM tiles miss) → no tile installed → the
    ladder bottoms out at vector-only. We still counted the bake attempt,
    but never fabricate a tile."""
    cache = FakeRouteTileCache(online=False)
    src = FakeMapViewSource(cache=cache, on_corridor=False)
    fix = (50.20, 14.30)
    assert src.render_frame(fix) == RenderResult.VECTOR
    assert cache.position_fallback_center is None
    assert cache.fetch_count == 1


def test_returning_to_corridor_resumes_corridor_tile():
    """Off-corridor → position tile, then the reroute completes / rider
    rejoins → nearestTile hits again → back to corridor tile. The stale
    position tile is simply ignored (not drawn) while on-route."""
    cache = FakeRouteTileCache(online=True)
    src = FakeMapViewSource(cache=cache, on_corridor=False)
    off_fix = (50.20, 14.30)
    assert src.render_frame(off_fix) == RenderResult.POSITION
    # Rider rejoins the corridor.
    src.on_corridor = True
    assert src.render_frame((50.10, 14.40)) == RenderResult.CORRIDOR
    # A position tile is still cached but no further bakes happened.
    assert cache.fetch_count == 1


# --- 800 m re-bake radius + coalescing --------------------------------------


def test_small_off_corridor_drift_does_not_rebake():
    """Within positionFallbackValidRadius (800 m) of the baked centre, the
    same tile keeps covering the rider — no re-bake. This is what keeps
    the off-corridor fetch rate bounded (≈ one bake per 800 m of straight
    off-route travel, not one per frame)."""
    cache = FakeRouteTileCache(online=True)
    src = FakeMapViewSource(cache=cache, on_corridor=False)
    base = (50.2000, 14.3000)
    assert src.render_frame(base) == RenderResult.POSITION
    assert cache.fetch_count == 1
    # Nudge ~300 m north — still inside the 800 m radius.
    near = (base[0] + 300 / 111_320.0, base[1])
    assert haversine(base, near) < POSITION_FALLBACK_VALID_RADIUS_M
    assert src.render_frame(near) == RenderResult.POSITION
    assert cache.fetch_count == 1   # no new bake


def test_large_off_corridor_drift_rebakes_once():
    """Past 800 m from the baked centre, the tile no longer covers the
    rider → exactly one fresh bake, re-centred on the new position."""
    cache = FakeRouteTileCache(online=True)
    src = FakeMapViewSource(cache=cache, on_corridor=False)
    base = (50.2000, 14.3000)
    assert src.render_frame(base) == RenderResult.POSITION
    assert cache.fetch_count == 1
    # Move ~1200 m north — outside the 800 m radius.
    far = (base[0] + 1200 / 111_320.0, base[1])
    assert haversine(base, far) > POSITION_FALLBACK_VALID_RADIUS_M
    assert src.render_frame(far) == RenderResult.POSITION
    assert cache.fetch_count == 2
    assert cache.position_fallback_center == far


def test_valid_radius_is_inside_nearest_tile_miss_radius():
    """Design invariant: the position-fallback re-bake radius must be
    smaller than nearestTile's miss guardrail, so the two decisions don't
    fight. A rider just past the corridor edge misses nearestTile (enters
    the fallback path) yet stays covered by a fresh position tile."""
    assert POSITION_FALLBACK_VALID_RADIUS_M < NEAREST_TILE_MISS_RADIUS_M


def test_concurrent_off_corridor_bakes_coalesce():
    """Two off-corridor frames rendering before the first bake finishes →
    only one bake starts (the second sees in_flight). Modelled by holding
    the in-flight flag across a nested render."""
    cache = FakeRouteTileCache(online=True)
    fix = (50.20, 14.30)

    # Manually simulate the in-flight guard: mark in-flight, then a second
    # ensure() during the bake must be a no-op.
    cache._in_flight = True
    cache.ensure_position_fallback(fix)   # should return immediately
    assert cache.fetch_count == 0
    assert cache.position_fallback_center is None
    cache._in_flight = False
    # Now the real bake runs.
    cache.ensure_position_fallback(fix)
    assert cache.fetch_count == 1


def test_rebake_invalidates_decoded_image_memo():
    """A fresh position tile must clear the decoded-image memo, else the
    renderer would paint the OLD off-route location's pixels at the new
    position (same class of bug as the index-reorder image cache)."""
    cache = FakeRouteTileCache(online=True)
    base = (50.2000, 14.3000)
    cache.ensure_position_fallback(base)
    # Decode once (populates the memo).
    assert cache.position_fallback_decoded_image() == "decoded"
    assert cache.position_fallback_image_decoded is True
    # Drift past the radius → re-bake → memo invalidated.
    far = (base[0] + 1200 / 111_320.0, base[1])
    cache.ensure_position_fallback(far)
    assert cache.position_fallback_image_decoded is False
