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


# --- Connection-block cleanup (bike-link audit) ------------------------------
#
# Unused symbols in `Tripper/` and `Stream/` were deleted, the per-packet
# initial-burst TX hex moved to `.debug` so it stays out of Release logs, and
# `deviceHostname()` lost a redundant `MainActor.run` hop (BikeLink is already
# `@MainActor`).


def test_unused_link_symbols_are_gone():
    assert not re.search(r"\bhandshakeOverallTimeout\b", _src("Tripper/K1GConstants.swift"))
    assert not re.search(r"\bextractPubkey\b", _src("Tripper/RsaHandshake.swift"))
    assert not re.search(r"\bconnectionStateLabel\b", _src("Stream/RtpStreamer.swift"))


def test_dash_socket_start_has_no_timeout_parameter():
    sock = _src("Tripper/DashSocket.swift")
    assert "func start() async throws {" in sock
    link = _src("Tripper/BikeLink.swift")
    assert "s.start(timeout:" not in link
    assert "try await s.start()" in link


def test_initial_burst_tx_hex_is_debug_level():
    handshake = decl_body(_src("Tripper/BikeLink.swift"), "private func runHandshake(")
    tx = [ln for ln in handshake.splitlines() if "TX burst #" in ln]
    assert len(tx) == 1, tx
    assert "log.debug(" in tx[0]


def test_device_hostname_is_plain_main_actor_static():
    link = _src("Tripper/BikeLink.swift")
    body = decl_body(link, "private static func deviceHostname(")
    assert body.startswith("private static func deviceHostname() -> String {")
    assert "MainActor.run" not in body
    assert "let hostname = Self.deviceHostname()" in link


def test_empty_reconnect_branch_block_is_gone():
    # The observer's final `else` held an `if` whose body was only a comment;
    # the comment now sits directly above applyKeepAwake().
    src = _src("App/AppStatus.swift")
    assert not re.search(r"if state == \.connected && !self\.isStreaming \{\s*\}", src)
