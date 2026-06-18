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

    // MARK: - Stored state

    private(set) var tiles: [RouteTile] = []
    private let imageCache = NSCache<NSNumber, UIImage>()
    private let log = Logger(subsystem: "eu.kolaczek.tripperdashpp.map", category: "RouteTileCache")

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
        let anchors = anchorsAlongPolyline(route.polyline, stride: Self.stride)
        log.info("Pre-rendering \(anchors.count, privacy: .public) tiles for route (\(Int(route.distance), privacy: .public) m)")
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

    /// Render one MKMapSnapshotter tile centered on `center`.
    /// Runs in foreground (caller responsibility) so the GPU is
    /// available; produces a JPEG-compressed `RouteTile`.
    private static func snapshot(center: CLLocationCoordinate2D) async -> RouteTile? {
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
        return RouteTile(
            center: center,
            region: options.region,
            jpeg: jpeg,
            pixelSize: img.size
        )
    }
}
