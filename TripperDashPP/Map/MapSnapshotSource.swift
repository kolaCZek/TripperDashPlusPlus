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
    let targetFps = 12

    // MARK: - Dependencies

    private weak var locationService: LocationService?
    private let log = Logger(subsystem: "TripperDashPP", category: "MapSource")

    // MARK: - State

    /// Live snapshotter held strongly during a render so MapKit doesn't
    /// deallocate it mid-load.
    private var currentSnapshotter: MKMapSnapshotter?
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

    /// Last successfully emitted frame. We re-emit it whenever the
    /// snapshotter fails (background GPU rejection, throttling, transient
    /// network) so the dash decoder never starves and the K1G heartbeat
    /// stays alive. PTS keeps advancing so the stream looks live even
    /// when the picture is frozen.
    private var lastFrameBuffer: CVPixelBuffer?

    /// Diagnostics: consecutive snapshotter failures, reset on success.
    /// If this climbs high while the screen is off, we know Apple Maps
    /// hit the same Metal background restriction as Mapbox did.
    private var consecutiveFailures: Int = 0

    /// Reusable pool keeps allocation pressure low at 12 fps.
    private var pool: CVPixelBufferPool?

    // MARK: - Init

    init(locationService: LocationService) {
        self.locationService = locationService
    }

    deinit {
        // deinit may run off-main; release shared services explicitly.
        Task { @MainActor [locationService, locationToken] in
            if let token = locationToken { locationService?.stop(token: token) }
        }
    }

    // MARK: - FrameSource

    func start(onFrame: @escaping (CVPixelBuffer, CMTime) -> Void) {
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
        currentSnapshotter?.cancel()
        currentSnapshotter = nil
        onFrame = nil
        if let service = locationService, let token = locationToken {
            service.stop(token: token)
        }
        locationToken = nil
        fixSubscription = nil
        headingSubscription = nil
        pool = nil
        lastFrameBuffer = nil
        consecutiveFailures = 0
        log.info("MapSnapshotSource stopped after \(self.frameIndex) frames")
    }

    // MARK: - Per-tick render

    private func tick() {
        guard !snapshotInFlight else { return }

        // No fix yet → render the placeholder synchronously so the dash
        // shows "Acquiring GPS…" instead of stale loading dots.
        guard let fix = lastFix else {
            emitPlaceholder(message: "Acquiring GPS…")
            return
        }

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
            // .realistic looks nicest but the elevation shading kills
            // legibility on a 526×300 TFT in sunlight. .flat keeps the
            // standard look but flattens shading. POIs stay on so we
            // get road names and the rider has visual landmarks.
            options.preferredConfiguration = MKStandardMapConfiguration(
                elevationStyle: .flat,
                emphasisStyle: .default
            )
        } else {
            options.mapType = .standard
        }
        // Keep POI filter open by default — riders want to see the
        // gas station / restaurant on the map. Phase 7 (turn-by-turn)
        // will dial this down to nav-relevant POIs only.

        let snapshotter = MKMapSnapshotter(options: options)
        currentSnapshotter = snapshotter
        snapshotInFlight = true
        let captureIndex = frameIndex

        snapshotter.start(with: .main) { [weak self] snapshot, error in
            Task { @MainActor in
                guard let self else { return }
                self.snapshotInFlight = false
                if self.currentSnapshotter === snapshotter {
                    self.currentSnapshotter = nil
                }
                if let snap = snapshot {
                    self.consecutiveFailures = 0
                    self.emitImage(snap.image, index: captureIndex)
                } else {
                    self.consecutiveFailures &+= 1
                    let nserr = (error as NSError?)
                    let code = nserr?.code ?? -1
                    let desc = error?.localizedDescription ?? "unknown"
                    // Log loudly the first failure in a streak, then go
                    // quiet — no point spamming hundreds of identical
                    // lines if we hit a sustained block (e.g. lockscreen).
                    if self.consecutiveFailures == 1 || self.consecutiveFailures % 60 == 0 {
                        self.log.warning("MKMapSnapshotter failed [#\(self.consecutiveFailures)] code=\(code): \(desc)")
                    }
                    // Re-emit the last good frame so the dash decoder
                    // keeps getting RTP at full rate.
                    if let buf = self.lastFrameBuffer {
                        let pts = CMTime(value: CMTimeValue(captureIndex), timescale: CMTimeScale(self.targetFps))
                        self.frameIndex = captureIndex &+ 1
                        self.onFrame?(buf, pts)
                    } else {
                        self.emitPlaceholder(message: "Map error")
                    }
                }
            }
        }
    }

    private func emitImage(_ image: UIImage, index: UInt64) {
        guard let buffer = pixelBuffer(from: image) else { return }
        let pts = CMTime(value: CMTimeValue(index), timescale: CMTimeScale(targetFps))
        frameIndex = index &+ 1
        lastFrameBuffer = buffer
        onFrame?(buffer, pts)
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
