//
//  InteractiveMapView.swift
//  TripperDashPP
//
//  Live interactive MKMapView wrapped in UIViewRepresentable with
//  hardened teardown.
//
//  Why a UIViewRepresentable instead of SwiftUI's `Map`: SwiftUI's
//  `Map` view wraps MKMapView with lifecycle semantics we don't
//  control. On NavigationStack pop, SwiftUI dealloc's the MKMapView
//  while its CAMetalLayer command buffer is still draining, triggering
//  an MTLDebugDevice assertion and a hard app freeze. Symptom log line
//  right before the crash: `CAMetalLayer ignoring invalid setDrawableSize
//  width=0.000000 height=0.000000` — MKMapView going to zero size
//  mid-teardown while still rendering. Wrapping the raw UIKit view
//  lets us route dismantle through `MapViewPark` (bottom of file),
//  which keeps the view alive long enough for the GPU command buffer
//  to drain before ARC frees the Metal resources.
//
//  Camera model (picker home map — June 2026 redesign):
//   - ALWAYS north-up. Rotation is disabled (`isRotateEnabled = false`)
//     and we never enter a heading-tracking mode, so the map can't spin.
//   - The camera does NOT follow the user. On the FIRST GPS fix we
//     center once (`didInitialCenter`); after that the camera stays
//     exactly where the rider left it — panning never snaps back.
//   - Recentering is explicit only: a `MapFocusRequest` (issued by the
//     recenter FAB, a search pick, or a favorite tap) animates the
//     camera to a coordinate. Each request carries a UUID so repeated
//     focuses on the same coordinate still fire.
//   - `onRecenterVisibilityChange` reports whether the user puck has
//     drifted out of the central region, so the parent can show/hide
//     the "center on me" button.
//
//  Capabilities:
//   - single-tap → drop pin → `onTap(coord)` callback
//   - selected pin annotation rendered as a red mappin marker.
//   - route polyline overlay rendered as a fat blue stroke
//

import MapKit
import SwiftUI

/// One-shot request to animate the camera to a coordinate. The `id`
/// makes each request unique so issuing the same coordinate twice (e.g.
/// tapping the recenter button repeatedly) still moves the camera.
struct MapFocusRequest: Equatable {
    let id: UUID
    var coordinate: CLLocationCoordinate2D

    init(coordinate: CLLocationCoordinate2D) {
        self.id = UUID()
        self.coordinate = coordinate
    }

    static func == (l: MapFocusRequest, r: MapFocusRequest) -> Bool { l.id == r.id }
}

struct InteractiveMapView: UIViewRepresentable {
    /// Latest GPS fix. Drives the one-shot initial center and the
    /// recenter-visibility computation. The camera never follows it.
    var userCoordinate: CLLocationCoordinate2D?

    /// When set, render a red marker at this coordinate (the currently
    /// selected destination / dropped pin). nil removes the marker.
    var selectedPin: CLLocationCoordinate2D?

    /// When this changes to a new request, animate the camera to its
    /// coordinate (keeping the current zoom). Used by the recenter FAB,
    /// search picks, and favorite taps.
    var focusRequest: MapFocusRequest?

    /// When set, render this polyline as the active/preview route.
    var routePolyline: MKPolyline?

    /// Device heading in degrees clockwise from true north (-1 / nil =
    /// unknown). Drives the rotation of the heading cone under the user
    /// puck. Because the map is north-up, this maps 1:1 to on-screen
    /// rotation.
    var userHeading: CLLocationDirection?

    /// Fires when the user single-taps the map. Coordinate is mapped
    /// from the touch location. Caller decides whether to drop a pin
    /// or open a search.
    var onTap: ((CLLocationCoordinate2D) -> Void)?

    /// Reports whether the recenter button should be shown — i.e. there
    /// is a known user location AND it has drifted out of the central
    /// region of the viewport. Only called when the value changes.
    var onRecenterVisibilityChange: ((Bool) -> Void)?

    func makeUIView(context: Context) -> MKMapView {
        let mv = MKMapView(frame: .zero)
        mv.delegate = context.coordinator
        mv.showsUserLocation = true
        // Keep the user-location puck the default Apple blue regardless of
        // the app accent colour (explicit product requirement: the map dot
        // must always read as the system blue, even if the accent changes).
        mv.tintColor = .systemBlue
        // North-up forever: no rotation, so the compass is meaningless.
        mv.showsCompass = false
        mv.showsScale = false
        mv.isRotateEnabled = false
        mv.isPitchEnabled = false  // 2D only, simpler tap → coord mapping
        // Deliberately NO userTrackingMode: the camera must not follow or
        // rotate with the user. We manage centering ourselves (one-shot
        // initial center + explicit focus requests).
        mv.userTrackingMode = .none
        if #available(iOS 16.0, *) {
            mv.preferredConfiguration = MKStandardMapConfiguration(
                elevationStyle: .flat,
                emphasisStyle: .default
            )
        }
        // Seed the initial region from a known fix so we don't flash the
        // whole world before the first center.
        if let coord = userCoordinate {
            mv.setRegion(MKCoordinateRegion(center: coord,
                                            latitudinalMeters: 3000,
                                            longitudinalMeters: 3000),
                         animated: false)
            context.coordinator.didInitialCenter = true
        }
        // Tap gesture for drop-pin.
        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handleTap(_:)))
        tap.delegate = context.coordinator
        mv.addGestureRecognizer(tap)
        context.coordinator.mapView = mv
        context.coordinator.onTap = onTap
        context.coordinator.onRecenterVisibilityChange = onRecenterVisibilityChange
        context.coordinator.userCoordinate = userCoordinate
        return mv
    }

    func updateUIView(_ mv: MKMapView, context: Context) {
        let coord = context.coordinator
        coord.onTap = onTap
        coord.onRecenterVisibilityChange = onRecenterVisibilityChange
        coord.userCoordinate = userCoordinate

        // One-shot initial center: first time we have a fix and the rider
        // hasn't picked anything yet, frame the user. Never again after.
        if !coord.didInitialCenter,
           focusRequest == nil,
           selectedPin == nil,
           let c = userCoordinate {
            mv.setRegion(MKCoordinateRegion(center: c,
                                            latitudinalMeters: 3000,
                                            longitudinalMeters: 3000),
                         animated: false)
            coord.didInitialCenter = true
        }

        // Explicit focus request → animate to coordinate (keep zoom).
        if let req = focusRequest, req.id != coord.lastFocusId {
            coord.lastFocusId = req.id
            coord.didInitialCenter = true   // an explicit move counts as "framed"
            mv.setCenter(req.coordinate, animated: true)
        }

        // Selected-pin sync — single annotation, remove + add on change
        // rather than diffing.
        let existing = mv.annotations.compactMap { $0 as? DestinationAnnotation }
        if let dest = selectedPin {
            let same = existing.first.map { $0.coordinate == dest } ?? false
            if !same {
                mv.removeAnnotations(existing)
                let pin = DestinationAnnotation()
                pin.coordinate = dest
                pin.title = "Destination"
                mv.addAnnotation(pin)
            }
        } else if !existing.isEmpty {
            mv.removeAnnotations(existing)
        }

        // Route polyline sync — single overlay.
        let existingOverlays = mv.overlays.compactMap { $0 as? MKPolyline }
        if let line = routePolyline {
            if existingOverlays.first !== line {
                mv.removeOverlays(existingOverlays)
                mv.addOverlay(line, level: .aboveRoads)
            }
        } else if !existingOverlays.isEmpty {
            mv.removeOverlays(existingOverlays)
        }

        // Recompute recenter-button visibility against the new fix.
        coord.recomputeRecenterVisibility()

        // Push the latest heading into the live puck (if it's on screen).
        coord.userHeading = userHeading
        coord.applyHeadingToPuck()
    }

    static func dismantleUIView(_ mv: MKMapView, coordinator: Coordinator) {
        // Park instead of letting ARC release immediately. See file
        // header comment for the full rationale. MapViewPark also
        // applies the teardown hardening (delegate = nil, etc.) so
        // there's a single source of truth for the dismantle sequence.
        MapViewPark.shared.park(mv)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    @MainActor
    final class Coordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate {
        weak var mapView: MKMapView?
        var onTap: ((CLLocationCoordinate2D) -> Void)?
        var onRecenterVisibilityChange: ((Bool) -> Void)?
        var userCoordinate: CLLocationCoordinate2D?
        /// Latest heading (deg clockwise from north), pushed into the
        /// puck view when it exists.
        var userHeading: CLLocationDirection?
        /// The live user-location puck, retained weakly so we can rotate
        /// its cone as fresh headings arrive without re-querying the map.
        weak var puckView: UserPuckAnnotationView?

        /// Set once we've framed the user on the first fix (or the rider
        /// has explicitly moved/focused the camera). Guards against the
        /// camera ever snapping back to the user on later GPS updates.
        var didInitialCenter = false
        /// Last honored focus request id, so we move the camera exactly
        /// once per request.
        var lastFocusId: UUID?
        /// Last reported recenter-button visibility, to avoid spamming the
        /// SwiftUI binding with no-op updates.
        private var lastRecenterVisible: Bool?

        @objc func handleTap(_ gr: UITapGestureRecognizer) {
            guard let mv = mapView, gr.state == .ended else { return }
            let point = gr.location(in: mv)
            let coord = mv.convert(point, toCoordinateFrom: mv)
            onTap?(coord)
        }

        /// Don't swallow MKMapView's own gestures (zoom/pan for the
        /// default Apple Maps tools). Letting both fire means the user can
        /// still pinch-zoom even while our single-tap is active.
        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }

        // MARK: - Recenter visibility

        /// The recenter button should appear when we know where the rider
        /// is but their puck has drifted out of the central region of the
        /// viewport (either because they panned away or they physically
        /// moved while the static north-up camera stayed put).
        ///
        /// The visibility callback is dispatched on the next main-actor
        /// tick (via `Task { @MainActor in … }`) rather than invoked
        /// inline: this method runs from `updateUIView`, and mutating
        /// SwiftUI `@State` synchronously during a view update logs a
        /// "Modifying state during view update" runtime warning. Bouncing
        /// to the next tick sidesteps that. Capturing `self` (a
        /// `@MainActor` class → implicitly Sendable) keeps it
        /// strict-concurrency clean — the non-Sendable closure is only
        /// touched inside the main-actor task, never across a hop.
        func recomputeRecenterVisibility() {
            let visible = computeRecenterVisible()
            guard visible != lastRecenterVisible else { return }
            lastRecenterVisible = visible
            Task { @MainActor in
                self.onRecenterVisibilityChange?(visible)
            }
        }

        private func computeRecenterVisible() -> Bool {
            guard let user = userCoordinate, let mv = mapView else { return false }
            let b = mv.bounds
            guard b.width > 0, b.height > 0 else { return false }
            let pt = mv.convert(user, toPointTo: mv)
            // Central region = bounds inset by 28% on each edge. If the
            // puck sits inside it, the rider is "centered enough" → hide.
            let central = b.insetBy(dx: b.width * 0.28, dy: b.height * 0.28)
            return !central.contains(pt)
        }

        // MARK: - Heading cone

        /// Push the current heading into the live puck view. No-op until
        /// the puck has been created (first user-location update).
        func applyHeadingToPuck() {
            puckView?.headingDegrees = userHeading
        }

        // MARK: - Delegate

        func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
            recomputeRecenterVisibility()
        }

        // MARK: - Renderers

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let line = overlay as? MKPolyline {
                let r = MKPolylineRenderer(polyline: line)
                r.strokeColor = UIColor.systemBlue.withAlphaComponent(0.85)
                r.lineWidth = 6
                r.lineCap = .round
                r.lineJoin = .round
                return r
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: any MKAnnotation) -> MKAnnotationView? {
            if annotation is MKUserLocation {
                // Custom puck so we can draw a heading cone on a north-up
                // map (MapKit only shows its own cone in followWithHeading,
                // which would rotate the whole map — not wanted here).
                let v = mapView.dequeueReusableAnnotationView(withIdentifier: UserPuckAnnotationView.reuseID)
                    as? UserPuckAnnotationView
                    ?? UserPuckAnnotationView(annotation: annotation,
                                              reuseIdentifier: UserPuckAnnotationView.reuseID)
                v.annotation = annotation
                v.headingDegrees = userHeading
                puckView = v
                return v
            }
            if annotation is DestinationAnnotation {
                let id = "DestinationPin"
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: id) as? MKMarkerAnnotationView
                    ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: id)
                view.annotation = annotation
                view.markerTintColor = .systemRed
                view.glyphImage = UIImage(systemName: "mappin")
                view.canShowCallout = false
                return view
            }
            return nil
        }
    }
}

/// Custom subclass so we can distinguish our destination pin from any
/// future annotations (traffic incidents, favorites overlay, etc.)
/// without dancing around `isKindOf` on MKPointAnnotation.
final class DestinationAnnotation: NSObject, MKAnnotation {
    dynamic var coordinate: CLLocationCoordinate2D = CLLocationCoordinate2D(latitude: 0, longitude: 0)
    var title: String?
    var subtitle: String?
}

// MARK: - MapViewPark

/// Holds MKMapView instances alive after SwiftUI hands them back to us
/// via `dismantleUIView`, so the underlying CAMetalLayer command buffer
/// has time to drain on the GPU before the view (and its Metal
/// resources) get dealloc'd.
///
/// Pattern parallels `SnapshotterPark` in Map/SnapshotterPark.swift —
/// same MTLDebugDevice assertion problem, same bounded-LIFO-ring
/// solution.
/// Capacity is much smaller here (10 vs 100) because MKMapView creation
/// is rare (once per picker appearance) and each view holds way more
/// memory than a snapshotter (~5–10 MB tile cache + Metal resources).
///
/// MUST run on @MainActor — MKMapView is not Sendable and all its APIs
/// require the main thread. SwiftUI calls dismantleUIView on the main
/// thread already, so this isolation is satisfied at the call site.
@MainActor
final class MapViewPark {
    static let shared = MapViewPark(capacity: 10)

    private let capacity: Int
    private var ring: [MKMapView] = []

    init(capacity: Int) {
        self.capacity = capacity
        self.ring.reserveCapacity(capacity + 1)
    }

    /// Harden the view's teardown state, then park it.
    func park(_ mv: MKMapView) {
        mv.delegate = nil
        mv.showsUserLocation = false
        if !mv.annotations.isEmpty {
            mv.removeAnnotations(mv.annotations)
        }
        if !mv.overlays.isEmpty {
            mv.removeOverlays(mv.overlays)
        }
        mv.removeFromSuperview()

        ring.append(mv)
        if ring.count > capacity {
            ring.removeFirst(ring.count - capacity)
        }
    }
}
