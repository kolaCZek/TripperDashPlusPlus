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


# ----------------------------------------------------------------------
# Dead UI removed in chore/remove-dead-ui.
#
# - `MapPreviewView` was not mounted anywhere since Phase 7a.
# - `FavoriteEditorSheet` was only ever opened with `existing: nil`, so its
#   edit branch, Delete button and "Edit favorite" title were unreachable.
# - `PlanningMapView.onTapWaypoint` was only ever passed a no-op closure.
# - `DashPreviewPanel` duplicated the byte-identical `LiveActivityController`
#   distance/ETA formatters; `NavigationHUD` had two copies of the
#   "1h 23m" / "15 min" formatter.
# ----------------------------------------------------------------------

PBXPROJ = APP / "TripperDashPP.xcodeproj" / "project.pbxproj"


def test_map_preview_view_is_gone():
    assert not (APP / "UI" / "MapPreviewView.swift").exists()
    assert "MapPreviewView" not in PBXPROJ.read_text(encoding="utf-8")
    # Its snapshot-parking helper still has live users.
    assert (APP / "Map" / "SnapshotterPark.swift").exists()
    for rel in ("UI/Navigation/RouteProgressMap.swift",
                "UI/Navigation/SavedRoutePreviewMap.swift"):
        assert "SnapshotterPark.shared" in _src(rel), rel


def test_favorite_editor_is_add_only():
    src = _src("UI/Navigation/FavoriteEditorSheet.swift")
    assert not re.search(r"\bexisting\b", src)
    assert "Edit favorite" not in src
    assert "Delete favorite" not in src
    assert "removeFavorite" not in src
    assert "updateFavorite" not in src
    assert '.navigationTitle("New favorite")' in src
    assert "store.addFavorite(fav)" in src
    picker = _src("UI/MapPickerView.swift")
    assert "FavoriteEditorSheet(seed: favoriteEditorSeed)" in picker
    assert "FavoriteEditorSheet(existing:" not in picker


def test_planning_map_has_no_tap_waypoint_hook():
    src = _src("UI/Navigation/PlanningMapView.swift")
    assert not re.search(r"\bonTapWaypoint\b", src)
    # Pins still deselect so they never stick in the selected state.
    body = decl_body(src, "func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView)")
    assert "deselectAnnotation" in body
    assert not re.search(r"\bonTapWaypoint\b", _src("UI/MapPickerView.swift"))


def test_dash_preview_reuses_live_activity_formatters():
    src = _src("UI/DashPreviewPanel.swift")
    dist = decl_body(src, "private func distanceText(")
    assert "LiveActivityController.distanceText(meters: m, imperial: bubble.imperial)" in dist
    eta = decl_body(src, "private func etaText(")
    assert "LiveActivityController.etaText(date: bubble.etaDate, is24Hour: bubble.is24Hour)" in eta
    assert "DateFormatter" not in src
    assert "3.280839895013123" not in src


def test_navigation_hud_has_one_hours_minutes_formatter():
    src = _src("UI/Navigation/NavigationHUD.swift")
    assert src.count("% 3600") == 1
    assert "Self.hoursMinutes(etaCardSeconds)" in decl_body(src, "private var timeRemaining:")
    assert "Self.hoursMinutes(nav.finalDestinationEtaSeconds)" in decl_body(
        src, "private var finalTimeRemaining:")


def test_cache_size_formatter_is_cached():
    src = _src("UI/StreamingView.swift")
    body = decl_body(src, "private func formatStats(")
    assert "ByteCountFormatter()" not in body
    assert "Self.byteFormatter.string(" in body
    assert "private static let byteFormatter: ByteCountFormatter" in src
