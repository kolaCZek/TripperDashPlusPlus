"""
Guard against the "dash timed out because streaming waited on tile download"
regression.

Field report (rider, underground car park, 8/2026): the app connected to the
dash and planned a route, but after tapping Navigate the bike showed "timeout"
after a while. Root cause: `startNavigation` awaited the full tile prerender
(`installRouteGeometry` → `await cache.prerender`) BEFORE calling
`startStreaming()`. The tile fetch uses `waitsForConnectivity = true`, so with
no cellular (underground) it stalls indefinitely — `startStreaming()` (which
sends projection-on + starts the RTP stream) never runs, and the dash times
out waiting for the phone's projection.

The fix: the dash link must never be held hostage to OSM downloads. Start
streaming immediately after installing route geometry (the renderer draws the
vector fallback until tiles arrive), and run the tile prerender in a detached
background Task AFTER streaming is live.

Static-source guard (no Xcode / MapKit in CI): parse MapPickerView.swift and
assert the ordering — streaming is not gated behind an awaited prerender.
"""

from __future__ import annotations

import re
from pathlib import Path


def _repo_root() -> Path:
    return Path(__file__).resolve().parents[3]


def _map_picker_src() -> str:
    return (_repo_root() / "TripperDashPP" / "UI" / "MapPickerView.swift").read_text(
        encoding="utf-8"
    )


def _start_navigation_body() -> str:
    """Isolate `startNavigation(plan:)` up to the next `private func`."""
    src = _map_picker_src()
    start = src.index("private func startNavigation(plan: PlannedRoute)")
    nxt = src.index("private func ", start + 10)
    return src[start:nxt]


def test_start_navigation_exists():
    assert "private func startNavigation(plan: PlannedRoute)" in _map_picker_src()


def test_streaming_not_behind_awaited_prerender():
    """`startStreaming()` must NOT sit after an `await` on the tile prerender.
    In startNavigation, no `await prerenderRouteTiles` / `await ...prerender`
    may appear BEFORE the `startStreaming()` call."""
    body = _start_navigation_body()
    stream_idx = body.index("startStreaming()")
    before = body[:stream_idx]
    assert "await prerenderRouteTiles" not in before, (
        "startStreaming() runs after `await prerenderRouteTiles` — the dash "
        "link is again hostage to tile downloads (underground timeout bug)"
    )
    assert "await cache.prerender" not in before, (
        "startStreaming() runs after an awaited `cache.prerender` — move the "
        "prerender to a background Task after streaming starts"
    )


def test_geometry_install_is_synchronous():
    """Route geometry must be attached via the synchronous installer, so the
    stream can start without awaiting anything network-bound."""
    body = _start_navigation_body()
    assert "installRouteGeometrySync(" in body, (
        "startNavigation must use the synchronous installRouteGeometrySync so "
        "streaming isn't blocked; the old `await installRouteGeometry` awaited "
        "the tile prerender"
    )
    # The old awaited installer must be gone from this path.
    assert "await installRouteGeometry(" not in body, (
        "old `await installRouteGeometry(...)` still gates startNavigation — "
        "it awaits the tile prerender and can stall the dash link"
    )


def test_prerender_runs_after_streaming():
    """The tile prerender must be kicked off (in a Task) only AFTER the
    startStreaming() call — i.e. streaming is not blocked by it."""
    body = _start_navigation_body()
    stream_idx = body.index("startStreaming()")
    after = body[stream_idx:]
    assert "prerenderRouteTiles" in after, (
        "prerenderRouteTiles must be launched after streaming starts so the "
        "real map still fills in once connectivity returns"
    )


def test_prerender_helper_is_background_only():
    """`prerenderRouteTiles` is the async tile-baking helper; it must not call
    startStreaming itself (ordering is owned by startNavigation)."""
    src = _map_picker_src()
    start = src.index("private func prerenderRouteTiles(")
    nxt = src.index("private func ", start + 10)
    body = src[start:nxt]
    assert "cache.prerender" in body, "prerenderRouteTiles must bake the tile cache"
    assert "startStreaming" not in body, (
        "prerenderRouteTiles must not start streaming — keep ordering in "
        "startNavigation"
    )
