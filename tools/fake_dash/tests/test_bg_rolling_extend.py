"""
Regression mirror for `MapViewSource.extendTileCache(near:)` — the
rolling-window tile bake that runs on every GPS fix.

Field bug (2026-06, Zvoleneves → Terezín): map tiles vanished halfway
through the ride; only the pre-cached fast-start window showed, the
rest of the route fell back to vector-only on dark slate. Root cause:
`extendTileCache` had a `guard applicationState == .active` that made
the rolling extend a no-op in `.background` — but a motorbike rider's
phone is locked in a pocket for the WHOLE ride, so `.active` never
happens after pull-away. The 8 km fast-start window ran out and the
window never grew.

Unlike `scheduleTileCacheRebuild` (full-route bake, GPU-bound when it
used MKMapSnapshotter — correctly deferred in BG, see
test_reroute_lifecycle.py), the rolling extend is pure URLSession +
CGContext: BG-safe AND mandatory in BG. This file pins that extend
bakes in every app state and that the only gate is throttle + already-
baked idempotency. Mirrors the Swift after the BG guard removal.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Optional


class AppState:
    ACTIVE = "active"
    INACTIVE = "inactive"
    BACKGROUND = "background"


THROTTLE_S = 2.0


@dataclass
class FakeRollingSource:
    """Mirror of MapViewSource.extendTileCache + RouteTileCache.extend
    idempotency, modelling time so the throttle can be exercised."""

    app_state: str = AppState.BACKGROUND
    has_cache: bool = True
    last_extend_at: Optional[float] = None
    baked_offsets: set = field(default_factory=set)
    bakes_executed: list = field(default_factory=list)

    def extend_tile_cache(self, snapped_offset: int, now: float) -> None:
        if not self.has_cache:
            return
        # NOTE: no app_state guard here — extend must run in BG (locked
        # phone is the whole ride). Removing this guard IS the fix.
        if self.last_extend_at is not None and (now - self.last_extend_at) < THROTTLE_S:
            return
        self.last_extend_at = now
        # Idempotent: only bake offsets in [snap-500, snap+5000] not yet baked.
        window = range(snapped_offset - 500, snapped_offset + 5000, 700)
        missing = [o for o in window if o not in self.baked_offsets]
        for o in missing:
            self.baked_offsets.add(o)
        if missing:
            self.bakes_executed.append((snapped_offset, len(missing)))


def test_extend_bakes_in_background():
    """The bug guard: BG is the ONLY state that matters on a bike."""
    src = FakeRollingSource(app_state=AppState.BACKGROUND)
    src.extend_tile_cache(8000, now=10.0)
    assert src.bakes_executed, "rolling extend must bake while locked"


def test_extend_bakes_in_every_state():
    for state in (AppState.ACTIVE, AppState.INACTIVE, AppState.BACKGROUND):
        src = FakeRollingSource(app_state=state)
        src.extend_tile_cache(8000, now=10.0)
        assert src.bakes_executed, f"extend must bake in {state}"


def test_throttle_still_applies():
    src = FakeRollingSource()
    src.extend_tile_cache(8000, now=10.0)
    src.extend_tile_cache(8200, now=11.0)  # <2 s later → throttled
    assert len(src.bakes_executed) == 1
    src.extend_tile_cache(8400, now=13.0)  # >2 s later → fires
    assert len(src.bakes_executed) == 2


def test_idempotent_when_already_baked():
    src = FakeRollingSource()
    src.extend_tile_cache(8000, now=10.0)
    n_first = len(src.baked_offsets)
    src.extend_tile_cache(8000, now=20.0)  # same window, all baked → no new
    assert len(src.baked_offsets) == n_first


def test_no_cache_is_noop():
    src = FakeRollingSource(has_cache=False)
    src.extend_tile_cache(8000, now=10.0)
    assert not src.bakes_executed


def test_rolling_window_advances_as_rider_moves():
    src = FakeRollingSource()
    src.extend_tile_cache(8000, now=10.0)
    src.extend_tile_cache(13000, now=20.0)  # 5 km later
    assert max(src.baked_offsets) >= 13000 + 5000 - 700
