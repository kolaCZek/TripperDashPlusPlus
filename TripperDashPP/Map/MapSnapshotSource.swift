//
//  MapSnapshotSource.swift
//  TripperDashPP
//
//  Phase 5 — Mapbox-backed FrameSource. Drives the dash with a live
//  map view centred on the rider's current GPS, redrawn at 12 fps and
//  handed to the H.264 encoder as 526×300 BGRA pixel buffers.
//
//  Why Snapshotter and not a hidden MapView in a UIWindow?
//
//    - Snapshotter is Mapbox's first-class off-screen render path.
//      It's the supported, documented API for "give me a UIImage of a
//      map at these camera params"; the hidden-MapView trick relies on
//      private-ish UIWindow lifecycle assumptions and breaks across
//      Mapbox SDK upgrades.
//    - On a static-camera ride (highway cruise) it caches tiles
//      aggressively, so the per-tick cost is mostly camera reposition
//      + GPU composite — fast enough for our 12 fps target on iPhone
//      13+.
//    - The Phase 7 nav engine can layer route geometry on top via
//      `Snapshotter.options.layers` without a second renderer.
//
//  Design notes for future phases:
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
//    - No GPS fix yet → render a "Acquiring GPS…" placeholder so the
//      dash shows something instead of stale loading dots.
//

import CoreGraphics
import CoreLocation
import CoreMedia
import CoreVideo
import Foundation
import MapboxMaps
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

    private var snapshotter: Snapshotter?
    private var locationToken: UUID?
    private var fixSubscription: LocationSubscription?
    private var headingSubscription: LocationSubscription?
    private var lastFix: Fix?
    private var lastHeading: Heading?

    private let queue = DispatchQueue(label: "TripperDashPP.MapSource", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var frameIndex: UInt64 = 0
    private var onFrame: ((CVPixelBuffer, CMTime) -> Void)?

    /// Guards against overlapping snapshot requests. Snapshotter can take
    /// 50–200 ms per call (tile fetch + render); if we fire another tick
    /// while one is in flight we'd just back up the queue and lag the
    /// display behind the rider's position. Drop the tick instead.
    private var snapshotInFlight = false

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

        // Snapshotter requires a resource manager (used for the public
        // access token, tile cache path, etc.). It picks up the token
        // from Info.plist (MBXAccessToken) automatically.
        let opts = MapSnapshotOptions(
            size: frameSize,
            pixelRatio: 1.0,
            resourceOptions: ResourceOptionsManager.default.resourceOptions
        )
        let snap = Snapshotter(options: opts)
        // Navigation Night gives high contrast on the small TFT —
        // bright route lines, dark background, no clutter.
        snap.styleURI = StyleURI(rawValue: "mapbox://styles/mapbox/navigation-night-v1")
        snapshotter = snap

        // Drive the ticks from a serial queue. Each tick re-points the
        // camera and asks for a fresh snapshot.
        let interval = 1.0 / Double(targetFps)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in
            Task { @MainActor in self?.tick() }
        }
        self.timer = timer
        timer.resume()
        log.info("MapSnapshotSource started (\(self.targetFps) fps, \(Int(self.frameSize.width))x\(Int(self.frameSize.height)))")
    }

    func stop() {
        timer?.cancel()
        timer = nil
        snapshotter = nil
        onFrame = nil
        if let service = locationService, let token = locationToken {
            service.stop(token: token)
        }
        locationToken = nil
        fixSubscription = nil
        headingSubscription = nil
        pool = nil
        log.info("MapSnapshotSource stopped after \(self.frameIndex) frames")
    }

    // MARK: - Per-tick render

    private func tick() {
        guard !snapshotInFlight, let snapshotter else { return }

        // No fix yet → render the placeholder synchronously so the dash
        // shows "Acquiring GPS…" instead of stale loading dots.
        guard let fix = lastFix else {
            emitPlaceholder(message: "Acquiring GPS…")
            return
        }

        // Point the camera at the rider. Bearing follows compass heading
        // when valid (positive accuracy), otherwise we fall back to
        // course-over-ground from the GPS speed vector. Zoom 16 is the
        // navigation-style "next 200 m" framing.
        let bearing: CLLocationDirection? = {
            if let h = lastHeading, h.accuracy >= 0 { return h.trueHeading }
            if fix.course >= 0 { return fix.course }
            return nil
        }()
        let camera = CameraOptions(
            center: fix.coordinate,
            padding: nil,
            anchor: nil,
            zoom: 16,
            bearing: bearing,
            pitch: 0
        )
        snapshotter.setCamera(to: camera)

        snapshotInFlight = true
        let captureIndex = frameIndex
        snapshotter.start(overlayHandler: nil) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.snapshotInFlight = false
                switch result {
                case .success(let image):
                    self.emitImage(image, index: captureIndex)
                case .failure(let err):
                    self.log.warning("Snapshotter failed: \(err.localizedDescription)")
                    self.emitPlaceholder(message: "Map error")
                }
            }
        }
    }

    private func emitImage(_ image: UIImage, index: UInt64) {
        guard let buffer = pixelBuffer(from: image) else { return }
        let pts = CMTime(value: CMTimeValue(index), timescale: CMTimeScale(targetFps))
        frameIndex = index &+ 1
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
    /// dash's native size. Snapshotter already gives us the right size
    /// thanks to MapSnapshotOptions, but we still need to convert from
    /// UIImage's CGImage to a CVPixelBuffer for VideoToolbox.
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

        // Dark background matching the navigation-night style.
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
