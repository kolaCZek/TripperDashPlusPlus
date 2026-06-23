//
//  TileDiskCache.swift
//  TripperDashPP
//
//  Persistent PNG cache for OSM Web Mercator tiles. Tiles are keyed
//  by their canonical (z, x, y) slippy-map address, which gives us
//  three nice properties:
//
//    1. **Deterministic** — same coord → same key, every time. No
//       quantisation, no measured geometry header. The address IS
//       the geometry: WebMercator.coordinate(forTile:y:zoom:) tells
//       you exactly where each tile sits.
//
//    2. **Provider-neutral** — same disk format works whether tiles
//       came from tile.openstreetmap.org, OpenTopoMap, or a future
//       tiles.kolaczek.cz self-host. Switching providers doesn't
//       invalidate the cache (it just becomes "wrong style" until
//       OSM-ToS dictates re-fetch, see `clear()`).
//
//    3. **Browseable** — `Caches/RouteTiles/15/8800/5512.png` is a
//       real PNG you can open in Preview. Debugging is delightful.
//
//  Layout:
//      Caches/RouteTiles/<z>/<x>/<y>.png
//
//  Eviction: lightweight age-based purge on app startup. Tiles older
//  than `maxAgeDays` (default 30 — matches OSM tile cache header
//  recommendations) are deleted; we also enforce a soft total-size
//  cap (`maxBytesOnDisk`) by deleting LRU entries until back under
//  cap. Both run off-main and only at startup, so the hot read/write
//  path stays fast.
//

import CoreLocation
import Foundation
import OSLog

/// Thread-safe persistent PNG cache for OSM raster tiles.
///
/// Use the shared singleton (`TileDiskCache.shared`) — it owns the
/// cache directory, the size cap, and the background eviction queue.
/// `RouteTileCache` calls `read` before triggering an `OSMTileFetcher`
/// request and `write` after a successful HTTP fetch.
actor TileDiskCache {

    static let shared = TileDiskCache()

    private let log = Logger(subsystem: "cz.kolaczek.TripperDashPP", category: "TileDiskCache")

    /// Tiles older than this are evicted at startup. 30 days matches
    /// OSM's "Expires" header default; longer would technically violate
    /// the tile usage policy.
    private let maxAgeDays: TimeInterval = 30

    /// Soft cap on total cache size. When exceeded, oldest-mtime
    /// files are deleted until back under cap. Tuned for a typical
    /// motorcyclist's cache: 30 km commute ~ 50 tiles + lateral wings
    /// ≈ 150 tiles ≈ 4-6 MB; 200 MB holds ~40-60 distinct rides of
    /// that size.
    private let maxBytesOnDisk: Int = 200 * 1024 * 1024

    /// Cache directory. `Caches` is the right base — the OS may evict
    /// it under memory pressure (which we're fine with — we'll just
    /// re-fetch from OSM), but it's not iCloud-backed and doesn't
    /// count against the user's app data quota.
    private lazy var baseDir: URL = {
        let fm = FileManager.default
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = caches.appendingPathComponent("RouteTiles", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Build the on-disk URL for tile (z, x, y) in `style`. The style's
    /// `cacheNamespace` is the FIRST path component — this is the
    /// load-bearing isolation: light and dark share the same (z, x, y)
    /// slippy address, so without the namespace split a dark tile would
    /// overwrite the light PNG at the same coordinate (last write wins)
    /// and the reader would get the wrong palette. Per-zoom + per-x
    /// subdirectories keep the per-directory file count sane.
    private nonisolated func url(style: MapStyle, z: Int, x: Int, y: Int, in baseDir: URL) -> URL {
        return baseDir
            .appendingPathComponent(style.cacheNamespace, isDirectory: true)
            .appendingPathComponent("\(z)", isDirectory: true)
            .appendingPathComponent("\(x)", isDirectory: true)
            .appendingPathComponent("\(y).png", isDirectory: false)
    }

    /// Look up a cached tile in `style`. Returns the raw PNG data if found
    /// and the file is readable, else nil. Touches the file's mtime so
    /// LRU eviction prefers truly stale entries.
    func read(style: MapStyle, z: Int, x: Int, y: Int) -> Data? {
        let url = url(style: style, z: z, x: x, y: y, in: baseDir)
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              !data.isEmpty else {
            return nil
        }
        // Bump mtime to mark "recently used". Best-effort.
        try? FileManager.default.setAttributes(
            [.modificationDate: Date()],
            ofItemAtPath: url.path
        )
        return data
    }

    /// Persist `pngData` for tile (z, x, y) in `style`. Creates
    /// intermediate directories on demand. Atomic write so a crash
    /// mid-write can't leave a partial file the next launch tries to
    /// decode.
    func write(style: MapStyle, z: Int, x: Int, y: Int, pngData: Data) {
        let url = url(style: style, z: z, x: x, y: y, in: baseDir)
        // Ensure parent directory exists. Cheap if it already does.
        let parent = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        do {
            try pngData.write(to: url, options: .atomic)
        } catch {
            log.warning("Disk cache write failed for \(style.cacheNamespace, privacy: .public)/\(z, privacy: .public)/\(x, privacy: .public)/\(y, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Returns (count, bytes) for ONE style's namespace — used by the
    /// Settings UI so we can show "Light tiles • 84 • 7.2 MB" per palette.
    func stats(style: MapStyle) -> (count: Int, bytes: Int) {
        let dir = baseDir.appendingPathComponent(style.cacheNamespace, isDirectory: true)
        return stats(in: dir)
    }

    /// Returns (count, bytes) across ALL styles — total on-disk footprint.
    func statsAll() -> (count: Int, bytes: Int) {
        return stats(in: baseDir)
    }

    private nonisolated func stats(in dir: URL) -> (count: Int, bytes: Int) {
        let fm = FileManager.default
        guard let it = fm.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else {
            return (0, 0)
        }
        var count = 0
        var total = 0
        for case let url as URL in it where url.pathExtension == "png" {
            count += 1
            total += (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        }
        return (count, total)
    }

    /// Nuke ONE style's tiles (Settings → per-palette trash). Recreates
    /// the empty namespace directory so subsequent writes don't have to.
    func clear(style: MapStyle) {
        let fm = FileManager.default
        let dir = baseDir.appendingPathComponent(style.cacheNamespace, isDirectory: true)
        do {
            try fm.removeItem(at: dir)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            log.info("Disk cache CLEARED for style \(style.cacheNamespace, privacy: .public)")
        } catch {
            log.warning("Disk cache clear failed for \(style.cacheNamespace, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Nuke the entire disk cache (all styles). Called from Settings →
    /// "Clear map cache". Recreates the empty directory so subsequent
    /// writes don't have to re-create it under the hood.
    func clearAll() {
        let fm = FileManager.default
        do {
            try fm.removeItem(at: baseDir)
            try fm.createDirectory(at: baseDir, withIntermediateDirectories: true)
            log.info("Disk cache CLEARED (all styles)")
        } catch {
            log.warning("Disk cache clear failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Eviction sweep: delete every file older than `maxAgeDays`, then
    /// if we're still over `maxBytesOnDisk` delete oldest-mtime files
    /// until back under. Called once per app launch from a Task —
    /// single-shot, cheap, and the actor serialisation prevents it
    /// racing with reads/writes.
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
        for case let url as URL in it where url.pathExtension == "png" {
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
}
