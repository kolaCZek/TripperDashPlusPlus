//
//  RouteTileCache.swift
//  TripperDashPP
//
//  Pre-rendered map tiles along an MKRoute, captured in foreground
//  while the GPU is still available so the BG render path never has
//  to ask MapKit to draw anything.
//
//  Design (June 2026, after the Phase 8c BG-render dead-end):
//
//    iOS 16+ blocks Metal-backed work from .background, so neither
//    `mapView.layer.render(in:)` nor `MKMapSnapshotter.start` can
//    produce real map content once the screen locks. Picture-in-
//    Picture buys us encoder + scheduler liveness, but NOT GPU
//    rendering.
//
//    The fix is to pre-bake every map tile we'll need before lock
//    screen, then composite in CGContext (CPU-only) at runtime.
//
//  Tile geometry:
//
//    * One snapshot per ~700 m along the polyline (overlap > 30 %
//      so heading rotation never reveals empty edges).
//    * 1024×1024 px @ 2× scale (effective 2048²) renders in ~150-
//      400 ms each on iPhone 15 Pro.
//    * Span: 1.2 km × 1.2 km, ~1.2 m/px → road labels still legible
//      after rotation + downsample to 526×300.
//    * 3 km lateral buffer (re-routes inside this stay on cache).
//
//  Pre-render budget:
//
//    * 35 km route → ~50 tiles → ~10-20 s wall-clock at 4-way
//      TaskGroup parallelism.
//    * Memory: 50 × 16 MB CGImage ≈ 800 MB. Too much. We compress
//      each tile to JPEG in memory (~400 KB) and decode on demand
//      via NSCache (capacity 8). Working set <10 MB.

import CoreGraphics
import CoreLocation
import Foundation
import MapKit
import OSLog
import UIKit

/// One pre-rendered map tile + the lat/lon region it covers.
struct RouteTile: Sendable {
    /// Center coordinate of the tile.
    let center: CLLocationCoordinate2D
    /// Geographic extent the tile covers (used to project pixels).
    let region: MKCoordinateRegion
    /// JPEG-compressed bytes (decoded lazily, see `RouteTileCache.image`).
    let jpeg: Data
    /// Pixel dimensions of the decoded image.
    let pixelSize: CGSize
    /// Pixel coordinates inside `jpeg` where `center` actually lands.
    /// `MKMapSnapshotter` clamps to tile boundaries so this is NOT
    /// always `pixelSize / 2`. Stored in *image-pixel* space (top-left
    /// origin, Y-down).
    let centerPixel: CGPoint
    /// MEASURED pixels-per-degree at `center`, derived from
    /// `snap.point(for:)` on offset probe coords — NOT from
    /// `pixelSize / region.span`. MKMapSnapshotter renders at the
    /// nearest tile zoom level, which often covers MORE area than
    /// the requested region; the naive pxPerDeg from request span
    /// over-estimates scale by 2-3×, making everything render
    /// "zoomed in" relative to real geography.
    let pxPerDegLon: Double
    let pxPerDegLat: Double
}

/// Container + builder for `RouteTile`s along an `MKRoute`.
@MainActor
final class RouteTileCache {

    // MARK: - Tunables

    /// Distance between successive tile centers along the polyline.
    /// Tile span is 1.2 km, so 700 m gives ~40 % overlap — enough
    /// that any rotation up to 360° still leaves the user position
    /// well inside a single tile (no seam stitching needed at run
    /// time).
    static let stride: CLLocationDistance = 700

    /// Per-tile pixel size (1× scale — multiplied by `tileScale`).
    static let tilePixels: CGFloat = 1024

    /// `MKMapSnapshotter` `.scale` value. 2× = retina, sharper text.
    static let tileScale: CGFloat = 2.0

    /// Tile geographic extent. ~1.2 m/px after 2× supersample.
    static let tileSpanMeters: CLLocationDistance = 1200

    /// Concurrent snapshotter requests. MKMapSnapshotter contends
    /// with itself for shared GPU buffers, so going wider than 4 in
    /// parallel actually slows down the batch on iPhone 15 Pro.
    static let parallelism = 4

    /// JPEG quality for the in-memory cache. 0.85 is visually
    /// indistinguishable from PNG for map tiles + ~10× smaller.
    static let jpegQuality: CGFloat = 0.85

    /// Lateral buffer distance — how far perpendicular to the route
    /// the wing anchor rows sit. 1500 m means the user can drift up
    /// to ~2 km from the centerline (lateral offset + ~half a tile
    /// span) before the cache misses and the dark fallback kicks
    /// in. Tuned so that a typical wrong-turn excursion stays
    /// covered until reroute fires (~30 s later) and rebakes.
    static let lateralOffset: CLLocationDistance = 1500

    /// Hard cap on total tiles per route so a 300 km road trip
    /// doesn't try to bake ~1000 tiles. When exceeded, the wings
    /// are decimated uniformly along the route; the main centerline
    /// is never thinned.
    static let maxTilesPerRoute: Int = 300

    // MARK: - Stored state

    private(set) var tiles: [RouteTile] = []
    private let imageCache = NSCache<NSNumber, UIImage>()
    private let log = Logger(subsystem: "eu.kolaczek.tripperdashpp", category: "RouteTileCache")

    init() {
        imageCache.countLimit = 8
    }

    // MARK: - Build

    /// Pre-render all tiles for `route`. Reports `0…1` progress on
    /// the main actor every time a tile finishes.
    ///
    /// `progress` callback fires with values strictly increasing
    /// from 0 to 1. The final call (1.0) only fires after every
    /// tile has been added to `self.tiles`.
    func prerender(
        route: MKRoute,
        progress: @MainActor @escaping (Double) -> Void
    ) async {
        tiles.removeAll(keepingCapacity: true)
        let mainAnchors = anchorsAlongPolyline(route.polyline, stride: Self.stride)
        // Lateral buffer: same anchor positions, shifted ±lateralOffset
        // meters perpendicular to the route. Gives the rider a tile-
        // backed safety zone if they deviate (wrong turn, scenic detour,
        // GPS drift) before reroute fires. Cap on total tiles prevents
        // pathological long routes from baking forever.
        let leftAnchors  = lateralAnchors(mainAnchors, offsetMeters: -Self.lateralOffset)
        let rightAnchors = lateralAnchors(mainAnchors, offsetMeters: +Self.lateralOffset)
        var anchors = mainAnchors + leftAnchors + rightAnchors
        if anchors.count > Self.maxTilesPerRoute {
            // Trim the wings first — main route is sacred. Keep all of
            // mainAnchors; uniformly decimate the lateral wings until
            // we fit. This keeps coverage even along the whole route
            // rather than dropping one tail.
            let budget = max(0, Self.maxTilesPerRoute - mainAnchors.count)
            let perWing = budget / 2
            let leftTrim  = Self.decimate(leftAnchors, keepCount: perWing)
            let rightTrim = Self.decimate(rightAnchors, keepCount: perWing)
            anchors = mainAnchors + leftTrim + rightTrim
            log.info("Anchor budget exceeded; decimated wings to \(perWing, privacy: .public) each side")
        }
        log.info("Pre-rendering \(anchors.count, privacy: .public) tiles (\(mainAnchors.count, privacy: .public) main + \(anchors.count - mainAnchors.count, privacy: .public) lateral) for route (\(Int(route.distance), privacy: .public) m)")
        progress(0)

        // Bound concurrency at `parallelism` via a simple semaphore-
        // style window. We keep tile order stable (anchor index =
        // tiles array index) so heading-up rotation never has to
        // search the whole list — we know roughly which tile to
        // hit by progress along the route.
        let total = anchors.count
        var completed = 0
        var built: [RouteTile?] = Array(repeating: nil, count: total)

        await withTaskGroup(of: (Int, RouteTile?).self) { group in
            var nextIndex = 0
            // Prime the window.
            for _ in 0..<min(Self.parallelism, total) {
                let idx = nextIndex
                nextIndex += 1
                let center = anchors[idx]
                group.addTask { @MainActor in
                    let tile = await Self.snapshot(center: center)
                    return (idx, tile)
                }
            }
            // Consume + refill.
            for await (idx, tile) in group {
                built[idx] = tile
                completed += 1
                progress(Double(completed) / Double(total))
                if nextIndex < total {
                    let i = nextIndex
                    nextIndex += 1
                    let center = anchors[i]
                    group.addTask { @MainActor in
                        let tile = await Self.snapshot(center: center)
                        return (i, tile)
                    }
                }
            }
        }

        tiles = built.compactMap { $0 }
        log.info("Pre-render done: \(self.tiles.count, privacy: .public)/\(total, privacy: .public) tiles built")
        progress(1)
    }

    // MARK: - Lookup

    /// Find the tile whose center is closest to `coord`. Returns
    /// `nil` if `coord` is more than ~1.5 km from every tile (off-
    /// route, re-routing scenario).
    func nearestTile(to coord: CLLocationCoordinate2D, hintIndex: Int? = nil) -> (RouteTile, Int)? {
        guard !tiles.isEmpty else { return nil }

        // Quick local scan around the hint (last successful lookup).
        // 99 % of frame ticks hit the same tile or a neighbour, so
        // the linear-scan worst case ~50 tiles is fine but we prefer
        // O(1) when we can.
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

        // Full scan fallback.
        var bestIdx = 0
        var bestDist = CLLocationDistance.greatestFiniteMagnitude
        for (i, t) in tiles.enumerated() {
            let d = PolylineMath.haversine(coord, t.center)
            if d < bestDist {
                bestDist = d
                bestIdx = i
            }
        }
        // Any tile center within 0.6× the tile span has the user
        // somewhere inside the tile (with margin for rotation).
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
    /// path. The first and last polyline vertex are always
    /// emitted so the route ends are fully covered.
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
            // Plant anchors every `stride` meters along [a,b].
            while consumed + stride <= segLen {
                consumed += stride
                let t = consumed / segLen
                let lat = a.latitude + (b.latitude - a.latitude) * t
                let lon = a.longitude + (b.longitude - a.longitude) * t
                out.append(CLLocationCoordinate2D(latitude: lat, longitude: lon))
            }
            carry = segLen - consumed
        }
        // Always cover the last vertex.
        let last = pts[n - 1].coordinate
        if let tail = out.last, PolylineMath.haversine(tail, last) > stride * 0.3 {
            out.append(last)
        }
        return out
    }

    // MARK: - Tile rendering

    /// Produce a parallel row of anchors offset perpendicular to the
    /// main polyline by `offsetMeters` (positive = right side in
    /// direction of travel, negative = left). Uses a flat-earth
    /// approximation — fine for offsets ≤ a few km, which is all we
    /// ever ask for. Returns the same count as the input.
    ///
    /// For each anchor we compute the local tangent from the two
    /// neighbours (or one if at an endpoint), rotate it 90° to get
    /// the right-hand normal, scale to `offsetMeters`, and add to
    /// the anchor coord. Cosine compensation handles the lat/lon →
    /// meters anisotropy.
    private func lateralAnchors(
        _ anchors: [CLLocationCoordinate2D],
        offsetMeters: CLLocationDistance
    ) -> [CLLocationCoordinate2D] {
        guard anchors.count >= 2 else { return [] }
        // Meters per degree at the route's average latitude. 111_320
        // is the equator value; cos(lat) compensates for longitude
        // converging at the poles. Latitude conversion is essentially
        // constant.
        let avgLat = anchors.map(\.latitude).reduce(0, +) / Double(anchors.count)
        let metersPerDegLat = 111_320.0
        let metersPerDegLon = 111_320.0 * cos(avgLat * .pi / 180)
        var out: [CLLocationCoordinate2D] = []
        out.reserveCapacity(anchors.count)
        for i in 0..<anchors.count {
            // Tangent: vector from previous to next neighbour (or
            // forward/backward at the ends). Operates in meters so
            // we convert via the local scale factors.
            let prev = anchors[max(0, i - 1)]
            let next = anchors[min(anchors.count - 1, i + 1)]
            let dxMeters = (next.longitude - prev.longitude) * metersPerDegLon
            let dyMeters = (next.latitude  - prev.latitude)  * metersPerDegLat
            let len = sqrt(dxMeters * dxMeters + dyMeters * dyMeters)
            guard len > 0.0001 else {
                // Degenerate (zero-length tangent — duplicate anchors).
                // Fall back to the original position; the dedupe in
                // nearestTile handles duplicates cleanly.
                out.append(anchors[i])
                continue
            }
            // Right-hand normal in meters: rotate (dx, dy) by -90°
            // → (dy, -dx). Sign of offsetMeters picks left vs right.
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

    /// Keep `keepCount` items from `array`, evenly distributed across
    /// the original positions. Used to thin the lateral wings when
    /// a very long route would otherwise blow the `maxTilesPerRoute`
    /// budget.
    private static func decimate<T>(_ array: [T], keepCount: Int) -> [T] {
        guard keepCount > 0 else { return [] }
        guard array.count > keepCount else { return array }
        var out: [T] = []
        out.reserveCapacity(keepCount)
        for i in 0..<keepCount {
            // Linear interpolation across [0, array.count) so we
            // sample uniformly along the route, not just from the
            // head.
            let idx = (i * (array.count - 1)) / max(1, keepCount - 1)
            out.append(array[idx])
        }
        return out
    }

    /// Render one MKMapSnapshotter tile centered on `center`.
    /// Runs in foreground (caller responsibility) so the GPU is
    /// available; produces a JPEG-compressed `RouteTile`.
    ///
    /// Two-level cache: tries the persistent `TileDiskCache` first;
    /// only falls through to MKMapSnapshotter on miss, and writes
    /// the freshly-baked JPEG back to disk for the next ride. Hit
    /// rate on a daily commute approaches 100% after the first
    /// bake, collapsing pre-render time from ~15 s to ~1 s.
    private static func snapshot(center: CLLocationCoordinate2D) async -> RouteTile? {
        // Try disk first. On hit, the JPEG + measured pxPerDeg geometry
        // come back as a single blob — no need to re-bake.
        if let cached = await TileDiskCache.shared.read(center: center) {
            return rehydrate(center: center, blob: cached)
        }
        let options = MKMapSnapshotter.Options()
        options.region = MKCoordinateRegion(
            center: center,
            latitudinalMeters: tileSpanMeters,
            longitudinalMeters: tileSpanMeters
        )
        options.size = CGSize(width: tilePixels, height: tilePixels)
        options.scale = tileScale
        options.mapType = .standard
        options.showsBuildings = true
        if #available(iOS 16.0, *) {
            options.preferredConfiguration = MKStandardMapConfiguration(
                elevationStyle: .flat,
                emphasisStyle: .default
            )
        }

        let snapshotter = MKMapSnapshotter(options: options)
        let snapshot: MKMapSnapshotter.Snapshot? = await withCheckedContinuation { cont in
            snapshotter.start(with: .main) { snap, _ in
                cont.resume(returning: snap)
            }
        }
        guard let snap = snapshot else { return nil }
        let img = snap.image
        guard let jpeg = img.jpegData(compressionQuality: jpegQuality) else { return nil }
        // Where does the *requested* center actually land in image pixels?
        // MKMapSnapshotter clamps the region to tile boundaries, so the
        // bitmap may end up offset by tens of pixels relative to math
        // that assumes pixelSize/2.
        let centerPt = snap.point(for: center)

        // MEASURE actual pxPerDeg by probing two offset coords.
        // MKMapSnapshotter renders at the nearest tile zoom level, which
        // may cover noticeably more (or less) area than the requested
        // region.span. Naive `pixelSize / region.span` over-estimates
        // scale by 2-3× → tile draws at wrong size and everything
        // appears offset. Measuring from `snap.point(for:)` on coords
        // that are a known number of degrees away gives ground truth.
        let probeDelta = 0.001  // ~111 m lat, ~70 m lon at 50°N
        let probeLon = CLLocationCoordinate2D(
            latitude: center.latitude,
            longitude: center.longitude + probeDelta
        )
        let probeLat = CLLocationCoordinate2D(
            latitude: center.latitude + probeDelta,
            longitude: center.longitude
        )
        let probeLonPt = snap.point(for: probeLon)
        let probeLatPt = snap.point(for: probeLat)
        // X axis: lon increases east, pixel x increases east → positive.
        let measuredPxPerDegLon = abs(Double(probeLonPt.x - centerPt.x)) / probeDelta
        // Y axis: lat increases north, pixel y increases south → flipped.
        let measuredPxPerDegLat = abs(Double(probeLatPt.y - centerPt.y)) / probeDelta

        // Persist for future bakes. We pack the four measured-geometry
        // floats into the blob header so a rehydrated tile renders at
        // the right scale without re-running MKMapSnapshotter.
        await TileDiskCache.shared.write(
            center: center,
            blob: TileBlob(
                jpeg: jpeg,
                pxPerDegLon: measuredPxPerDegLon,
                pxPerDegLat: measuredPxPerDegLat,
                centerPixel: centerPt
            )
        )

        return RouteTile(
            center: center,
            region: options.region,
            jpeg: jpeg,
            pixelSize: img.size,
            centerPixel: centerPt,
            pxPerDegLon: measuredPxPerDegLon,
            pxPerDegLat: measuredPxPerDegLat
        )
    }

    /// Build a `RouteTile` from a disk-cached blob WITHOUT going
    /// through MKMapSnapshotter. The geometry fields (centerPixel,
    /// pxPerDeg, pixelSize) are reconstructed from the blob's header
    /// + the JPEG's intrinsic size — no GPU work, just JPEG decode
    /// when the tile is actually drawn. Crucially: works in `.background`.
    private static func rehydrate(center: CLLocationCoordinate2D, blob: TileBlob) -> RouteTile? {
        // Decode the JPEG just enough to learn pixel dimensions.
        // UIImage is fine here — it lazy-decodes; we throw the
        // CGImage away immediately since downstream renders use the
        // JPEG data and decode-on-draw.
        guard let img = UIImage(data: blob.jpeg) else { return nil }
        // Reconstruct the requested region from the constants we
        // baked with (tileSpanMeters). The original `region` field
        // is consumed by callers only as informational metadata —
        // actual hit-testing uses `pxPerDeg` + `centerPixel`.
        let region = MKCoordinateRegion(
            center: center,
            latitudinalMeters: tileSpanMeters,
            longitudinalMeters: tileSpanMeters
        )
        return RouteTile(
            center: center,
            region: region,
            jpeg: blob.jpeg,
            pixelSize: img.size,
            centerPixel: blob.centerPixel,
            pxPerDegLon: blob.pxPerDegLon,
            pxPerDegLat: blob.pxPerDegLat
        )
    }
}
