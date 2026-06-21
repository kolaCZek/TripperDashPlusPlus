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
//  Capabilities:
//   - single-tap → drop pin → `onTapPin(coord)` callback
//   - destination pin annotation rendered as a red flag.checkered
//   - route polyline overlay rendered as a fat blue stroke
//

import MapKit
import SwiftUI

struct InteractiveMapView: UIViewRepresentable {
    /// Center coordinate. Only consulted when `followsUser == false`.
    /// When followsUser is true, MKMapView's own user tracking handles
    /// the camera.
    var coordinate: CLLocationCoordinate2D?

    /// When true, MKMapView locks the camera to the user puck and
    /// rotates with heading. When false, we manage center via
    /// `coordinate`.
    var followsUser: Bool = true

    /// When set, render a red marker at this coordinate (typically the
    /// active destination pin).
    var destinationPin: CLLocationCoordinate2D?

    /// When set, render this polyline as the active/preview route.
    var routePolyline: MKPolyline?

    /// Fires when the user single-taps the map. Coordinate is mapped
    /// from the touch location. Caller decides whether to drop a pin
    /// or open a search.
    var onTapPin: ((CLLocationCoordinate2D) -> Void)?

    func makeUIView(context: Context) -> MKMapView {
        let mv = MKMapView(frame: .zero)
        mv.delegate = context.coordinator
        mv.showsUserLocation = true
        mv.showsCompass = true
        mv.showsScale = false
        mv.isRotateEnabled = true
        mv.isPitchEnabled = false  // 2D only, simpler tap → coord mapping
        if followsUser {
            mv.setUserTrackingMode(.followWithHeading, animated: false)
        }
        if #available(iOS 16.0, *) {
            mv.preferredConfiguration = MKStandardMapConfiguration(
                elevationStyle: .flat,
                emphasisStyle: .default
            )
        }
        // Tap gesture for drop-pin.
        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handleTap(_:)))
        tap.delegate = context.coordinator
        mv.addGestureRecognizer(tap)
        context.coordinator.mapView = mv
        context.coordinator.onTapPin = onTapPin
        return mv
    }

    func updateUIView(_ mv: MKMapView, context: Context) {
        context.coordinator.onTapPin = onTapPin

        // Tracking sync
        if followsUser, mv.userTrackingMode == .none {
            mv.setUserTrackingMode(.followWithHeading, animated: true)
        }
        if !followsUser, let coord = coordinate {
            mv.setCenter(coord, animated: true)
        }

        // Destination pin sync — single annotation, remove + add on
        // change rather than diffing.
        let existing = mv.annotations.compactMap { $0 as? DestinationAnnotation }
        if let dest = destinationPin {
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

    final class Coordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate {
        weak var mapView: MKMapView?
        var onTapPin: ((CLLocationCoordinate2D) -> Void)?

        @objc func handleTap(_ gr: UITapGestureRecognizer) {
            guard let mv = mapView, gr.state == .ended else { return }
            let point = gr.location(in: mv)
            let coord = mv.convert(point, toCoordinateFrom: mv)
            onTapPin?(coord)
        }

        /// Don't swallow MKMapView's own gestures (zoom/pan/long-press
        /// for default Apple Maps tools). Letting both fire means the
        /// user can still pinch-zoom even while our single-tap is
        /// active.
        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
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
            if annotation is MKUserLocation { return nil }
            if annotation is DestinationAnnotation {
                let id = "DestinationPin"
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: id) as? MKMarkerAnnotationView
                    ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: id)
                view.annotation = annotation
                view.markerTintColor = .systemRed
                view.glyphImage = UIImage(systemName: "flag.checkered")
                view.canShowCallout = true
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
