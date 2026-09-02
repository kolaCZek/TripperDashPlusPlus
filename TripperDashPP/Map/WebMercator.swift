//
//  WebMercator.swift
//  TripperDashPP
//
//  Pure-math helpers for the Slippy Map (Web Mercator / EPSG:3857)
//  tile scheme used by every OSM-derived raster provider on Earth.
//
//  Tiles are addressed by (zoom, x, y) where:
//    - zoom 0 is one tile covering the whole world (256 × 256 px)
//    - each zoom level doubles in both dimensions: 4 tiles at z=1,
//      16 at z=2, … 2^(2z) at zoom z
//    - x runs west→east, y runs north→south
//    - a single tile covers 360 / 2^z degrees of longitude and a
//      latitude band that GROWS toward the poles (Mercator stretch)
//
//  Reference: https://wiki.openstreetmap.org/wiki/Slippy_map_tilenames
//
//  We isolate all of this in one tiny enum so the rest of the codebase
//  can speak in lat/lon + zoom level and never see the inverse-Gudermannian.
//

import CoreLocation
import Foundation

/// Web Mercator projection helpers. Stateless, pure functions.
enum WebMercator {

    /// Standard OSM tile size in pixels (logical, pre-Retina).
    static let tilePixels: Int = 256

    /// Default zoom level for the TripperDash renderer.
    ///
    /// Picked empirically:
    ///   - z=15 → 1 tile ≈ 1.2 km × 0.8 km at 50°N → similar coverage
    ///     to the old MKMapSnapshotter `tileSpanMeters = 1200` setting
    ///   - z=16 → ~600 m / tile, very zoomed in (good for city streets
    ///     but loses context on highways)
    ///   - z=14 → ~2.4 km / tile, too zoomed out for turn-by-turn
    nonisolated static let defaultZoom: Int = 15

    /// Convert a geographic coordinate to a *fractional* tile address
    /// at the given zoom level. Integer part = tile index; fractional
    /// part = position within that tile [0.0, 1.0).
    ///
    /// Returning fractional tile coords (not just integers) is what
    /// lets the stitcher pixel-align an arbitrary center inside a
    /// 4×4 grid — without it we'd snap to tile corners and the user's
    /// position would jitter by ~150 m every time it crossed a tile
    /// boundary.
    static func tile(for coord: CLLocationCoordinate2D, zoom: Int) -> (x: Double, y: Double) {
        let n = pow(2.0, Double(zoom))
        // Sanitise BEFORE any arithmetic. CoreLocation hands out
        // `kCLLocationCoordinate2DInvalid` (NaN, NaN) whenever a fix is
        // unusable, and a NaN here propagates straight into the caller's
        // `Int(floor(fx))`, which is a hard Swift runtime trap
        // ("Double value cannot be converted to Int because it is either
        // infinite or NaN") — i.e. an instant crash, not a bad tile.
        //
        // Longitude was previously left unclamped while latitude was
        // clamped, so an out-of-range or non-finite longitude sailed
        // through. Both are now clamped and non-finite input falls back to
        // (0, 0), which yields a valid — if wrong — tile the caller can
        // render instead of killing the process.
        let safeLat = coord.latitude.isFinite ? coord.latitude : 0
        let safeLon = coord.longitude.isFinite ? coord.longitude : 0
        let clampedLat = max(-85.0511, min(85.0511, safeLat))
        let clampedLon = max(-180.0, min(180.0, safeLon))
        let clampedLatRad = clampedLat * .pi / 180.0
        let x = (clampedLon + 180.0) / 360.0 * n
        let y = (1.0 - log(tan(clampedLatRad) + 1.0 / cos(clampedLatRad)) / .pi) / 2.0 * n
        // Belt and braces: if the Gudermannian still produced a non-finite
        // value (shouldn't after clamping, but this is the only thing
        // standing between a numeric edge case and a process kill), hand
        // back the map centre rather than something `Int()` will trap on.
        guard x.isFinite, y.isFinite else { return (n / 2, n / 2) }
        return (x, y)
    }

    /// Inverse of `tile(for:zoom:)`: tile (x, y) at zoom → coord of
    /// the tile's TOP-LEFT corner.
    static func coordinate(forTile x: Double, y: Double, zoom: Int) -> CLLocationCoordinate2D {
        let n = pow(2.0, Double(zoom))
        let lon = x / n * 360.0 - 180.0
        // Forward Gudermannian. atan(sinh(...)) is the standard form;
        // numerically well-behaved across all valid y ∈ [0, n].
        let latRad = atan(sinh(.pi * (1.0 - 2.0 * y / n)))
        let lat = latRad * 180.0 / .pi
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    /// Meters per pixel at the given latitude and zoom. Used by the
    /// renderer to draw the polyline + position chevron at the right
    /// scale on a stitched tile bitmap.
    ///
    /// Formula: at the equator, one tile = 40075017 m / 2^z, and one
    /// tile = `tilePixels` px → mpp = circumference / (tilePixels * 2^z).
    /// At latitude φ the horizontal scale shrinks by cos(φ).
    static func metersPerPixel(latitude: Double, zoom: Int) -> Double {
        let earthCircumference = 40_075_016.686
        let n = pow(2.0, Double(zoom))
        // Same NaN-hardening as `tile(for:zoom:)`: `cos(NaN)` is NaN, which
        // would flow into `tileRange`'s `Int(floor(...))` and trap. Callers
        // divide by this value, so it must also never be zero — clamp short
        // of the poles where cos → 0.
        let safeLat = latitude.isFinite ? latitude : 0
        let clampedLat = max(-85.0511, min(85.0511, safeLat))
        return earthCircumference * cos(clampedLat * .pi / 180.0) / (Double(tilePixels) * n)
    }

    /// Pixels per degree of longitude at the given latitude and zoom.
    /// Inverse-shaped sibling of `metersPerPixel`, but expressed in
    /// the units that `MapViewSource` already speaks.
    ///
    /// Derivation: 360° of lon spans 2^z tiles = tilePixels * 2^z px,
    /// then the Mercator x stretch contributes cos(φ)⁻¹ … but for the
    /// purpose of mapping lon-offsets to pixel-offsets at a fixed
    /// latitude row, the relationship is uniform: 1° lon = (tilePixels
    /// * 2^z / 360) px. Latitude cosine is already baked in by the
    /// Mercator projection's compression of high-lat rows.
    static func pixelsPerDegreeLongitude(zoom: Int) -> Double {
        let n = pow(2.0, Double(zoom))
        return Double(tilePixels) * n / 360.0
    }

    /// Pixels per degree of latitude at the given latitude and zoom.
    /// LATITUDE-DEPENDENT because Mercator stretches the y-axis as
    /// you approach the poles. Used by the renderer to position the
    /// chevron correctly along the y-axis.
    ///
    /// We get this by numerical differentiation of the y-pixel
    /// formula — much shorter than expanding the closed form, and
    /// since the renderer only needs ~1 m precision over a single
    /// tile, the tiny error from a 0.0001° probe is irrelevant.
    static func pixelsPerDegreeLatitude(latitude: Double, zoom: Int) -> Double {
        let n = pow(2.0, Double(zoom))
        let probe = 0.0001  // ~11 m at the equator
        // Convert lat→y twice and divide. cos & log give very stable
        // numbers in the latitude range we care about.
        func y(_ lat: Double) -> Double {
            let latRad = lat * .pi / 180.0
            return (1.0 - log(tan(latRad) + 1.0 / cos(latRad)) / .pi) / 2.0 * n
        }
        let dy = y(latitude + probe) - y(latitude - probe)
        // dy is in tile-units; multiply by tilePixels for pixel-units.
        // Negate because y grows southward but lat grows northward;
        // we want a positive "pixels per +1° lat" value.
        return -dy * Double(tilePixels) / (2.0 * probe)
    }

    /// Build the integer tile-index range that fully contains the
    /// `radiusMeters` neighbourhood of `center`. Returned as
    /// (minX, minY, maxX, maxY), inclusive on both ends. Used by
    /// the route-tile-cache to know which 16 tiles (typically 4×4)
    /// to fetch around an anchor.
    static func tileBox(
        around center: CLLocationCoordinate2D,
        radiusMeters: Double,
        zoom: Int
    ) -> (minX: Int, minY: Int, maxX: Int, maxY: Int) {
        let mpp = metersPerPixel(latitude: center.latitude, zoom: zoom)
        // `mpp` is now always finite and non-zero (see metersPerPixel), but
        // `radiusMeters` is caller-supplied and can itself be non-finite —
        // and every one of the four `Int(floor(...))` below traps on NaN.
        let safeRadius = radiusMeters.isFinite ? max(0, radiusMeters) : 0
        let radiusPx = safeRadius / mpp
        let radiusTiles = radiusPx / Double(tilePixels)
        let (cx, cy) = tile(for: center, zoom: zoom)
        let minX = Int(floor(cx - radiusTiles))
        let maxX = Int(floor(cx + radiusTiles))
        let minY = Int(floor(cy - radiusTiles))
        let maxY = Int(floor(cy + radiusTiles))
        return (minX, minY, maxX, maxY)
    }
}
