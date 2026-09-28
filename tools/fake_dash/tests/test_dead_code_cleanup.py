"""Dead code removed in the route/tile review cleanup (review section D)
must stay gone.

- D1: `MapViewSource` owned an `MKMapView` that was never on screen (its
  SwiftUI host `MapViewHost` had no users), yet every fix called
  `setRegion`, every route swapped overlays, and it ran user-location
  tracking on the main actor, in the background too. The dash frame is
  CGContext-only; the map view fed nothing.
- D2: the tile URLSession's 100 MB disk URLCache stored every tile a
  second time next to `TileDiskCache`.
- D3: `decimate`, `maxTilesPerRoute`, `tileSpanMeters` / `RouteTile.region`
  had no readers.

Swift can't be compiled on Linux, so pin the absence in source.
"""

from __future__ import annotations

import pathlib
import re

from tests.swift_source import decl_body, strip_comments

APP = pathlib.Path(__file__).resolve().parents[3] / "TripperDashPP"


def _src(rel: str) -> str:
    return strip_comments((APP / rel).read_text(encoding="utf-8"))


def test_map_view_source_has_no_mkmapview():
    src = _src("Map/MapViewSource.swift")
    for banned in (
        r"\bMKMapView\b",
        r"\bMKMapViewDelegate\b",
        r"\bMapViewHost\b",
        r"\bhostView\b",
        r"\bsetRegion\(",
        r"\baddOverlay\(",
        r"\bshowsUserLocation\b",
        r"\buserTrackingMode\b",
        r"\bUIViewRepresentable\b",
    ):
        assert not re.search(banned, src), banned
    # Route coords for the CGContext path are still cached.
    body = decl_body(src, "func setRoutePolyline(")
    assert "routePolylineCoords = coords" in body


def test_tile_url_cache_is_memory_only():
    src = _src("Map/OSMTileFetcher.swift")
    assert "diskCapacity: 0," in src
    assert "memoryCapacity: 4 * 1024 * 1024," in src
    assert "osm-tile-http-cache" not in src


def test_unused_tile_cache_symbols_are_gone():
    src = _src("Map/RouteTileCache.swift")
    for banned in (r"\bdecimate\b", r"\bmaxTilesPerRoute\b", r"\btileSpanMeters\b"):
        assert not re.search(banned, src), banned
    tile = decl_body(src, "nonisolated struct RouteTile: Sendable {")
    assert not re.search(r"\blet region\b", tile)
    assert "MKCoordinateRegion" not in src
