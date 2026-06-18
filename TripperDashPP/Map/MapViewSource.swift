//
//  MapViewSource.swift
//  TripperDashPP
//
//  Phase 8b — Live MKMapView as a frame source.
//
//  Why this exists:
//  ----------------
//  MKMapSnapshotter (used by MapSnapshotSource) is throttled in
//  .background state — that's the freeze we kept hitting even with
//  PiP active. MKMapView is a *continuous* map renderer; as long as
//  it's mounted in a visible view hierarchy, MapKit keeps its tile
//  fetcher + Metal pipeline alive. PiP keeps our PiPHostView in the
//  "visible" hierarchy from iOS's perspective even with the screen
//  locked, so a MKMapView mounted inside PiPHostView's container
//  should keep rendering.
//
//  How frames make it to the encoder:
//  ----------------------------------
//  We don't snapshot through MKMapSnapshotter at all. Instead, on
//  each tick (6 fps DispatchSourceTimer) we call
//  `mapView.layer.render(in: cgContext)` against an in-memory
//  CGContext, then wrap that pixel buffer into a CVPixelBuffer and
//  emit it to the encoder. `layer.render(in:)` is synchronous,
//  CPU-side, and doesn't depend on the GPU presentation pipeline —
//  whatever the layer last drew is what we get. As long as MapKit
//  is updating its layer (which requires a visible view), the
//  output stays live.
//
//  Overlays:
//  ---------
//  Native MKMapView overlays (route polyline as MKPolyline +
//  MKPolylineRenderer, user puck via mapView.showsUserLocation,
//  maneuver chevron via MKPointAnnotation) — they render inline,
//  no post-compositing required.
//
//  Output size:
//  ------------
//  We size the underlying MKMapView at 526×300 (the dash native
//  resolution). The PiPHostView's UIView container may render it at
//  a smaller on-screen size (90×54 thumbnail in the corner of the
//  HUD), but layer.render(in:) always grabs the layer's intrinsic
//  size. PiP shows it scaled to fit the thumbnail; the stream goes
//  out at 526×300.
//

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

    private let queue = DispatchQueue(label: "TripperDashPP.MapViewSource", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var frameIndex: UInt64 = 0
    private var onFrame: ((CVPixelBuffer, CMTime) -> Void)?

    private var pixelBufferPool: CVPixelBufferPool?
    private var routePolyline: MKPolyline?

    init(locationService: LocationService, activeNavigator: ActiveNavigator) {
        self.locationService = locationService
        self.activeNavigator = activeNavigator
        super.init()
        configureMapView()
    }

    deinit {
        // stop() is @MainActor, can't call from deinit. UI teardown
        // is fast and ARC will release the MKMapView.
    }

    /// The live MKMapView. Mount this in your PiP host view so the
    /// system keeps MapKit's render loop alive.
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
        timer?.cancel()
        timer = nil
        if let service = locationService, let token = locationToken {
            service.stop(token: token)
        }
        locationToken = nil
        fixSubscription = nil
        headingSubscription = nil
        onFrame = nil
        log.info("MapViewSource stopped after \(self.frameIndex) frames")
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
        // userTrackingMode = .followWithHeading already rotates the
        // map for us, but we update camera heading explicitly for
        // smoother motion.
        let cam = mapView.camera.copy() as! MKMapCamera
        cam.heading = heading.trueHeading
        mapView.setCamera(cam, animated: false)
    }
}

// MARK: - Render tick

extension MapViewSource {
    private func startTimer() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        let interval = DispatchTimeInterval.milliseconds(1000 / targetFps)
        t.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(20))
        t.setEventHandler { [weak self] in
            Task { @MainActor in self?.tick() }
        }
        timer = t
        t.resume()
    }

    private func tick() {
        guard onFrame != nil else { return }
        guard let buffer = renderMapViewToPixelBuffer() else { return }
        let pts = CMTime(value: CMTimeValue(frameIndex), timescale: CMTimeScale(targetFps))
        frameIndex &+= 1
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
        // BGRA on iOS, premultiplied first = native CALayer format
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

        // CALayer coordinate system is flipped vs Core Graphics — MapKit
        // draws "right-side up" when we don't flip; if we did flip the
        // user marker would go upside-down. Render straight.
        mapView.layer.render(in: ctx)

        return buffer
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

/// Mounts a MapViewSource's live MKMapView in the SwiftUI hierarchy.
/// The MKMapView is owned by the source; we just give it a slot in
/// the view tree so MapKit's renderer stays awake.
struct MapViewHost: UIViewRepresentable {
    let source: MapViewSource

    func makeUIView(context: Context) -> MKMapView {
        return source.hostView
    }

    func updateUIView(_: MKMapView, context: Context) {
        // Source manages its own region/heading/overlays.
    }
}
