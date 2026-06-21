//
//  RouteTileCache.swift
//  TripperDashPP
//
//  Pre-fetched OSM map tiles along an MKRoute, stitched into 1024×1024
//  composite bitmaps so the BG render path never has to ask MapKit to
//  draw anything.
//
//  Design (post-OSM-migration, late June 2026):
//
//    We used to call `MKMapSnapshotter.start` for each anchor, which
//    bit us on iOS 16+: MapKit's GPU compositor is blocked from
//    `.background` along with the rest of Metal. We had a state
//    machine + did-become-active drain queue + measured-geometry
//    persistence to work around it, and the whole thing was a tax
//    we paid on every reroute.
//
//    OSM raster tiles fix this at the source: they're plain HTTPS
//    PNG GETs (see `OSMTileFetcher`). URLSession works fine from
//    `.background`. The on-disk cache becomes a pile of standard
//    `{z}/{x}/{y}.png` files, browseable in Preview. Geometry is
//    fully deterministic (Web Mercator math, see `WebMercator`),
//    so we no longer persist any measured pxPerDeg headers.
//
//  Tile geometry:
//
//    * Anchor stride: ~700 m along the polyline.
//    * Per-anchor composite: 4×4 OSM tiles (each 256×256 native) →
//      1024×1024 px bitmap centered on the anchor. Span at z=15 is
//      ~1.2 km × 1.2 km at 50°N — same coverage as the old MapKit
//      bake.
//    * Lateral buffer: ±1500 m (left + right wings), unchanged.
//
//  Pre-fetch budget:
//
//    * 35 km route → ~50 main anchors + ~100 lateral = ~150 anchors.
//    * Each anchor fetches up to 16 OSM tiles, deduped against neighbouring
//      anchors and the disk cache → in practice ~300-500 unique tiles
//      for a brand-new region, ~0 for a re-bake of familiar territory.
//    * Wall-clock: ~5-15 s on 4G cold, ~1-2 s warm-cache.
//    * Memory: 150 × 1024² × 4 B ≈ 600 MB raw — same NSCache(8) trick
//      as before keeps working set under 40 MB; full bitmaps live as
//      PNG bytes in `RouteTile.jpeg` (misnomer kept for compat).
//

import CoreGraphics
import CoreLocation
import Foundation
import ImageIO
import MapKit
import OSLog
import UIKit

/// One pre-rendered map tile + the lat/lon region it covers.
///
/// The field name `jpeg` is a historical artifact — the bytes are
/// now PNG-encoded (OSM tiles are PNG natively, and re-encoding to
/// JPEG would discard the alpha channel + add encoding cost for no
/// memory savings on a 256-colour-palette PNG). Renamed inside
/// `MapViewSource` would ripple too far; the name is internal and
/// the contents are still self-describing image data.
struct RouteTile: Sendable {
    /// Center coordinate of the tile composite.
    let center: CLLocationCoordinate2D
    /// Geographic extent the tile covers (informational only —
    /// runtime hit-testing uses pxPerDeg + centerPixel).
    let region: MKCoordinateRegion
    /// Image bytes (PNG). Decoded lazily — see `RouteTileCache.image`.
    let jpeg: Data
    /// Pixel dimensions of the decoded image. Always
    /// `(tilePixels, tilePixels)` for OSM stitches, but kept as a
    /// field for backward compatibility with the MapKit-era renderer.
    let pixelSize: CGSize
    /// Pixel coordinates inside the bitmap where `center` lands.
    /// For OSM stitches this is ALWAYS the exact bitmap midpoint —
    /// the stitcher pixel-aligns the composite around the requested
    /// center. No `MKMapSnapshotter`-style clamping to worry about.
    let centerPixel: CGPoint
    /// Pixels per degree of longitude at `center`, derived analytically
    /// from `WebMercator.pixelsPerDegreeLongitude(zoom:)`. No probe,
    /// no measurement — Web Mercator is fully deterministic.
    let pxPerDegLon: Double
    /// Pixels per degree of latitude at `center`. Latitude-dependent
    /// (Mercator y-stretch) — see `WebMercator.pixelsPerDegreeLatitude`.
    let pxPerDegLat: Double
}

/// Container + builder for `RouteTile`s along an `MKRoute`.
@MainActor
final class RouteTileCache {

    // MARK: - Tunables

    /// Distance between successive composite anchors along the
    /// polyline. Tile composite span is ~1.2 km, so 700 m gives
    /// ~40 % overlap — enough that any rotation up to 360° still
    /// leaves the user position well inside a single composite.
    static let stride: CLLocationDistance = 700

    /// Composite bitmap size in pixels. Equals
    /// `gridSide * WebMercator.tilePixels` so the math stays clean.
    static let tilePixels: CGFloat = 1024

    /// How many OSM tiles per side of each composite. 4 × 256 = 1024 px,
    /// covers ~1.4-1.6 km at z=15 (latitude-dependent) which neatly
    /// contains the 1.2 km nominal span with margin for the request
    /// center landing anywhere inside the central tile.
    static let gridSide: Int = 4

    /// OSM zoom level for the composites. Re-exposed here so callers
    /// (and tests) can find the source of truth in one place even
    /// though the value comes from `WebMercator.defaultZoom`.
    static let zoom: Int = WebMercator.defaultZoom

    /// Composite geographic extent — informational. Real geometry
    /// comes from `pxPerDeg`. ~1.2 m/px after factoring in the
    /// 4× supersample at the renderer's 526×300 output resolution.
    static let tileSpanMeters: CLLocationDistance = 1200

    /// Max parallel composites being assembled. Each composite waits
    /// on up to 16 OSM tile fetches; capping the OUTER loop at 3
    /// composites in flight gives the fetcher's 4-way HTTP gate
    /// some breathing room and prevents progress from going
    /// "0% … 0% … 0% … 100%" in chunks.
    static let parallelism = 3

    /// Lateral buffer distance — how far perpendicular to the route
    /// the wing anchor rows sit. 1500 m means the user can drift up
    /// to ~2 km from the centerline (lateral offset + ~half a tile
    /// span) before the cache misses and the dark fallback kicks in.
    static let lateralOffset: CLLocationDistance = 1500

    /// Hard cap on total composites per route so a 300 km road trip
    /// doesn't try to bake ~1000 anchors. When exceeded, the wings
    /// are decimated uniformly; the main centerline is never thinned.
    static let maxTilesPerRoute: Int = 300

    // MARK: - Stored state

    private(set) var tiles: [RouteTile] = []
    private let imageCache = NSCache<NSNumber, UIImage>()
    private let log = Logger(subsystem: "eu.kolaczek.tripperdashpp", category: "RouteTileCache")

    init() {
        imageCache.countLimit = 8
    }

    // MARK: - Build

    /// Pre-fetch + stitch all composites for `route`. Reports `0…1`
    /// progress on the main actor every time a composite finishes.
    ///
    /// `progress` callback fires with values strictly increasing
    /// from 0 to 1. The final call (1.0) only fires after every
    /// composite has been added to `self.tiles`.
    func prerender(
        route: MKRoute,
        progress: @MainActor @escaping (Double) -> Void
    ) async {
        tiles.removeAll(keepingCapacity: true)
        let mainAnchors = anchorsAlongPolyline(route.polyline, stride: Self.stride)
        // Lateral buffer: same anchor positions, shifted ±lateralOffset
        // meters perpendicular to the route. Gives the rider a tile-
        // backed safety zone if they deviate before reroute fires.
        // Cap on total anchors prevents pathological long routes from
        // pre-fetching forever.
        let leftAnchors  = lateralAnchors(mainAnchors, offsetMeters: -Self.lateralOffset)
        let rightAnchors = lateralAnchors(mainAnchors, offsetMeters: +Self.lateralOffset)
        var anchors = mainAnchors + leftAnchors + rightAnchors
        if anchors.count > Self.maxTilesPerRoute {
            let budget = max(0, Self.maxTilesPerRoute - mainAnchors.count)
            let perWing = budget / 2
            let leftTrim  = Self.decimate(leftAnchors, keepCount: perWing)
            let rightTrim = Self.decimate(rightAnchors, keepCount: perWing)
            anchors = mainAnchors + leftTrim + rightTrim
            log.info("Anchor budget exceeded; decimated wings to \(perWing, privacy: .public) each side")
        }
        log.info("Pre-fetching \(anchors.count, privacy: .public) composites (\(mainAnchors.count, privacy: .public) main + \(anchors.count - mainAnchors.count, privacy: .public) lateral) for route (\(Int(route.distance), privacy: .public) m)")
        progress(0)

        // Bound concurrency at `parallelism` via a simple semaphore-
        // style window. Composite order matches anchor index so
        // heading-up rotation never has to search the whole list.
        let total = anchors.count
        var completed = 0
        var built: [RouteTile?] = Array(repeating: nil, count: total)

        await withTaskGroup(of: (Int, RouteTile?).self) { group in
            var nextIndex = 0
            for _ in 0..<min(Self.parallelism, total) {
                let idx = nextIndex
                nextIndex += 1
                let center = anchors[idx]
                group.addTask { @MainActor in
                    let tile = await Self.composite(center: center)
                    return (idx, tile)
                }
            }
            for await (idx, tile) in group {
                built[idx] = tile
                completed += 1
                progress(Double(completed) / Double(total))
                if nextIndex < total {
                    let i = nextIndex
                    nextIndex += 1
                    let center = anchors[i]
                    group.addTask { @MainActor in
                        let tile = await Self.composite(center: center)
                        return (i, tile)
                    }
                }
            }
        }

        tiles = built.compactMap { $0 }
        log.info("Pre-fetch done: \(self.tiles.count, privacy: .public)/\(total, privacy: .public) composites built")
        progress(1)
    }

    // MARK: - Lookup

    /// Find the composite whose center is closest to `coord`. Returns
    /// `nil` if `coord` is more than ~half a composite span from
    /// every anchor (off-route, re-routing scenario).
    func nearestTile(to coord: CLLocationCoordinate2D, hintIndex: Int? = nil) -> (RouteTile, Int)? {
        guard !tiles.isEmpty else { return nil }

        if let hint = hintIndex {
            let lo = max(0, hint - 2)
            let hi = min(tiles.count - 1, hint + 2)
            var best = lo
            var bestDist = PolylineMath.haversine(coord, tiles[lo].center)
            for i in (lo + 1)...hi {
                let d = PolylineMath.haversine(coord, tiles[i].center)
                if d < bestDist {
                    bestDist = d
                    best = i
                }
            }
            if bestDist < Self.tileSpanMeters * 0.45 {
                return (tiles[best], best)
            }
        }

        var bestIdx = 0
        var bestDist = CLLocationDistance.greatestFiniteMagnitude
        for (i, t) in tiles.enumerated() {
            let d = PolylineMath.haversine(coord, t.center)
            if d < bestDist {
                bestDist = d
                bestIdx = i
            }
        }
        guard bestDist < Self.tileSpanMeters * 0.6 else { return nil }
        return (tiles[bestIdx], bestIdx)
    }

    /// Decoded UIImage for `tile`. Cached; safe to call every frame.
    func image(for tile: RouteTile, atIndex idx: Int) -> UIImage? {
        let key = NSNumber(value: idx)
        if let cached = imageCache.object(forKey: key) {
            return cached
        }
        guard let img = UIImage(data: tile.jpeg) else { return nil }
        imageCache.setObject(img, forKey: key)
        return img
    }

    // MARK: - Anchor sampling

    /// Walk the polyline and emit anchor coordinates spaced
    /// approximately `stride` meters apart along the great-circle
    /// path. The first and last polyline vertex are always emitted
    /// so the route ends are fully covered.
    private func anchorsAlongPolyline(
        _ polyline: MKPolyline,
        stride: CLLocationDistance
    ) -> [CLLocationCoordinate2D] {
        let n = polyline.pointCount
        guard n > 0 else { return [] }
        let pts = polyline.points()
        var out: [CLLocationCoordinate2D] = [pts[0].coordinate]

        var carry: CLLocationDistance = 0
        for i in 0..<(n - 1) {
            let a = pts[i].coordinate
            let b = pts[i + 1].coordinate
            let segLen = PolylineMath.haversine(a, b)
            var consumed = -carry
            while consumed + stride <= segLen {
                consumed += stride
                let t = consumed / segLen
                let lat = a.latitude + (b.latitude - a.latitude) * t
                let lon = a.longitude + (b.longitude - a.longitude) * t
                out.append(CLLocationCoordinate2D(latitude: lat, longitude: lon))
            }
            carry = segLen - consumed
        }
        let last = pts[n - 1].coordinate
        if let tail = out.last, PolylineMath.haversine(tail, last) > stride * 0.3 {
            out.append(last)
        }
        return out
    }

    /// Produce a parallel row of anchors offset perpendicular to the
    /// main polyline by `offsetMeters`. Flat-earth approximation —
    /// fine for offsets ≤ a few km. (Unchanged from the MapKit era.)
    private func lateralAnchors(
        _ anchors: [CLLocationCoordinate2D],
        offsetMeters: CLLocationDistance
    ) -> [CLLocationCoordinate2D] {
        guard anchors.count >= 2 else { return [] }
        let avgLat = anchors.map(\.latitude).reduce(0, +) / Double(anchors.count)
        let metersPerDegLat = 111_320.0
        let metersPerDegLon = 111_320.0 * cos(avgLat * .pi / 180)
        var out: [CLLocationCoordinate2D] = []
        out.reserveCapacity(anchors.count)
        for i in 0..<anchors.count {
            let prev = anchors[max(0, i - 1)]
            let next = anchors[min(anchors.count - 1, i + 1)]
            let dxMeters = (next.longitude - prev.longitude) * metersPerDegLon
            let dyMeters = (next.latitude  - prev.latitude)  * metersPerDegLat
            let len = sqrt(dxMeters * dxMeters + dyMeters * dyMeters)
            guard len > 0.0001 else {
                out.append(anchors[i])
                continue
            }
            let nxMeters =  dyMeters / len * offsetMeters
            let nyMeters = -dxMeters / len * offsetMeters
            let dLon = nxMeters / metersPerDegLon
            let dLat = nyMeters / metersPerDegLat
            out.append(CLLocationCoordinate2D(
                latitude:  anchors[i].latitude  + dLat,
                longitude: anchors[i].longitude + dLon
            ))
        }
        return out
    }

    /// Keep `keepCount` items evenly distributed.
    private static func decimate<T>(_ array: [T], keepCount: Int) -> [T] {
        guard keepCount > 0 else { return [] }
        guard array.count > keepCount else { return array }
        var out: [T] = []
        out.reserveCapacity(keepCount)
        for i in 0..<keepCount {
            let idx = (i * (array.count - 1)) / max(1, keepCount - 1)
            out.append(array[idx])
        }
        return out
    }

    // MARK: - Composite rendering

    /// Fetch + stitch an OSM tile composite centered on `center`.
    ///
    /// Algorithm:
    ///   1. Project `center` to fractional tile coords (z, fx, fy).
    ///   2. Pick the gridSide × gridSide block of integer tiles that
    ///      brackets the center pixel-aligned (anchor block top-left
    ///      = round(fx) - gridSide/2 etc.).
    ///   3. Fetch every tile (disk cache first → HTTP fallback via
    ///      OSMTileFetcher). Missing tiles become transparent — better
    ///      than a black hole over network drop.
    ///   4. Paint into a tilePixels × tilePixels CGContext at the
    ///      offset that puts `center` at the bitmap midpoint.
    ///   5. PNG-encode and wrap in a RouteTile.
    ///
    /// Geometry is fully deterministic — no probe, no measure. The
    /// renderer in `MapViewSource` reads `pxPerDeg` and `centerPixel`
    /// from the returned tile and gets pixel-exact results.
    private static func composite(center: CLLocationCoordinate2D) async -> RouteTile? {
        let z = zoom
        let pxPerDegLon = WebMercator.pixelsPerDegreeLongitude(zoom: z)
        let pxPerDegLat = WebMercator.pixelsPerDegreeLatitude(latitude: center.latitude, zoom: z)
        let bitmapSize = Int(tilePixels)

        // Fractional tile coords for the center.
        let (fx, fy) = WebMercator.tile(for: center, zoom: z)

        // Top-left tile index of the gridSide × gridSide block.
        // We center the block on the anchor: the anchor's fractional
        // position lands somewhere inside the central tile(s).
        let half = gridSide / 2
        let tlx = Int(floor(fx)) - half
        let tly = Int(floor(fy)) - half

        // Pixel offset of the requested center inside the assembled
        // bitmap, if we drew tile (tlx, tly) at (0, 0):
        //   centerPxInBlock_x = (fx - tlx) * 256
        //   centerPxInBlock_y = (fy - tly) * 256
        // We want the center to land at the bitmap midpoint
        // (bitmapSize/2, bitmapSize/2), so the paint offset is:
        //   paintOffsetX = bitmapSize/2 - centerPxInBlock_x
        // Same for Y. Tiles drawn at (paintOffsetX + tx*256, paintOffsetY + ty*256)
        // for tx, ty in 0..<gridSide.
        let centerPxInBlockX = (fx - Double(tlx)) * Double(WebMercator.tilePixels)
        let centerPxInBlockY = (fy - Double(tly)) * Double(WebMercator.tilePixels)
        let paintOffsetX = Double(bitmapSize) / 2.0 - centerPxInBlockX
        let paintOffsetY = Double(bitmapSize) / 2.0 - centerPxInBlockY

        // Fetch all 16 (or gridSide²) tiles in parallel. Each call
        // hits TileDiskCache first then OSMTileFetcher; misses are
        // rare on a re-bake of familiar territory.
        let tilesData: [(tx: Int, ty: Int, data: Data?)] = await withTaskGroup(
            of: (Int, Int, Data?).self
        ) { group in
            for ty in 0..<gridSide {
                for tx in 0..<gridSide {
                    let absX = tlx + tx
                    let absY = tly + ty
                    group.addTask {
                        // Disk cache first — synchronous-ish via actor.
                        if let cached = await TileDiskCache.shared.read(z: z, x: absX, y: absY) {
                            return (tx, ty, cached)
                        }
                        // HTTP fallback. On error (network, 429) we
                        // return nil; the composite still draws with
                        // the missing tile area transparent — degraded
                        // UX is better than a black screen.
                        do {
                            let data = try await OSMTileFetcher.shared.fetch(z: z, x: absX, y: absY)
                            await TileDiskCache.shared.write(z: z, x: absX, y: absY, pngData: data)
                            return (tx, ty, data)
                        } catch {
                            return (tx, ty, nil)
                        }
                    }
                }
            }
            var collected: [(Int, Int, Data?)] = []
            collected.reserveCapacity(gridSide * gridSide)
            for await result in group {
                collected.append(result)
            }
            return collected
        }

        // Bail if we didn't get a single tile — composite would be
        // entirely transparent, useless to the renderer.
        guard tilesData.contains(where: { $0.data != nil }) else {
            return nil
        }

        // Assemble into one bitmap. Background light grey (matches
        // OSM Carto land color, so missing tiles blend in instead
        // of glaring as black holes).
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: bitmapSize,
            height: bitmapSize,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        // OSM Carto "land" base color (#F2EFE9). Renders nicely under
        // missing-tile gaps and matches the visible tiles' background.
        ctx.setFillColor(red: 242.0 / 255, green: 239.0 / 255, blue: 233.0 / 255, alpha: 1.0)
        ctx.fill(CGRect(x: 0, y: 0, width: bitmapSize, height: bitmapSize))

        // CGContext default coordinate system is Y-up. We want bitmap-
        // natural Y-down (tile row 0 at the TOP). Flip once for the
        // whole composite, draw normally inside.
        ctx.saveGState()
        ctx.translateBy(x: 0, y: CGFloat(bitmapSize))
        ctx.scaleBy(x: 1, y: -1)

        for entry in tilesData {
            guard let data = entry.data,
                  let imgSrc = CGImageSourceCreateWithData(data as CFData, nil),
                  let cgImg = CGImageSourceCreateImageAtIndex(imgSrc, 0, nil) else {
                continue
            }
            let x = paintOffsetX + Double(entry.tx * WebMercator.tilePixels)
            let y = paintOffsetY + Double(entry.ty * WebMercator.tilePixels)
            // Y-up coordinate system inside the saveGState — but we
            // flipped, so the visual top of the bitmap is now y=0
            // from CGContext's perspective. Draw the tile so its
            // top-left is at (x, y) in flipped coords.
            ctx.draw(
                cgImg,
                in: CGRect(
                    x: x,
                    y: y,
                    width: CGFloat(WebMercator.tilePixels),
                    height: CGFloat(WebMercator.tilePixels)
                )
            )
        }
        ctx.restoreGState()

        // Optional: stamp OSM attribution in the bottom-right corner.
        // Small, semi-transparent, doesn't compete with the route line.
        // Drawn AFTER the saveGState restore so it uses Y-up coords
        // (matches CoreText drawing convention).
        drawAttribution(into: ctx, bitmapSize: CGFloat(bitmapSize))

        guard let outImage = ctx.makeImage() else { return nil }
        // PNG encode (preserves transparency for missing-tile fallbacks;
        // OSM Carto's palette compresses well — typical composite is
        // 200-500 KB).
        let uiImage = UIImage(cgImage: outImage, scale: 1.0, orientation: .up)
        guard let png = uiImage.pngData() else { return nil }

        let region = MKCoordinateRegion(
            center: center,
            latitudinalMeters: tileSpanMeters,
            longitudinalMeters: tileSpanMeters
        )
        return RouteTile(
            center: center,
            region: region,
            jpeg: png,
            pixelSize: CGSize(width: bitmapSize, height: bitmapSize),
            // Pixel-exact: we stitched the composite so that `center`
            // lands at the bitmap midpoint. No clamp drift.
            centerPixel: CGPoint(x: Double(bitmapSize) / 2.0, y: Double(bitmapSize) / 2.0),
            pxPerDegLon: pxPerDegLon,
            pxPerDegLat: pxPerDegLat
        )
    }

    /// Draw "© OpenStreetMap" in the bottom-right of the composite.
    /// Required by OSM Tile Usage Policy: every map view must show
    /// attribution. Small, white-with-shadow so it stays legible
    /// over both light and dark terrain.
    ///
    /// We bake it into the composite (rather than overlay at render
    /// time) so it survives heading-up rotation — the rider always
    /// sees attribution somewhere on screen, just not always in the
    /// same corner. That's fine per OSM policy as long as it IS
    /// visible.
    private static func drawAttribution(into ctx: CGContext, bitmapSize: CGFloat) {
        let text = "© OpenStreetMap"
        let font = UIFont.systemFont(ofSize: 11, weight: .regular)
        let textAttrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor(white: 0.0, alpha: 0.75)
        ]
        let attr = NSAttributedString(string: text, attributes: textAttrs)
        let line = CTLineCreateWithAttributedString(attr)
        let bounds = CTLineGetImageBounds(line, ctx)
        let pad: CGFloat = 6
        let x = bitmapSize - bounds.width - pad - 4
        let y = pad + 2
        // White semi-transparent pill behind the text for legibility
        // against busy map content.
        ctx.saveGState()
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 0.7)
        let pill = CGRect(
            x: x - 4, y: y - 2,
            width: bounds.width + 8, height: bounds.height + 4
        )
        ctx.fill(pill)
        ctx.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }
}
