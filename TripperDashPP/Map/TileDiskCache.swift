//
//  TileDiskCache.swift
//  TripperDashPP
//
//  Persistent JPEG cache for `MKMapSnapshotter` tiles. Tiles are keyed
//  by quantised lat/lon (so the same anchor on two different routes
//  hits the same cache entry) and survive across app launches.
//
//  Rationale: every reroute or new ride re-bakes ~50-200 tiles, each
//  costing 200-400 ms of GPU. For familiar territory (commute, daily
//  ride) the same anchors keep coming back — caching them on disk
//  collapses bake time from 10-30 s to under 2 s and saves the user
//  ~50 MB/day of redundant MapKit tile downloads on a cellular plan.
//
//  File format (one file per tile, extension `.tile`):
//      bytes  0..3   Float32 BE  pxPerDegLon  (measured at bake time)
//      bytes  4..7   Float32 BE  pxPerDegLat  (measured at bake time)
//      bytes  8..11  Float32 BE  centerPixelX (where the requested
//      bytes 12..15  Float32 BE  centerPixelY  center landed in JPEG)
//      bytes 16..end JPEG bytes
//
//  We persist the measured geometry because MKMapSnapshotter snaps to
//  the nearest internal tile zoom — naive `pixels / span` over-estimates
//  scale by 2-3×, so without these four floats rehydration would render
//  the cached tile at the wrong size and centerPixel would be wrong.
//
//  Layout:
//      Caches/RouteTiles/
//          <zoomBucket>/<latQ>_<lonQ>.tile
//          ...
//
//  Lat/lon are quantised to 4 decimal places (~11 m precision at the
//  equator). The cache key matches if and only if the requested center
//  lands within ±11 m of a previously-baked anchor — same anchor stride
//  on the same route reliably hits, but a freshly-picked random POI
//  doesn't accidentally collide.
//
//  Eviction: lightweight age-based purge on app startup. Tiles older
//  than `maxAgeDays` (default 30) are deleted; we also enforce a soft
//  total-size cap (`maxBytesOnDisk`) by deleting LRU entries until
//  back under cap. Both run off-main and only at startup, so the hot
//  read/write path stays fast.
//

import CoreGraphics
import CoreLocation
import Foundation
import OSLog

/// Decoded tile blob — what `read` returns and `write` accepts.
struct TileBlob: Sendable {
    let jpeg: Data
    let pxPerDegLon: Double
    let pxPerDegLat: Double
    let centerPixel: CGPoint
}

/// Thread-safe persistent JPEG cache for prerendered map tiles.
///
/// Use the shared singleton (`TileDiskCache.shared`) — it owns the
/// cache directory, the size cap, and the background eviction queue.
/// `RouteTileCache.snapshot(center:)` calls `read` before triggering
/// MKMapSnapshotter and `write` after a successful render.
actor TileDiskCache {

    static let shared = TileDiskCache()

    private let log = Logger(subsystem: "cz.kolaczek.TripperDashPP", category: "TileDiskCache")

    /// Round lat/lon to this many decimals when building the cache key.
    /// 4 decimals ≈ 11 m precision at the equator, which is much
    /// finer than the 700 m stride between anchors — so two bakes
    /// of the "same" anchor reliably hit the same key, but a
    /// genuinely different anchor never collides.
    private let coordPrecision: Int = 4

    /// Zoom bucket — only one for now (we always bake at the same
    /// `tileSpanMeters`). Keyed as a directory level so a future
    /// multi-zoom cache can coexist without nuking the old data.
    private let zoomBucket: String = "1200m_v2"

    /// Tiles older than this are evicted at startup.
    private let maxAgeDays: TimeInterval = 30

    /// Soft cap on total cache size. When exceeded, oldest-mtime
    /// files are deleted until back under cap. Tuned for a typical
    /// motorcyclist's cache: 30 km commute ~ 50 tiles ~ 5 MB; 200 MB
    /// holds ~40 distinct rides of that size.
    private let maxBytesOnDisk: Int = 200 * 1024 * 1024

    /// Lazy-resolved cache directory. `Caches` is the right base —
    /// the OS may evict it under memory pressure (which we're fine
    /// with — we'll just re-bake), but it's not iCloud-backed and
    /// it doesn't count against the user's app data quota.
    private lazy var baseDir: URL = {
        let fm = FileManager.default
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = caches.appendingPathComponent("RouteTiles", isDirectory: true)
            .appendingPathComponent(zoomBucket, isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Build a cache filename for a tile centered at `center`.
    /// Lat first so directory listings are roughly geographic-sorted.
    private nonisolated func filename(for center: CLLocationCoordinate2D) -> String {
        let lat = round(center.latitude  * pow(10.0, Double(4))) / pow(10.0, Double(4))
        let lon = round(center.longitude * pow(10.0, Double(4))) / pow(10.0, Double(4))
        // Use a `_` separator (filesystem-safe, never appears in a number).
        // `%+010.4f` pads to a fixed width so lexical sort matches numeric sort.
        return String(format: "%+010.4f_%+010.4f.tile", lat, lon)
    }

    /// Look up a cached tile. Returns the parsed blob if found and the
    /// file is readable and the header sane, else nil. Touches the
    /// file's mtime so the LRU eviction prefers truly stale entries.
    func read(center: CLLocationCoordinate2D) -> TileBlob? {
        let url = baseDir.appendingPathComponent(filename(for: center))
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              data.count > 16 else {
            return nil
        }
        // Header: 4× Float32 big-endian, then JPEG.
        let header = data.prefix(16)
        let jpeg   = data.suffix(from: 16)
        let pxLon = Double(Self.readFloat32BE(header, offset: 0))
        let pxLat = Double(Self.readFloat32BE(header, offset: 4))
        let cx    = CGFloat(Self.readFloat32BE(header, offset: 8))
        let cy    = CGFloat(Self.readFloat32BE(header, offset: 12))
        // Sanity gate: a broken / partially-written file would have
        // garbage floats. Real pxPerDeg ranges 1e3..1e6; centerPixel
        // is inside [0, 4096]. Anything else → ignore + delete.
        guard pxLon > 100, pxLon < 1e7,
              pxLat > 100, pxLat < 1e7,
              cx >= 0, cx < 8192,
              cy >= 0, cy < 8192 else {
            log.warning("Disk cache file has bad header, deleting: \(url.lastPathComponent, privacy: .public)")
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        // Bump mtime to mark "recently used". Best-effort; we don't
        // care if the touch fails (eviction will still happen,
        // just slightly less LRU-correct).
        let now = Date()
        try? FileManager.default.setAttributes(
            [.modificationDate: now],
            ofItemAtPath: url.path
        )
        log.debug("Disk cache HIT: \(url.lastPathComponent, privacy: .public) (\(data.count, privacy: .public) B)")
        return TileBlob(
            jpeg: Data(jpeg),
            pxPerDegLon: pxLon,
            pxPerDegLat: pxLat,
            centerPixel: CGPoint(x: cx, y: cy)
        )
    }

    /// Persist `blob` for a tile centered at `center`. Atomic write
    /// (tmp + rename) so a crash mid-write can't leave a partial
    /// file the next launch tries to decode.
    func write(center: CLLocationCoordinate2D, blob: TileBlob) {
        let url = baseDir.appendingPathComponent(filename(for: center))
        var packed = Data(capacity: 16 + blob.jpeg.count)
        packed.append(Self.float32BE(Float(blob.pxPerDegLon)))
        packed.append(Self.float32BE(Float(blob.pxPerDegLat)))
        packed.append(Self.float32BE(Float(blob.centerPixel.x)))
        packed.append(Self.float32BE(Float(blob.centerPixel.y)))
        packed.append(blob.jpeg)
        do {
            try packed.write(to: url, options: .atomic)
            log.debug("Disk cache WRITE: \(url.lastPathComponent, privacy: .public) (\(packed.count, privacy: .public) B)")
        } catch {
            log.warning("Disk cache write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Returns (count, bytes) — used by the Settings cell so we can
    /// show "84 tiles • 7.2 MB" without two separate walks. Walks
    /// the entire `RouteTiles/` subtree (every zoom bucket, including
    /// stale ones from previous app versions) so the user sees true
    /// disk usage.
    func stats() -> (count: Int, bytes: Int) {
        let fm = FileManager.default
        let root = baseDir.deletingLastPathComponent()
        guard let it = fm.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey]) else {
            return (0, 0)
        }
        var count = 0
        var total = 0
        for case let url as URL in it where url.pathExtension == "tile" || url.pathExtension == "jpg" {
            count += 1
            total += (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        }
        return (count, total)
    }

    /// Nuke the entire disk cache. Called from Settings → "Clear map
    /// cache" button. Recreates the empty directory so subsequent
    /// writes don't have to re-create it under the hood.
    func clear() {
        let fm = FileManager.default
        // We delete the whole RouteTiles directory (parent of
        // baseDir's zoom bucket) so a future multi-zoom rollout can
        // wipe all buckets in one go.
        let parent = baseDir.deletingLastPathComponent()
        do {
            try fm.removeItem(at: parent)
            try fm.createDirectory(at: baseDir, withIntermediateDirectories: true)
            log.info("Disk cache CLEARED")
        } catch {
            log.warning("Disk cache clear failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Eviction sweep: delete every file older than `maxAgeDays`,
    /// then if we're still over `maxBytesOnDisk` delete oldest-mtime
    /// files until back under. Designed to be called once per app
    /// launch from a Task — single-shot, cheap, and the actor
    /// serialisation prevents it racing with reads/writes.
    func evictIfNeeded() {
        let fm = FileManager.default
        guard let it = fm.enumerator(at: baseDir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else {
            return
        }
        struct Entry {
            let url: URL
            let size: Int
            let mtime: Date
        }
        var entries: [Entry] = []
        let now = Date()
        let ageCutoff = now.addingTimeInterval(-maxAgeDays * 86400)
        var ageEvicted = 0
        for case let url as URL in it where url.pathExtension == "tile" {
            let vals = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let mtime = vals?.contentModificationDate ?? now
            let size  = vals?.fileSize ?? 0
            if mtime < ageCutoff {
                try? fm.removeItem(at: url)
                ageEvicted += 1
                continue
            }
            entries.append(Entry(url: url, size: size, mtime: mtime))
        }
        // Size-based LRU pass on the survivors.
        var totalBytes = entries.reduce(0) { $0 + $1.size }
        if totalBytes > maxBytesOnDisk {
            entries.sort { $0.mtime < $1.mtime }   // oldest first
            var sizeEvicted = 0
            for e in entries {
                if totalBytes <= maxBytesOnDisk { break }
                try? fm.removeItem(at: e.url)
                totalBytes -= e.size
                sizeEvicted += 1
            }
            log.info("Eviction: age=\(ageEvicted, privacy: .public), size=\(sizeEvicted, privacy: .public); remaining=\(totalBytes / 1024, privacy: .public) KiB")
        } else if ageEvicted > 0 {
            log.info("Eviction: age=\(ageEvicted, privacy: .public); under size cap")
        }
    }

    // MARK: - Float32 BE helpers

    private nonisolated static func float32BE(_ v: Float) -> Data {
        var be = v.bitPattern.bigEndian
        return Data(bytes: &be, count: 4)
    }

    private nonisolated static func readFloat32BE(_ data: Data, offset: Int) -> Float {
        var word: UInt32 = 0
        for i in 0..<4 {
            word = (word << 8) | UInt32(data[data.startIndex + offset + i])
        }
        return Float(bitPattern: word)
    }
}
