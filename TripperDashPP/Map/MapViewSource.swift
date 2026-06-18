//
//  MapViewSource.swift
//  TripperDashPP
//
//  Phase 8d — Pre-rendered route tile cache as the BG frame source.
//
//  History:
//  --------
//  Phase 8b: live MKMapView.layer.render(in:) every frame. FAILS in BG —
//            MapKit's Metal renderer is paused once the app is no longer
//            .active, so layer.render returns black pixels.
//
//  Phase 8c: MKMapSnapshotter on a 1 Hz cache + dot overlay. FAILS in
//            BG — the snapshotter completion handler is silently
//            suspended on the lock screen too. Confirmed by telemetry.
//
//  Phase 8d (THIS): pre-render every tile we'll need DURING foreground
//            (when the GPU is awake), JPEG-compress them in memory, then
//            in BG do CPU-only CGContext composition: crop a tile around
//            the current fix, rotate to heading-up, draw the polyline,
//            draw the user dot. CGContext is BG-safe.
//
//  Output:
//  -------
//  526×300 BGRA pixel buffer at 6 fps emitted to the encoder. PiP keeps
//  the encoder pipeline + Swift Concurrency executor alive on lock
//  screen; the tile cache supplies the visual content.

import CoreLocation
import CoreMedia
import CoreVideo
import MapKit
import OSLog
import UIKit

@MainActor
final class MapViewSource: NSObject, FrameSource {

    // MARK: - FrameSource contract

    let frameSize = CGSize(width: 526, height: 300)
    let targetFps = 6

    // MARK: - State

    private let mapView = MKMapView()
    private weak var locationService: LocationService?
    private weak var activeNavigator: ActiveNavigator?
    private let log = Logger(subsystem: "TripperDashPP", category: "MapViewSource")

    private var locationToken: UUID?
    private var fixSubscription: LocationSubscription?
    private var headingSubscription: LocationSubscription?
    private var lastFix: Fix?
    private var lastHeading: CLLocationDirection = 0

    private let queue = DispatchQueue(label: "TripperDashPP.MapViewSource", qos: .userInitiated)
    private var renderTask: Task<Void, Never>?
    private var frameIndex: UInt64 = 0
    private var onFrame: ((CVPixelBuffer, CMTime) -> Void)?

    private var pixelBufferPool: CVPixelBufferPool?
    private var routePolyline: MKPolyline?
    private var routePolylineCoords: [CLLocationCoordinate2D] = []

    /// Pre-rendered tile cache — built from the active route in FG.
    private var routeTileCache: RouteTileCache?
    private var lastTileHintIndex: Int = 0

    /// PiP wrapper.
    /// Phase 8d removed — tile cache + CGContext composite is BG-safe
    /// without PiP. AVAudioSession (SilentAudioKeeper) keeps the
    /// process awake on lock screen.

    init(locationService: LocationService, activeNavigator: ActiveNavigator) {
        self.locationService = locationService
        self.activeNavigator = activeNavigator
        super.init()
        configureMapView()
    }

    deinit {}

    var hostView: MKMapView { mapView }

    private func configureMapView() {
        mapView.frame = CGRect(origin: .zero, size: frameSize)
        mapView.bounds = CGRect(origin: .zero, size: frameSize)
        mapView.showsCompass = false
        mapView.showsScale = false
        mapView.showsTraffic = false
        mapView.showsBuildings = true
        mapView.showsUserLocation = true
        mapView.userTrackingMode = .followWithHeading
        mapView.preferredConfiguration = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .default)
        mapView.delegate = self
        mapView.isPitchEnabled = false
        mapView.isRotateEnabled = false
        mapView.isScrollEnabled = false
        mapView.isZoomEnabled = false
    }

    // MARK: - FrameSource

    func start(onFrame: @escaping (CVPixelBuffer, CMTime) -> Void) {
        self.onFrame = onFrame
        self.frameIndex = 0
        preparePool()
        subscribeLocation()
        startTimer()
        log.info("MapViewSource started (live MKMapView, \(self.targetFps) fps, \(Int(self.frameSize.width))x\(Int(self.frameSize.height)))")
    }

    func stop() {
        renderTask?.cancel()
        renderTask = nil
        if let service = locationService, let token = locationToken {
            service.stop(token: token)
        }
        locationToken = nil
        fixSubscription = nil
        headingSubscription = nil
        onFrame = nil
        log.info("MapViewSource stopped after \(self.frameIndex) frames")
    }

    // MARK: - Tile cache wiring

    /// Install a pre-rendered tile cache produced by `RouteTileCache.prerender`.
    /// Once installed, the BG render path will composite from these tiles
    /// instead of asking MapKit to draw anything.
    func setTileCache(_ cache: RouteTileCache?) {
        routeTileCache = cache
        lastTileHintIndex = 0
        log.info("Tile cache installed: \(cache?.tiles.count ?? 0, privacy: .public) tiles")
    }
}

// MARK: - Location wiring

extension MapViewSource {
    private func subscribeLocation() {
        guard let service = locationService else { return }
        locationToken = service.start(mode: .mapping)
        fixSubscription = service.subscribeFixes { [weak self] fix in
            Task { @MainActor in self?.handleFix(fix) }
        }
        headingSubscription = service.subscribeHeading { [weak self] heading in
            Task { @MainActor in self?.handleHeading(heading) }
        }
    }

    private func handleFix(_ fix: Fix) {
        lastFix = fix
        let region = MKCoordinateRegion(
            center: fix.coordinate,
            latitudinalMeters: 400,
            longitudinalMeters: 400
        )
        mapView.setRegion(region, animated: false)
    }

    private func handleHeading(_ heading: Heading) {
        lastHeading = heading.trueHeading
        let cam = mapView.camera.copy() as! MKMapCamera
        cam.heading = heading.trueHeading
        mapView.setCamera(cam, animated: false)
    }
}

// MARK: - Render tick

extension MapViewSource {
    /// Render loop via Swift Concurrency Task + Task.sleep.
    /// Same scheduler pattern as HeartbeatLoop, which we've confirmed
    /// keeps ticking on locked screen with PiP active.
    private func startTimer() {
        renderTask?.cancel()
        let intervalNs: UInt64 = UInt64(1_000_000_000) / UInt64(targetFps)
        renderTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tickOnMain()
                try? await Task.sleep(nanoseconds: intervalNs)
            }
        }
    }

    @MainActor
    private func tickOnMain() async {
        guard onFrame != nil else { return }
        guard let buffer = renderMapViewToPixelBuffer() else { return }
        let pts = CMTime(value: CMTimeValue(frameIndex), timescale: CMTimeScale(targetFps))
        frameIndex &+= 1
        if frameIndex % 60 == 0 {
            let state = UIApplication.shared.applicationState.rawValue
            log.info("frame tick #\(self.frameIndex, privacy: .public) (appState=\(state, privacy: .public))")
        }
        onFrame?(buffer, pts)
    }

    private func renderMapViewToPixelBuffer() -> CVPixelBuffer? {
        guard let pool = pixelBufferPool else { return nil }
        var pb: CVPixelBuffer?
        let r = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
        guard r == kCVReturnSuccess, let buffer = pb else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue |
                         CGBitmapInfo.byteOrder32Little.rawValue

        guard let ctx = CGContext(
            data: base,
            width: Int(frameSize.width),
            height: Int(frameSize.height),
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return nil }

        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: frameSize.width, height: frameSize.height))

        // CGContext for CVPixelBuffer has origin at bottom-left;
        // CALayer/UIImage expect top-left. Flip the Y axis once.
        ctx.translateBy(x: 0, y: frameSize.height)
        ctx.scaleBy(x: 1, y: -1)

        // Unified FG + BG path. After the PiP/thumb removal, the
        // MKMapView is no longer in a window so layer.render produces
        // black. Instead we always composite from the pre-rendered
        // tile cache (built when navigation starts) — works FG and BG
        // since it's pure CGContext, no MapKit live render.
        if routeTileCache != nil {
            drawTileCacheFrame(into: ctx)
        } else {
            // Pre-navigation / no cache — vector-only on dark slate.
            drawVectorOnlyFrame(into: ctx)
        }

        return buffer
    }
}

// MARK: - BG render: tile cache composite

extension MapViewSource {
    /// Draw one BG frame from the pre-rendered tile cache.
    /// Steps: pick nearest tile → rotate context to heading-up →
    /// draw cropped tile → polyline → user dot in the center.
    private func drawTileCacheFrame(into ctx: CGContext) {
        guard let cache = routeTileCache, let fix = lastFix else { return }
        guard let (_, idx) = cache.nearestTile(to: fix.coordinate, hintIndex: lastTileHintIndex) else {
            // Off-route / re-routing — fall back to vector-only.
            drawVectorOnlyFrame(into: ctx)
            return
        }
        lastTileHintIndex = idx

        // Debug: log mismatch between user GPS and selected tile centre.
        if frameIndex % 30 == 0 {
            let t = cache.tiles[idx]
            let dist = PolylineMath.haversine(fix.coordinate, t.center)
            log.debug("tile pick idx=\(idx) user=(\(fix.coordinate.latitude),\(fix.coordinate.longitude)) tile.center=(\(t.center.latitude),\(t.center.longitude)) dist=\(Int(dist))m heading=\(Int(self.lastHeading))°")
        }

        // Pick the centre tile + 2 neighbours either side. After
        // heading-up rotation, frame corners can reach beyond a single
        // tile's footprint — drawing all overlapping tiles keeps the
        // composite seamless.
        var tilesToDraw: [(RouteTile, CGImage)] = []
        for offset in -2...2 {
            let i = idx + offset
            guard i >= 0, i < cache.tiles.count else { continue }
            let t = cache.tiles[i]
            guard let img = cache.image(for: t, atIndex: i)?.cgImage else { continue }
            tilesToDraw.append((t, img))
        }
        guard let refTile = tilesToDraw.first?.0 else { return }

        // Pixels-per-degree (every tile is built with the same span/size).
        let pxPerDegLon = Double(refTile.pixelSize.width) / refTile.region.span.longitudeDelta
        let pxPerDegLat = Double(refTile.pixelSize.height) / refTile.region.span.latitudeDelta

        // Anchor coordinate space on the user — they sit at the origin
        // after rotation; neighbouring tiles draw offset from that.
        let centerLon = fix.coordinate.longitude
        let centerLat = fix.coordinate.latitude

        ctx.saveGState()
        // Re-flip Y for the duration of this draw. The outer ctx has a
        // global Y-flip into math-convention coords (Y up), but tile
        // bitmaps and `ctx.draw(image, in:)` expect Y-down (UIKit).
        // Without this second flip the bitmaps render upside-down.
        ctx.translateBy(x: 0, y: frameSize.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.translateBy(x: frameSize.width / 2, y: frameSize.height / 2)
        // Heading-up: rotate by -heading (heading is deg cw from north;
        // CGContext rotates counter-clockwise in radians).
        // DEBUG: rotation disabled for diagnostic — verify position alignment
        // with map north-up before re-enabling heading rotation.
        // let theta = -lastHeading * .pi / 180
        // ctx.rotate(by: theta)

        // Draw every overlapping tile shifted by the delta from its
        // own centre to the user's position. Use `t.center` (the
        // requested centre — and the geographic centre of the
        // rendered image), not `t.region.center`. MKMapSnapshotter
        // can adjust the region span but the centre stays put.
        // In Y-down coords (after the second flip), north = -y, so a
        // tile whose centre is north of the user (t.lat > user.lat)
        // lands at NEGATIVE dy = upper part of the frame. ✓
        for (t, cg) in tilesToDraw {
            let dx = (t.center.longitude - centerLon) * pxPerDegLon
            let dy = (centerLat - t.center.latitude) * pxPerDegLat
            let tw = t.pixelSize.width
            let th = t.pixelSize.height
            ctx.draw(cg, in: CGRect(x: CGFloat(dx) - tw / 2,
                                    y: CGFloat(dy) - th / 2,
                                    width: tw, height: th))
        }

        // Draw the route polyline in the same Y-down coordinate space.
        if !routePolylineCoords.isEmpty {
            ctx.setStrokeColor(CGColor(red: 0.0, green: 0.48, blue: 1.0, alpha: 0.85))
            ctx.setLineWidth(8)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.beginPath()
            var first = true
            for c in routePolylineCoords {
                let dx = (c.longitude - centerLon) * pxPerDegLon
                let dy = (centerLat - c.latitude) * pxPerDegLat
                let pt = CGPoint(x: CGFloat(dx), y: CGFloat(dy))
                if first {
                    ctx.move(to: pt)
                    first = false
                } else {
                    ctx.addLine(to: pt)
                }
            }
            ctx.strokePath()
        }

        ctx.restoreGState()

        // Draw user dot in the center (always upright — drawn after
        // restoreGState so heading rotation doesn't tilt it).
        let cx = frameSize.width / 2
        let cy = frameSize.height / 2
        // Re-flip Y just for the dot (we restored to ctx top-down state,
        // but the outer ctx is bottom-up; cy is fine in either since
        // it's the center).
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: cx - 9, y: cy - 9, width: 18, height: 18))
        ctx.setFillColor(CGColor(red: 0.0, green: 0.48, blue: 1.0, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: cx - 6, y: cy - 6, width: 12, height: 12))
    }

    /// Vector-only fallback: dark background + polyline + dot.
    /// Used when the tile cache is unavailable or the user has gone
    /// off the cached corridor.
    private func drawVectorOnlyFrame(into ctx: CGContext) {
        // Dark slate background
        ctx.setFillColor(CGColor(red: 0.10, green: 0.12, blue: 0.16, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: frameSize.width, height: frameSize.height))

        guard let fix = lastFix, !routePolylineCoords.isEmpty else {
            // Nothing useful to draw.
            return
        }

        // Use a constant scale: 1 m = 0.5 px → 526 px = ~1 km wide view.
        let metersPerPx: Double = 2.0
        let centerLat = fix.coordinate.latitude
        let centerLon = fix.coordinate.longitude
        let mPerDegLat = 111_320.0
        let mPerDegLon = 111_320.0 * cos(centerLat * .pi / 180)

        ctx.saveGState()
        ctx.translateBy(x: 0, y: frameSize.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.translateBy(x: frameSize.width / 2, y: frameSize.height / 2)
        ctx.rotate(by: -lastHeading * .pi / 180)

        ctx.setStrokeColor(CGColor(red: 0.0, green: 0.78, blue: 1.0, alpha: 0.95))
        ctx.setLineWidth(6)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.beginPath()
        var first = true
        for c in routePolylineCoords {
            let dxM = (c.longitude - centerLon) * mPerDegLon
            let dyM = (centerLat - c.latitude) * mPerDegLat
            let pt = CGPoint(x: CGFloat(dxM / metersPerPx), y: CGFloat(dyM / metersPerPx))
            if first {
                ctx.move(to: pt)
                first = false
            } else {
                ctx.addLine(to: pt)
            }
        }
        ctx.strokePath()
        ctx.restoreGState()

        // Dot in the center.
        let cx = frameSize.width / 2
        let cy = frameSize.height / 2
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: cx - 9, y: cy - 9, width: 18, height: 18))
        ctx.setFillColor(CGColor(red: 0.0, green: 0.48, blue: 1.0, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: cx - 6, y: cy - 6, width: 12, height: 12))
    }

    private func preparePool() {
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(frameSize.width),
            kCVPixelBufferHeightKey as String: Int(frameSize.height),
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ]
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
        pixelBufferPool = pool
    }
}

// MARK: - Route rendering

extension MapViewSource {
    func setRoutePolyline(_ polyline: MKPolyline?) {
        if let existing = routePolyline {
            mapView.removeOverlay(existing)
        }
        routePolyline = polyline
        if let polyline {
            mapView.addOverlay(polyline, level: .aboveRoads)
            // Cache coords for the BG composite path.
            let n = polyline.pointCount
            let pts = polyline.points()
            var coords: [CLLocationCoordinate2D] = []
            coords.reserveCapacity(n)
            for i in 0..<n { coords.append(pts[i].coordinate) }
            routePolylineCoords = coords
        } else {
            routePolylineCoords = []
        }
    }
}

// MARK: - MKMapViewDelegate

extension MapViewSource: MKMapViewDelegate {
    nonisolated func mapView(_: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
        if let polyline = overlay as? MKPolyline {
            let r = MKPolylineRenderer(polyline: polyline)
            r.strokeColor = UIColor.systemBlue.withAlphaComponent(0.85)
            r.lineWidth = 6
            r.lineCap = .round
            r.lineJoin = .round
            return r
        }
        return MKOverlayRenderer(overlay: overlay)
    }
}

// MARK: - SwiftUI host

import SwiftUI

struct MapViewHost: UIViewRepresentable {
    let source: MapViewSource

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.clipsToBounds = true
        container.backgroundColor = .black
        container.addSubview(source.hostView)
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        let mapView = source.hostView
        let native = source.frameSize
        let bounds = container.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }
        guard mapView.superview === container else { return }

        mapView.transform = .identity
        mapView.translatesAutoresizingMaskIntoConstraints = true
        mapView.frame = CGRect(origin: .zero, size: native)
        let scale = min(bounds.width / native.width, bounds.height / native.height)
        mapView.transform = CGAffineTransform(scaleX: scale, y: scale)
        mapView.center = CGPoint(x: bounds.midX, y: bounds.midY)
    }
}
