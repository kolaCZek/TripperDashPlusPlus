//
//  MapSnapshotSource.swift
//  TripperDashPP
//
//  Phase 5 — Apple Maps-backed FrameSource. Drives the dash with a live
//  map view centred on the rider's current GPS, redrawn at 12 fps and
//  handed to the H.264 encoder as 526×300 BGRA pixel buffers.
//
//  Why MKMapSnapshotter and not Mapbox?
//
//    - Mapbox iOS SDK renders via Metal. iOS 16+ kills any Metal command
//      buffer submitted from a non-foreground process, which means the
//      stream froze the moment the rider locked the screen. The rider's
//      use case is "phone in pocket on the bike", i.e. always background.
//    - Apple's MapKit is the native, system-level map framework. Whether
//      MKMapSnapshotter is permitted to render in the background is
//      undocumented — we're testing it. If it survives lockscreen we
//      win (no quota, no token, no SDK dependency).
//    - Even foreground-only this removes the Mapbox account / token /
//      quota plumbing and the SPM dependency from the streaming path.
//
//  Design notes:
//    - `MapSnapshotSource` consumes `LocationService` updates rather
//      than owning a CLLocationManager. That keeps the wakelock + map
//      camera + (future) nav engine on a single shared GPS subscription.
//    - The class exposes `setCameraOverride(_:)` and `setRoute(_:)` as
//      no-op-friendly entry points; Phase 7 hooks turn-by-turn maneuver
//      previews and chase-cam framing through these instead of growing
//      a parallel renderer.
//
//  Failure modes the encoder downstream tolerates:
//    - Snapshotter is busy / mid-tile-fetch → we skip the tick (no
//      callback). Better to drop a frame than queue stale captures.
//    - No GPS fix yet → render an "Acquiring GPS…" placeholder so the
//      dash shows something instead of stale loading dots.
//    - Snapshotter returns an error (typically rate-limit or background
//      GPU rejection) → re-emit the last good frame so the dash decoder
//      stays fed; PTS keeps advancing so the stream looks live.
//

import CoreGraphics
import CoreLocation
import CoreMedia
import CoreVideo
import Foundation
import MapKit
import os.log
import UIKit

@MainActor
final class MapSnapshotSource: FrameSource {

    // MARK: - FrameSource contract

    let frameSize = CGSize(width: 526, height: 300)
    let targetFps = 6

    /// At targetFps=6 the encoder tick rate already matches what
    /// MKMapSnapshotter can sustain comfortably (a 2× supersampled
    /// 526×300 render takes 80–250 ms). We schedule snapshots at the
    /// same rate as the encoder — one fresh frame per tick. If a
    /// snapshot is still in flight when the next tick fires we skip
    /// that request and the encoder re-emits the last latched frame.
    private let snapshotFps = 6

    // MARK: - Dependencies

    private weak var locationService: LocationService?
    private let log = Logger(subsystem: "TripperDashPP", category: "MapSource")

    // MARK: - State

    /// Live snapshotter held strongly during a render so MapKit doesn't
    /// deallocate it mid-load. NEVER call `.cancel()` on it — that
    /// triggers an MTLDebugDevice assertion if the Metal command buffer
    /// is still in flight, which freezes the app. Just discard the
    /// reference and let the completion handler arrive into a no-op
    /// (gated by `generation` so stale results are dropped).
    private var currentSnapshotter: MKMapSnapshotter?
    /// Bumped on stop() and on every new snapshot request. Completion
    /// handlers check it before doing anything; mismatched generations
    /// just return.
    private var generation: UInt64 = 0
    private var locationToken: UUID?
    private var fixSubscription: LocationSubscription?
    private var headingSubscription: LocationSubscription?
    private var lastFix: Fix?
    private var lastHeading: Heading?

    private let queue = DispatchQueue(label: "TripperDashPP.MapSource", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var frameIndex: UInt64 = 0
    private var onFrame: ((CVPixelBuffer, CMTime) -> Void)?

    /// Guards against overlapping snapshot requests. MKMapSnapshotter can
    /// take 50–250 ms per call (tile fetch + render); if we fire another
    /// tick while one is in flight we'd back up the queue and lag behind
    /// the rider's position. Drop the tick instead.
    private var snapshotInFlight = false

    /// Last snapshot result we got from MapKit. The encoder ticks at
    /// `targetFps` and re-emits whichever frame is currently latched
    /// here. The snapshotter runs at `snapshotFps` (slower) and
    /// updates this whenever a render completes successfully.
    private var latestSnapshot: CVPixelBuffer?

    /// Wall-clock time we last KICKED OFF a snapshot request. The
    /// snapshotter tick runs at `snapshotFps` independently of the
    /// 12 fps encoder tick.
    private var lastSnapshotRequestAt: TimeInterval = 0

    /// Diagnostics: consecutive snapshotter failures, reset on success.
    /// If this climbs high while the screen is off, we know Apple Maps
    /// hit the same Metal background restriction as Mapbox did.
    private var consecutiveFailures: Int = 0

    /// Reusable pool keeps allocation pressure low at 12 fps.
    private var pool: CVPixelBufferPool?

    // MARK: - Init

    /// Optional navigator — when set and active, the snapshot is post-
    /// processed: route polyline drawn on top, next-step glyph drawn
    /// in the bottom-left corner so the dash shows the same turn cue
    /// as the phone HUD.
    private weak var activeNavigator: ActiveNavigator?

    init(locationService: LocationService, activeNavigator: ActiveNavigator? = nil) {
        self.locationService = locationService
        self.activeNavigator = activeNavigator
    }

    deinit {
        // Best-effort: capture token + service synchronously and post a
        // release on the main actor. Note that if start() was called
        // multiple times without stop() between them, only the LAST
        // token gets released here — but in practice the StreamingView
        // teardown calls stop() explicitly, so deinit is a safety net.
        if let token = locationToken, let service = locationService {
            Task { @MainActor in service.stop(token: token) }
        }
    }

    // MARK: - FrameSource

    func start(onFrame: @escaping (CVPixelBuffer, CMTime) -> Void) {
        // Defensive: if start() is called twice in a row without stop()
        // (e.g. view re-creation race), release the previous slot first
        // so consumers don't accumulate in LocationService.
        if locationToken != nil || timer != nil {
            log.notice("MapSnapshotSource.start called while already running — recycling previous session")
            stop()
        }

        self.onFrame = onFrame
        preparePool()

        // Acquire GPS at full accuracy. The same LocationService is
        // already holding the wakelock at .wakelock priority; our slot
        // upgrades the manager to .mapping (best accuracy, no filter).
        if let service = locationService {
            locationToken = service.start(mode: .mapping)
            fixSubscription = service.subscribeFixes { [weak self] fix in
                self?.lastFix = fix
            }
            headingSubscription = service.subscribeHeading { [weak self] heading in
                self?.lastHeading = heading
            }
        }

        // Drive the ticks from a serial queue. Each tick builds a fresh
        // MKMapSnapshotter pointed at the rider and asks for an image.
        let interval = 1.0 / Double(targetFps)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in
            Task { @MainActor in self?.tick() }
        }
        self.timer = timer
        timer.resume()
        log.info("MapSnapshotSource started (Apple Maps, \(self.targetFps) fps, \(Int(self.frameSize.width))x\(Int(self.frameSize.height)))")
    }

    func stop() {
        timer?.cancel()
        timer = nil
        // CRITICAL: do NOT call currentSnapshotter.cancel() — it triggers
        // an MTLDebugDevice assertion when a Metal command buffer is
        // still alive. Bump generation so any pending completion drops
        // its result, and park the snapshotter for grace period so its
        // GPU work can drain.
        generation &+= 1
        if let current = currentSnapshotter {
            Self.parkSnapshotter(current)
        }
        currentSnapshotter = nil
        onFrame = nil
        if let service = locationService, let token = locationToken {
            service.stop(token: token)
        }
        locationToken = nil
        fixSubscription = nil
        headingSubscription = nil
        pool = nil
        latestSnapshot = nil
        consecutiveFailures = 0
        lastSnapshotRequestAt = 0
        log.info("MapSnapshotSource stopped after \(self.frameIndex) frames")
    }

    // MARK: - Per-tick render

    private func tick() {
        // Re-emit whatever's currently latched at the full target fps.
        // The snapshotter completion updates `latestSnapshot` whenever
        // a fresh render lands. This decouples encoder throughput from
        // MapKit render time.
        if let latest = latestSnapshot {
            let pts = CMTime(value: CMTimeValue(frameIndex), timescale: CMTimeScale(targetFps))
            frameIndex &+= 1
            onFrame?(latest, pts)
        } else if lastFix == nil {
            emitPlaceholder(message: "Acquiring GPS…")
        } else {
            // First few ticks before first snapshot lands — neutral
            // placeholder so the K1G heartbeat starts in lockstep.
            emitPlaceholder(message: "Loading map…")
        }

        // Maybe kick off a new MapKit snapshot, rate-limited to
        // `snapshotFps`. We only fire one at a time (no overlap), and
        // never sooner than 1/snapshotFps after the previous request.
        let now = CACurrentMediaTime()
        let minGap = 1.0 / Double(snapshotFps)
        guard !snapshotInFlight, now - lastSnapshotRequestAt >= minGap else { return }
        guard let fix = lastFix else { return }
        lastSnapshotRequestAt = now
        requestSnapshot(for: fix)
    }

    private func requestSnapshot(for fix: Fix) {
        // Bearing follows compass heading when valid (positive accuracy),
        // otherwise we fall back to course-over-ground from the GPS
        // speed vector. Zero on no signal.
        let bearing: CLLocationDirection = {
            if let h = lastHeading, h.accuracy >= 0 { return h.trueHeading }
            if fix.course >= 0 { return fix.course }
            return 0
        }()

        // 500 m visible distance ≈ Mapbox zoom 16 framing — the "next
        // 200 m" view used by most turn-by-turn nav apps.
        let camera = MKMapCamera(
            lookingAtCenter: fix.coordinate,
            fromDistance: 500,
            pitch: 0,
            heading: bearing
        )

        let options = MKMapSnapshotter.Options()
        options.size = frameSize
        // Render at 2× and let CGContext downsample into the dash's
        // native 526×300 pixel buffer. The extra source pixels make
        // road names and shields significantly more legible after H.264
        // — at 1:1 scale the renderer rounds glyph strokes to whole
        // pixels and the encoder smears the result.
        options.scale = 2.0
        options.camera = camera
        if #available(iOS 16.0, *) {
            options.preferredConfiguration = MKStandardMapConfiguration(
                elevationStyle: .flat,
                emphasisStyle: .default
            )
        } else {
            options.mapType = .standard
        }

        let snapshotter = MKMapSnapshotter(options: options)
        currentSnapshotter = snapshotter
        snapshotInFlight = true
        generation &+= 1
        let myGen = generation

        snapshotter.start(with: .main) { [weak self] snapshot, error in
            Task { @MainActor in
                guard let self else {
                    // Self gone (view torn down) — still park the
                    // snapshotter so its GPU work can drain without
                    // crashing the process.
                    Self.parkSnapshotter(snapshotter)
                    return
                }
                // Stale result from a previous start() session — drop
                // the data, but the snapshotter still needs grace time.
                if myGen != self.generation {
                    Self.parkSnapshotter(snapshotter)
                    return
                }
                self.snapshotInFlight = false
                if self.currentSnapshotter === snapshotter {
                    self.currentSnapshotter = nil
                }
                if let snap = snapshot {
                    self.consecutiveFailures = 0
                    let composed = self.composeOverlay(on: snap)
                    if let buf = self.pixelBuffer(from: composed) {
                        self.latestSnapshot = buf
                    }
                } else {
                    self.consecutiveFailures &+= 1
                    let nserr = (error as NSError?)
                    let code = nserr?.code ?? -1
                    let desc = error?.localizedDescription ?? "unknown"
                    if self.consecutiveFailures == 1 || self.consecutiveFailures % 60 == 0 {
                        self.log.warning("MKMapSnapshotter failed [#\(self.consecutiveFailures)] code=\(code): \(desc)")
                    }
                    // Leave `latestSnapshot` as-is; the next encoder tick
                    // will re-emit the previous good frame so the stream
                    // doesn't stall.
                }
                // CRITICAL: park the snapshotter for a grace period
                // before letting it deallocate. MKMapSnapshotter signals
                // completion as soon as the result image is ready, but
                // its underlying Metal command buffer is still draining
                // on the GPU for up to a couple of seconds afterwards.
                // If we release the snapshotter now, MTLDebugDevice
                // asserts ('Metal object destroyed while still required
                // to be alive by the command buffer') and the app
                // freezes.
                Self.parkSnapshotter(snapshotter)
            }
        }
    }

    /// Holds an MKMapSnapshotter alive after its completion callback
    /// fires, so the underlying Metal command buffer has time to
    /// finish executing on the GPU before the snapshotter is
    /// deallocated.
    ///
    /// Previous implementation used `Task.detached` with a 3 s sleep,
    /// but `Task.sleep` is wall-clock based and iOS suspends background
    /// tasks aggressively. When the app spent time in background, the
    /// timer would fire prematurely relative to the (also-suspended)
    /// GPU work, the snapshotter would be released, and the Metal CB
    /// would crash on resume.
    ///
    /// Current implementation: bounded LIFO ring buffer in a separate
    /// non-isolated holder (storage can't live on @MainActor class
    /// because we need to push from nonisolated context). Each
    /// snapshotter is retained until pushed out by 99 newer ones. At
    /// 6 fps that's ~16 s of natural retention, fully decoupled from
    /// wall-clock time and immune to background scheduler suspension.
    /// Memory cost: snapshotter holds a few hundred KB, total cap ~50 MB.
    nonisolated static func parkSnapshotter(_ snapshotter: MKMapSnapshotter) {
        SnapshotterPark.shared.park(snapshotter)
    }

    private func emitPlaceholder(message: String) {
        guard let buffer = renderPlaceholder(message: message) else { return }
        let pts = CMTime(value: CMTimeValue(frameIndex), timescale: CMTimeScale(targetFps))
        frameIndex &+= 1
        onFrame?(buffer, pts)
    }

    // MARK: - Pixel buffer plumbing

    private func preparePool() {
        let width = Int(frameSize.width)
        let height = Int(frameSize.height)
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:],
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ]
        var p: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &p)
        if status != kCVReturnSuccess {
            log.error("CVPixelBufferPoolCreate failed: \(status)")
        }
        pool = p
    }

    /// Draws a UIImage into a fresh BGRA pixel buffer at exactly the
    /// dash's native size. We tell MKMapSnapshotter to render at 2×
    /// scale (1052×600 of source pixels) and then downsample here into
    /// the 526×300 buffer — gives smoother glyphs and road antialiasing
    /// after the H.264 encoder rounds everything.
    /// Post-process the MKMapSnapshotter.Snapshot to overlay the active route
    /// polyline and a next-step maneuver glyph. Returns the original
    /// snapshot image when no navigation is active — so this is also
    /// the right path for the no-nav streaming case (test, pre-flight).
    private func composeOverlay(on snap: MKMapSnapshotter.Snapshot) -> UIImage {
        let baseImage = snap.image
        guard let nav = activeNavigator, nav.isNavigating,
              let polyline = nav.activeRoute?.polyline else {
            return baseImage
        }

        let size = baseImage.size
        let format = UIGraphicsImageRendererFormat()
        format.scale = baseImage.scale
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)

        return renderer.image { ctx in
            baseImage.draw(at: .zero)
            let cg = ctx.cgContext

            // Polyline — convert each point to image space via the
            // snapshot's own projection so it lines up with the
            // rendered streets.
            let count = polyline.pointCount
            guard count >= 2 else { return }

            cg.setStrokeColor(UIColor.systemBlue.withAlphaComponent(0.85).cgColor)
            cg.setLineWidth(8)
            cg.setLineCap(.round)
            cg.setLineJoin(.round)

            let coords = polylineCoordinates(polyline)
            var started = false
            for coord in coords {
                let p = snap.point(for: coord)
                // Skip points outside the snapshot (saves a tiny bit
                // of CG work for routes that extend off-screen).
                guard p.x.isFinite, p.y.isFinite else { continue }
                if !started {
                    cg.move(to: p)
                    started = true
                } else {
                    cg.addLine(to: p)
                }
            }
            cg.strokePath()

            // Next-step glyph in the bottom-left corner, sized to the
            // dash. Render text below it so the rider can read both at
            // a glance. Background is a rounded translucent slab.
            if let step = nav.nextStep {
                let glyph = ManeuverGlyph.symbol(for: step)
                let distText = ActiveNavigator.formatDistance(nav.distanceToNextStep)
                drawManeuverCard(in: cg, size: size, glyph: glyph, distance: distText)
            }
        }
    }

    /// Helper: pull a `[CLLocationCoordinate2D]` out of an MKPolyline
    /// without UB. `getCoordinates(_:range:)` writes into a buffer we
    /// allocate.
    private func polylineCoordinates(_ line: MKPolyline) -> [CLLocationCoordinate2D] {
        let n = line.pointCount
        var coords = [CLLocationCoordinate2D](
            repeating: CLLocationCoordinate2D(latitude: 0, longitude: 0),
            count: n
        )
        coords.withUnsafeMutableBufferPointer { buf in
            line.getCoordinates(buf.baseAddress!, range: NSRange(location: 0, length: n))
        }
        return coords
    }

    /// Draw a translucent rounded card with a maneuver glyph + distance
    /// label in the bottom-left corner.
    private func drawManeuverCard(in cg: CGContext, size: CGSize,
                                  glyph: String, distance: String) {
        let cardW: CGFloat = 180 * (size.width / 526)
        let cardH: CGFloat = 64 * (size.height / 300)
        let margin: CGFloat = 8 * (size.width / 526)
        let rect = CGRect(x: margin,
                          y: size.height - cardH - margin,
                          width: cardW, height: cardH)

        cg.saveGState()
        cg.setFillColor(UIColor.black.withAlphaComponent(0.55).cgColor)
        let path = UIBezierPath(roundedRect: rect, cornerRadius: 10)
        cg.addPath(path.cgPath)
        cg.fillPath()
        cg.restoreGState()

        // Glyph
        let glyphFont = UIFont.systemFont(ofSize: cardH * 0.55, weight: .heavy)
        let glyphAttrs: [NSAttributedString.Key: Any] = [
            .font: glyphFont,
            .foregroundColor: UIColor.white,
        ]
        let glyphStr = NSAttributedString(string: glyph, attributes: glyphAttrs)
        let glyphSize = glyphStr.size()
        let glyphOrigin = CGPoint(x: rect.minX + 8,
                                  y: rect.midY - glyphSize.height / 2)
        glyphStr.draw(at: glyphOrigin)

        // Distance label
        let distFont = UIFont.systemFont(ofSize: cardH * 0.35, weight: .semibold)
        let distAttrs: [NSAttributedString.Key: Any] = [
            .font: distFont,
            .foregroundColor: UIColor.white,
        ]
        let distStr = NSAttributedString(string: distance, attributes: distAttrs)
        let distOrigin = CGPoint(x: rect.minX + 8 + glyphSize.width + 10,
                                 y: rect.midY - distStr.size().height / 2)
        distStr.draw(at: distOrigin)
    }

    private func pixelBuffer(from image: UIImage) -> CVPixelBuffer? {
        guard let pool, let cgImage = image.cgImage else { return nil }
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard status == kCVReturnSuccess, let buffer else {
            log.error("CVPixelBufferPoolCreatePixelBuffer failed: \(status)")
            return nil
        }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: base,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        // High-quality downsample from 2× source to dash native size.
        ctx.interpolationQuality = .high
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }

    private func renderPlaceholder(message: String) -> CVPixelBuffer? {
        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard status == kCVReturnSuccess, let buffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: base,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        // Dark background, readable on the small TFT.
        ctx.setFillColor(red: 0.05, green: 0.07, blue: 0.10, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // Flip CTM so UIKit text draws right-side up.
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        UIGraphicsPushContext(ctx)
        defer { UIGraphicsPopContext() }

        let font = UIFont.monospacedSystemFont(ofSize: 18, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor.white,
        ]
        let attr = NSAttributedString(string: message, attributes: attrs)
        let size = attr.size()
        let origin = CGPoint(
            x: (CGFloat(width) - size.width) / 2,
            y: (CGFloat(height) - size.height) / 2
        )
        attr.draw(at: origin)

        return buffer
    }
}


// MARK: - SnapshotterPark

/// Non-isolated holder that retains MKMapSnapshotter instances after
/// their completion fires, so the underlying Metal command buffer has
/// time to drain on the GPU. Lives outside MapSnapshotSource because
/// that class is @MainActor and we need to push from nonisolated
/// contexts (e.g. completion handlers that capture `weak self`).
///
/// Strategy: bounded LIFO ring. New entries push out old ones; by the
/// time an entry has been pushed out by `capacity` newer entries the
/// GPU work is long-since complete.
final class SnapshotterPark: @unchecked Sendable {
    static let shared = SnapshotterPark(capacity: 100)

    private let capacity: Int
    private let lock = NSLock()
    private var ring: [MKMapSnapshotter] = []

    init(capacity: Int) {
        self.capacity = capacity
        self.ring.reserveCapacity(capacity + 1)
    }

    func park(_ snapshotter: MKMapSnapshotter) {
        lock.lock()
        defer { lock.unlock() }
        ring.append(snapshotter)
        if ring.count > capacity {
            ring.removeFirst(ring.count - capacity)
        }
    }
}
