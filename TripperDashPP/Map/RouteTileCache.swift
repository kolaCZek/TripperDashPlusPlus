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

    // MARK: - Debug
    /// Dump first N composites to Documents/ for visual orientation
    /// check (see DEBUG block in bake-composite path). Decrements
    /// each dump. Set to 0 to disable.
    #if DEBUG
    static var debugDumpsRemaining = 3
    static var debugDumpIndex = 0
    #endif

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

    /// Hard cap on total composites per route. Anchors are still
    /// computed beyond this number, but bake batches will only ever
    /// process up to this many distinct indices — used as a sanity
    /// brake for routes that produce truly absurd anchor counts
    /// (10000+ km loops). For the rolling-window architecture this
    /// is rarely hit in practice; `prerender`'s fast-start window
    /// stays well under the cap on every reasonable route.
    static let maxTilesPerRoute: Int = 300

    // MARK: - Rolling-window tunables

    /// How far ahead of the route start the initial `prerender` call
    /// bakes tiles. Picked so `prerender` finishes in ~3-5 s on 4G
    /// from cold (no disk hits): 8 km / 700 m stride = ~12 main +
    /// 24 wings = ~36 composites × 16 tiles = ~500 max tile fetches
    /// (heavily dedup'd by overlap → typically ~200 unique tiles).
    static let initialBakeAheadMeters: CLLocationDistance = 8000

    /// How far ahead of the current rider position the rolling
    /// extender keeps the cache warm. 5 km is comfortable margin:
    /// at 130 km/h (highway top of guerrilla) that's ~2.3 minutes
    /// of buffer, far longer than any conceivable bake latency
    /// even on dodgy mobile data.
    static let rollingLookaheadMeters: CLLocationDistance = 5000

    /// How far BEHIND the rider position we keep extending. Small
    /// margin so a temporary stop or u-turn doesn't immediately
    /// drop the trailing tile, which would look bad to the rider
    /// (renderer would fall back to dark territory directly behind
    /// them). We don't actively evict — this just protects against
    /// a future eviction policy.
    static let rollingTrailMeters: CLLocationDistance = 500

    // MARK: - Stored state

    // MARK: - Rolling-window state
    //
    // Rolling-window architecture (mid-2026):
    //
    //   The old `prerender` paid the full bake cost upfront — for a
    //   300 km road trip that meant fetching ~600 tiles and waiting
    //   30 s before the rider could press "Go". Worse, if you decided
    //   to ride 10 km then turn back home, you'd have wasted ~80 % of
    //   that bake on tiles you'd never see.
    //
    //   The new architecture:
    //     1. Compute *all* anchors upfront (main + wings). Cheap —
    //        just lat/lon arithmetic, no I/O.
    //     2. Bake only an initial **fast-start window** near the route
    //        start: ~8 km of main anchors with their wing tiles.
    //        Typical: 12 main + 24 wing = ~36 composites = ~3-5 s
    //        on 4G, well under the rider's tolerance for "tap → go".
    //     3. Expose `extend(near:)`. The navigator hooks this into
    //        every GPS fix (throttled in the caller — we don't enforce
    //        that here). It bakes any not-yet-baked anchors that fall
    //        within the lookahead window of the rider's current
    //        position. Wings are baked along with their main anchor.
    //     4. `nearestTile(to:)` only returns baked tiles. Unbaked
    //        anchors are invisible to the renderer — the dark
    //        fallback you already see for off-route territory just
    //        extends to "ahead of the rolling window".
    //
    //   Net effect: instant nav start, scale-free behaviour for any
    //   route length, and rebuilds (reroute mid-trip) are also fast
    //   because `extend()` is idempotent and disk cache survives
    //   the cache instance going away.

    /// One anchor in the routeAnchors array. Identifies position
    /// along the polyline + which lateral row (0=main, -1=left wing,
    /// +1=right wing, …). Indexing is dense: anchor i+1 always
    /// neighbours anchor i in the geometry, so we can walk the array
    /// in index space and stay close in real space.
    private struct Anchor: Sendable {
        let coord: CLLocationCoordinate2D
        /// Distance from the polyline START along the route (meters).
        /// Used to pick the "front edge" of the rolling window quickly.
        let routeOffsetMeters: CLLocationDistance
        /// 0 = main anchor on the polyline, ±1 / ±2 = lateral wing
        /// offsets. Kept around for diagnostics only — bake order
        /// treats main and wings equally.
        let lateralRow: Int
    }

    /// Built tiles only — `nearestTile` walks this. Sparse w.r.t.
    /// `allAnchors` (only baked-so-far entries appear).
    private(set) var tiles: [RouteTile] = []
    /// Parallel-indexed array of `Anchor.lateralRow` for each entry of
    /// `tiles[]`. 0 = main row (on-route), ±1 = lateral wing. Used by
    /// `nearestTile(to:hintIndex:)` to prefer main-row tiles even when
    /// a wing tile is geometrically closer.
    private(set) var tileRowKind: [Int] = []

    /// All anchors for the current route. `allAnchors[i]` is unbaked
    /// unless `bakedIndices.contains(i)`. Used as the source of truth
    /// for `extend()` — we never re-derive anchors per fix, that'd
    /// be wasteful.
    private var allAnchors: [Anchor] = []

    /// Which indices into `allAnchors` have a successfully baked tile.
    /// `bakedTileByIndex[idx]` gives the actual `RouteTile`.
    private var bakedTileByIndex: [Int: RouteTile] = [:]

    /// Indices currently being baked. Prevents `extend()` from
    /// re-issuing fetches for tiles already in flight when two GPS
    /// fixes arrive close together.
    private var inFlight: Set<Int> = []

    /// Distance (along route) of the latest GPS fix snapped to the
    /// closest main anchor. We extend `[snapped, snapped + lookahead]`
    /// and the lateral wings of every main in that range.
    private var lastRiderRouteOffset: CLLocationDistance = 0

    private let imageCache = NSCache<NSNumber, UIImage>()
    private let log = Logger(subsystem: "eu.kolaczek.tripperdashpp", category: "RouteTileCache")

    init() {
        imageCache.countLimit = 8
    }

    // MARK: - Build

    /// Pre-fetch the **fast-start** window for `route` — enough tiles
    /// to start moving immediately, without waiting for a full-route
    /// bake. Subsequent `extend(near:)` calls top up the cache as
    /// the rider progresses.
    ///
    /// `progress` callback fires `0…1` over the fast-start window
    /// only. Once it reaches 1.0, the rider can press Go even though
    /// most of the route still has no tiles. The rolling extender
    /// keeps the buffer ahead of the rider from then on.
    func prerender(
        route: MKRoute,
        progress: @MainActor @escaping (Double) -> Void
    ) async {
        // Reset all rolling state for the new route.
        tiles.removeAll(keepingCapacity: true)
        tileRowKind.removeAll(keepingCapacity: true)
        bakedTileByIndex.removeAll(keepingCapacity: true)
        inFlight.removeAll(keepingCapacity: true)
        allAnchors = computeAllAnchors(for: route)
        lastRiderRouteOffset = 0
        log.info("Route has \(self.allAnchors.count, privacy: .public) total anchors (main + wings); fast-start window = \(Self.initialBakeAheadMeters, privacy: .public) m")
        progress(0)

        // Fast start: bake every anchor (main + wings) whose
        // routeOffset falls within [0, initialBakeAheadMeters].
        let initialIndices = anchorIndices(
            withinOffsetRange: 0...Self.initialBakeAheadMeters
        )
        await bakeAnchors(at: initialIndices, progress: progress)
        progress(1)
    }

    /// Top up the cache to cover `near` + `lookaheadMeters` along the
    /// route. Idempotent — anchors already baked or in flight are
    /// skipped. Safe to call from every GPS fix (the caller should
    /// throttle to ~1 Hz to avoid logspam).
    ///
    /// No progress callback: this is background work, the rider
    /// is already navigating and the progress sheet is gone.
    func extend(
        near coord: CLLocationCoordinate2D,
        lookaheadMeters: CLLocationDistance = RouteTileCache.rollingLookaheadMeters
    ) async {
        guard !allAnchors.isEmpty else { return }

        // Snap the rider position to the closest **main** anchor and
        // use its routeOffset as the window's center-back edge. Main
        // anchors are the ones on the actual polyline; wings would
        // give a misleading offset for someone briefly drifting.
        let snappedOffset = snapToMainAnchor(coord: coord) ?? lastRiderRouteOffset
        lastRiderRouteOffset = snappedOffset

        let frontEdge = snappedOffset + lookaheadMeters
        // Also keep a small backwards margin so a rider who briefly
        // stops or reverses doesn't see the trailing tiles get pruned
        // (we don't prune at all yet, but the principle stays valid).
        let backEdge = max(0, snappedOffset - Self.rollingTrailMeters)

        let candidateIndices = anchorIndices(withinOffsetRange: backEdge...frontEdge)
        let missing = candidateIndices.filter {
            bakedTileByIndex[$0] == nil && !inFlight.contains($0)
        }
        guard !missing.isEmpty else { return }
        log.debug("extend: rider @ \(Int(snappedOffset), privacy: .public) m, baking \(missing.count, privacy: .public) new anchors (window \(Int(backEdge), privacy: .public)…\(Int(frontEdge), privacy: .public) m)")
        await bakeAnchors(at: missing, progress: nil)
    }

    // MARK: - Bake helpers

    /// Bake `indices` into `allAnchors`, updating `tiles` /
    /// `bakedTileByIndex` as each completes. `progress` is fed with
    /// `0…1` of THIS batch when non-nil (used by `prerender` for
    /// the fast-start sheet; left nil by `extend`).
    private func bakeAnchors(
        at indices: [Int],
        progress: (@MainActor (Double) -> Void)?
    ) async {
        guard !indices.isEmpty else {
            progress?(1)
            return
        }
        // Mark in-flight before we await so a concurrent extend()
        // call doesn't double up.
        for i in indices { inFlight.insert(i) }
        let total = indices.count
        var completed = 0

        await withTaskGroup(of: (Int, RouteTile?).self) { group in
            var nextSlot = 0
            // Prime the pool.
            for _ in 0..<min(Self.parallelism, total) {
                let i = indices[nextSlot]
                nextSlot += 1
                let center = allAnchors[i].coord
                group.addTask { @MainActor in
                    let tile = await Self.composite(center: center)
                    return (i, tile)
                }
            }
            for await (idx, tile) in group {
                inFlight.remove(idx)
                if let tile = tile {
                    bakedTileByIndex[idx] = tile
                }
                completed += 1
                progress?(Double(completed) / Double(total))
                if nextSlot < total {
                    let i = indices[nextSlot]
                    nextSlot += 1
                    let center = allAnchors[i].coord
                    group.addTask { @MainActor in
                        let tile = await Self.composite(center: center)
                        return (i, tile)
                    }
                }
            }
        }
        // Rebuild `tiles` in route order from the baked set. We do this
        // once per batch (not per tile) because `nearestTile(hintIndex:)`
        // assumes `tiles[i+1]` is geometrically near `tiles[i]` — sparse
        // / append-order arrays would silently break the heading-up
        // composite path. Rebuilding is cheap (~100 entries, O(n)).
        //
        // Ordering: primary key = routeOffsetMeters, secondary =
        // lateralRow. That groups every position into a (main,
        // left, right) triplet block ordered along the route, which
        // gives `nearestTile`'s `idx ± 2` neighbourhood good
        // geometric locality.
        //
        // SIDE EFFECT: this reorders `tiles`, so any cached
        // `lastTileHintIndex` over in `MapViewSource` is stale after
        // a batch finishes. `nearestTile(hintIndex:)` falls back to
        // a full scan when the hint doesn't land within tileSpan/2,
        // so correctness is preserved — the cost is one extra full
        // scan per batch, well under one frame.
        let sortedIdxs = bakedTileByIndex.keys.sorted { a, b in
            let aa = allAnchors[a]
            let bb = allAnchors[b]
            if aa.routeOffsetMeters != bb.routeOffsetMeters {
                return aa.routeOffsetMeters < bb.routeOffsetMeters
            }
            return aa.lateralRow < bb.lateralRow
        }
        tiles = sortedIdxs.map { bakedTileByIndex[$0]! }
        tileRowKind = sortedIdxs.map { allAnchors[$0].lateralRow }
        // Reorder invalidates the (idx → UIImage) memo. Without this
        // the renderer's `image(for:atIndex:)` would return a *stale*
        // image for a freshly-shuffled index — i.e. the picture for
        // some other anchor entirely — which paints the right pixels
        // at the wrong geographic position. Visible symptom: composite
        // looks like a different place than where the rider is.
        imageCache.removeAllObjects()
        log.info("Baked batch: \(completed, privacy: .public) anchors, total tiles now = \(self.tiles.count, privacy: .public)/\(self.allAnchors.count, privacy: .public)")
    }

    /// Build the full anchor list for `route` — every main anchor
    /// along the polyline + every lateral wing anchor — without
    /// baking anything. Pure arithmetic, runs in microseconds.
    private func computeAllAnchors(for route: MKRoute) -> [Anchor] {
        guard route.polyline.pointCount > 0 else { return [] }
        let mainCoords = anchorsAlongPolyline(route.polyline, stride: Self.stride)
        // Tag each main anchor with its routeOffset (distance along
        // the polyline from start). We need this to define the
        // rolling window — Euclidean distance to the rider doesn't
        // know which direction is "ahead".
        var mainOffsets: [CLLocationDistance] = []
        mainOffsets.reserveCapacity(mainCoords.count)
        var prev: CLLocationCoordinate2D? = nil
        var acc: CLLocationDistance = 0
        for c in mainCoords {
            if let p = prev {
                acc += PolylineMath.haversine(p, c)
            }
            mainOffsets.append(acc)
            prev = c
        }
        // Build wing rows with the same offsets as their main counterparts.
        let leftCoords = lateralAnchors(mainCoords, offsetMeters: -Self.lateralOffset)
        let rightCoords = lateralAnchors(mainCoords, offsetMeters: +Self.lateralOffset)
        var out: [Anchor] = []
        out.reserveCapacity(mainCoords.count * 3)
        for (i, c) in mainCoords.enumerated() {
            out.append(Anchor(coord: c, routeOffsetMeters: mainOffsets[i], lateralRow: 0))
        }
        for (i, c) in leftCoords.enumerated() {
            out.append(Anchor(coord: c, routeOffsetMeters: mainOffsets[i], lateralRow: -1))
        }
        for (i, c) in rightCoords.enumerated() {
            out.append(Anchor(coord: c, routeOffsetMeters: mainOffsets[i], lateralRow: +1))
        }
        return out
    }

    /// Filter `allAnchors` to those whose `routeOffsetMeters` falls
    /// within `range`. Used by both `prerender` (initial window) and
    /// `extend` (rolling window).
    private func anchorIndices(
        withinOffsetRange range: ClosedRange<CLLocationDistance>
    ) -> [Int] {
        var out: [Int] = []
        for (i, a) in allAnchors.enumerated() where range.contains(a.routeOffsetMeters) {
            out.append(i)
        }
        return out
    }

    /// Find the main-row anchor closest to `coord` and return its
    /// `routeOffsetMeters`. Used to snap the rider position to a
    /// well-defined "distance along route" value.
    ///
    /// Returns nil if the rider is implausibly far from every main
    /// anchor (>3 km, off-route plus lateral buffer) — `extend()`
    /// will then fall back to the last known offset.
    private func snapToMainAnchor(coord: CLLocationCoordinate2D) -> CLLocationDistance? {
        var bestOffset: CLLocationDistance = 0
        var bestDist = CLLocationDistance.greatestFiniteMagnitude
        for a in allAnchors where a.lateralRow == 0 {
            let d = PolylineMath.haversine(coord, a.coord)
            if d < bestDist {
                bestDist = d
                bestOffset = a.routeOffsetMeters
            }
        }
        return bestDist < 3000 ? bestOffset : nil
    }

    // MARK: - Lookup

    /// Find the composite whose center is closest to `coord`. Returns
    /// `nil` if `coord` is more than ~half a composite span from
    /// every anchor (off-route, re-routing scenario).
    ///
    /// **Main-row preference**: a wing tile is centred 1.5 km lateral
    /// to the route. If the rider is on the route, both a main tile
    /// (~350 m away in route direction) and a wing tile (~1.5 km
    /// lateral) qualify under the 700 m hint guardrail — but only the
    /// main tile is visually correct (the wing tile's geographic centre
    /// sits 1.5 km off-route, so the rider would appear in the bitmap
    /// 1.5 km off the polyline). Bias the search toward main-row.
    func nearestTile(to coord: CLLocationCoordinate2D, hintIndex: Int? = nil) -> (RouteTile, Int)? {
        guard !tiles.isEmpty else { return nil }

        // Identify which tiles are main-row (lateralRow == 0). We
        // cached this at bake-time in `tileRowKind`.
        func isMain(_ i: Int) -> Bool {
            return tileRowKind[i] == 0
        }

        if let hint = hintIndex {
            let lo = max(0, hint - 4)
            let hi = min(tiles.count - 1, hint + 4)
            // First pass: main-row only.
            var bestMain = -1
            var bestMainDist = CLLocationDistance.greatestFiniteMagnitude
            for i in lo...hi where isMain(i) {
                let d = PolylineMath.haversine(coord, tiles[i].center)
                if d < bestMainDist {
                    bestMainDist = d
                    bestMain = i
                }
            }
            // If a main-row tile is "close enough" (within stride),
            // prefer it over any wing tile in the window.
            if bestMain >= 0 && bestMainDist < 700 {
                return (tiles[bestMain], bestMain)
            }
            // Otherwise fall back to ANY tile (main or wing) within window.
            var best = lo
            var bestDist = PolylineMath.haversine(coord, tiles[lo].center)
            for i in (lo + 1)...hi {
                let d = PolylineMath.haversine(coord, tiles[i].center)
                if d < bestDist {
                    bestDist = d
                    best = i
                }
            }
            if bestDist < 700 {
                return (tiles[best], best)
            }
        }

        // Full-scan fallback: also bias toward main-row.
        var bestMainIdx = -1
        var bestMainDist = CLLocationDistance.greatestFiniteMagnitude
        for (i, t) in tiles.enumerated() where isMain(i) {
            let d = PolylineMath.haversine(coord, t.center)
            if d < bestMainDist {
                bestMainDist = d
                bestMainIdx = i
            }
        }
        if bestMainIdx >= 0 && bestMainDist < 1500 {
            return (tiles[bestMainIdx], bestMainIdx)
        }
        // Final fallback: any tile within the wider 2.5 km guardrail.
        var bestIdx = 0
        var bestDist = CLLocationDistance.greatestFiniteMagnitude
        for (i, t) in tiles.enumerated() {
            let d = PolylineMath.haversine(coord, t.center)
            if d < bestDist {
                bestDist = d
                bestIdx = i
            }
        }
        guard bestDist < 2500 else { return nil }
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
    ///
    /// Currently unused after the rolling-window refactor (the old
    /// `prerender` decimated wings when total anchors > maxTilesPerRoute).
    /// Left in place because the unit test in
    /// `tests/test_lateral_buffer.py` still cross-checks the Swift
    /// behaviour against a Python port — and because a future
    /// eviction policy might want it.
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

        // ── DEBUG: dump first composite to disk for orientation check ──
        // Marks bitmap centre (= tile.center geographically), 64 px N
        // (should be NORTH geographically), and 64 px S (should be SOUTH).
        // If compose is upside-down, N marker will appear at bottom of
        // saved PNG and S marker at top.
        // Open the file from the Files app under "On My iPhone > TripperDashPP".
        #if DEBUG
        if RouteTileCache.debugDumpsRemaining > 0 {
            RouteTileCache.debugDumpsRemaining -= 1
            RouteTileCache.debugDumpIndex += 1
            let dumpIdx = RouteTileCache.debugDumpIndex
            let debugCtx = CGContext(
                data: nil,
                width: bitmapSize,
                height: bitmapSize,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: cs,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
            if let debugCtx {
                debugCtx.draw(outImage, in: CGRect(x: 0, y: 0,
                    width: bitmapSize, height: bitmapSize))
                // Bitmap coords are Y-down (default CGContext post-draw).
                let mid = CGFloat(bitmapSize) / 2.0
                // Centre marker (green): tile.center
                debugCtx.setFillColor(red: 0, green: 1, blue: 0, alpha: 1)
                debugCtx.fillEllipse(in: CGRect(x: mid - 6, y: mid - 6,
                    width: 12, height: 12))
                // North marker (red): 64 px above centre in Y-down = lower y
                debugCtx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
                debugCtx.fillEllipse(in: CGRect(x: mid - 6, y: mid - 64 - 6,
                    width: 12, height: 12))
                // South marker (blue): 64 px below centre = higher y
                debugCtx.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
                debugCtx.fillEllipse(in: CGRect(x: mid - 6, y: mid + 64 - 6,
                    width: 12, height: 12))
                if let debugImg = debugCtx.makeImage() {
                    let debugUI = UIImage(cgImage: debugImg, scale: 1, orientation: .up)
                    if let debugPng = debugUI.pngData() {
                        let docs = FileManager.default.urls(
                            for: .documentDirectory, in: .userDomainMask)[0]
                        let url = docs.appendingPathComponent(
                            "compose_debug_\(dumpIdx).png")
                        try? debugPng.write(to: url)
                        NSLog("[compose-debug] wrote \(url.path)")
                    }
                }
            }
        }
        #endif

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
