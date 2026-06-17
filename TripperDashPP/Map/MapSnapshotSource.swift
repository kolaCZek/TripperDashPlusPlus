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

    /// Last successfully emitted frame. While the app is in the background
    /// (screen locked) iOS forbids Metal command buffer submission, so we
    /// can't render fresh map tiles. Instead of starving the dash of RTP
    /// (which would freeze its decoder and trip K1G heartbeat timeout),
    /// we keep re-emitting this buffer at the target fps with fresh PTS.
    /// The dash sees a "frozen but live" stream.
    private var lastFrameBuffer: CVPixelBuffer?

    /// True between `UIApplication.didEnterBackground` and
    /// `willEnterForeground`. Snapshotter calls are suppressed while set.
    private var isInBackground = false

    /// Lifecycle observers held for the duration of streaming.
    private var bgObserver: NSObjectProtocol?
    private var fgObserver: NSObjectProtocol?

    /// Background fallback path. When the screen goes off iOS forbids
    /// Metal command-buffer submission, so the Snapshotter (which uses
    /// Metal) can't render. Static Images API is a plain HTTPS PNG
    /// fetch — pure CPU + network, allowed in the background while the
    /// audio + location wakelock keeps the process alive.
    ///
    /// We poll at ~2 fps (network roundtrip + Mapbox quota friendly) and
    /// the tick loop re-emits the latest fetched frame at the full
    /// target fps so the dash decoder never starves.
    private var bgFetchTask: Task<Void, Never>?
    private var lastBgFrame: CVPixelBuffer?
    private let bgFetchInterval: TimeInterval = 0.5
    private lazy var urlSession: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 4
        cfg.waitsForConnectivity = true
        return URLSession(configuration: cfg)
    }()

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

        // v11 removed ResourceOptionsManager — the public token is read
        // from Info.plist (MBXAccessToken) at framework init. We just
        // pass size + pixel ratio.
        let opts = MapSnapshotOptions(
            size: frameSize,
            pixelRatio: 1.0
        )
        let snap = Snapshotter(options: opts)
        // Standard — same style as the in-app MapPickerView preview, so
        // the rider sees the exact look they picked from on the dash.
        snap.styleURI = StyleURI(rawValue: "mapbox://styles/mapbox/standard")
        snapshotter = snap

        // Observe app lifecycle so we can suspend Metal work in the
        // background — iOS 16+ kills GPU command buffers submitted while
        // the app is not foreground (kIOGPUCommandBufferCallbackErrorBackgroundExecutionNotPermitted).
        // The wakelock (audio + location) keeps the process alive; this
        // observer just makes sure we don't try to render with the screen off.
        isInBackground = (UIApplication.shared.applicationState != .active)
        let center = NotificationCenter.default
        bgObserver = center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.isInBackground = true
                self.log.info("App → background: switching to Static Images API fallback")
                self.startBackgroundFetcher()
            }
        }
        fgObserver = center.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.isInBackground = false
                self.stopBackgroundFetcher()
                self.log.info("App → foreground: resuming Snapshotter (Metal)")
            }
        }
        // If we launched directly into background (rare but possible),
        // kick the fetcher right away — no need to wait for a transition.
        if isInBackground { startBackgroundFetcher() }

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
        lastFrameBuffer = nil
        stopBackgroundFetcher()
        if let bg = bgObserver { NotificationCenter.default.removeObserver(bg) }
        if let fg = fgObserver { NotificationCenter.default.removeObserver(fg) }
        bgObserver = nil
        fgObserver = nil
        log.info("MapSnapshotSource stopped after \(self.frameIndex) frames")
    }

    // MARK: - Per-tick render

    private func tick() {
        // Background: don't touch Metal. Re-emit the latest Static-API
        // fetched frame (preferred) or, if none arrived yet, the last
        // Snapshotter frame captured before lockscreen. PTS keeps
        // advancing so the stream stays live for the dash decoder.
        if isInBackground {
            if let buf = lastBgFrame ?? lastFrameBuffer {
                let pts = CMTime(value: CMTimeValue(frameIndex), timescale: CMTimeScale(targetFps))
                frameIndex &+= 1
                onFrame?(buf, pts)
            }
            return
        }

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
        lastFrameBuffer = buffer
        onFrame?(buffer, pts)
    }

    private func emitPlaceholder(message: String) {
        guard let buffer = renderPlaceholder(message: message) else { return }
        let pts = CMTime(value: CMTimeValue(frameIndex), timescale: CMTimeScale(targetFps))
        frameIndex &+= 1
        onFrame?(buffer, pts)
    }

    // MARK: - Background fetcher (Static Images API)

    private func startBackgroundFetcher() {
        bgFetchTask?.cancel()
        bgFetchTask = Task { @MainActor [weak self] in
            // Kick one fetch immediately so we don't wait 500 ms for
            // the first background frame.
            await self?.fetchOneStatic()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64((self?.bgFetchInterval ?? 0.5) * 1_000_000_000))
                if Task.isCancelled { break }
                await self?.fetchOneStatic()
            }
        }
    }

    private func stopBackgroundFetcher() {
        bgFetchTask?.cancel()
        bgFetchTask = nil
        lastBgFrame = nil
    }

    private func fetchOneStatic() async {
        guard let fix = lastFix else { return }
        let bearing: CLLocationDirection = {
            if let h = lastHeading, h.accuracy >= 0 { return h.trueHeading }
            if fix.course >= 0 { return fix.course }
            return 0
        }()
        guard let token = Bundle.main.object(forInfoDictionaryKey: "MBXAccessToken") as? String,
              !token.isEmpty else {
            log.error("Static fetch: MBXAccessToken missing")
            return
        }
        let w = Int(frameSize.width)
        let h = Int(frameSize.height)
        let zoom = 16
        // /styles/v1/{user}/{style_id}/static/{lon},{lat},{zoom},{bearing},{pitch}/{w}x{h}
        // Use the same Mapbox Standard style as foreground so the look
        // stays consistent across the lockscreen transition.
        let pathStr = String(
            format: "/styles/v1/mapbox/standard/static/%.6f,%.6f,%d,%.1f,0/%dx%d",
            fix.coordinate.longitude, fix.coordinate.latitude, zoom, bearing, w, h
        )
        var comps = URLComponents()
        comps.scheme = "https"
        comps.host = "api.mapbox.com"
        comps.path = pathStr
        comps.queryItems = [URLQueryItem(name: "access_token", value: token)]
        guard let url = comps.url else { return }
        do {
            let (data, response) = try await urlSession.data(from: url)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                log.warning("Static API HTTP \(http.statusCode) (\(data.count) bytes)")
                return
            }
            guard let img = UIImage(data: data) else {
                log.warning("Static API returned undecodable image (\(data.count) bytes)")
                return
            }
            guard let buf = pixelBuffer(from: img) else { return }
            lastBgFrame = buf
        } catch {
            // Transient network failure — keep last frame, try again next tick.
            log.debug("Static fetch error: \(error.localizedDescription)")
        }
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
