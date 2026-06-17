//
//  InteractiveMapView.swift
//  TripperDashPP
//
//  Phase 7a — live interactive MKMapView wrapped in UIViewRepresentable
//  with hardened teardown so we don't repeat the SwiftUI `Map(position:)`
//  crash that forced us to fall back to MapPreviewView in Phase 5.
//
//  Why this exists: SwiftUI's `Map` view wraps MKMapView with lifecycle
//  semantics we don't control. On NavigationStack pop, SwiftUI dealloc's
//  the MKMapView while its CAMetalLayer command buffer is still draining,
//  triggering MTLDebugDevice assertion + app freeze. Symptom log line
//  right before crash: `CAMetalLayer ignoring invalid setDrawableSize
//  width=0.000000 height=0.000000` = MKMapView going to zero size
//  mid-teardown while still rendering.
//
//  This wrapper:
//   1. Owns the MKMapView lifecycle ourselves via UIViewRepresentable
//   2. Hardens `dismantleUIView(_:coordinator:)` to:
//      - Cut off the delegate (no further callbacks during teardown)
//      - Turn off showsUserLocation (kills its CoreLocation+Metal path)
//      - Remove annotations/overlays (they hold Metal resources)
//      - removeFromSuperview() so UIKit stops asking it to draw
//      - Park the view in `MapViewPark` for natural retention until
//        pushed out by 9 newer ones (same pattern as SnapshotterPark
//        in MapSnapshotSource — see references/ios-map-renderer.md)
//
//  For Phase 7b (destination picking) we'll add a tap-to-drop-pin
//  gesture + `selectedDestination` binding + polyline overlay support
//  to this same view. Right now it just shows a live, GPS-following
//  map — replaces the 1 Hz UIImage in MapPreviewView for MapPicker.
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

    func makeUIView(context: Context) -> MKMapView {
        let mv = MKMapView(frame: .zero)
        mv.delegate = context.coordinator
        mv.showsUserLocation = true
        mv.showsCompass = true
        mv.showsScale = false
        mv.isRotateEnabled = true
        mv.isPitchEnabled = false  // 2D only, simpler tap → coord mapping later
        if followsUser {
            mv.setUserTrackingMode(.followWithHeading, animated: false)
        }
        // Match the streaming-path snapshot style for visual consistency
        // between picker and dash.
        if #available(iOS 16.0, *) {
            mv.preferredConfiguration = MKStandardMapConfiguration(
                elevationStyle: .flat,
                emphasisStyle: .default
            )
        }
        return mv
    }

    func updateUIView(_ mv: MKMapView, context: Context) {
        // Re-sync user-tracking mode if it diverged (e.g. user dragged
        // the map → MKMapView dropped tracking automatically).
        if followsUser, mv.userTrackingMode == .none {
            mv.setUserTrackingMode(.followWithHeading, animated: true)
        }
        if !followsUser, let coord = coordinate {
            mv.setCenter(coord, animated: true)
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

    final class Coordinator: NSObject, MKMapViewDelegate {
        // Phase 7b will populate this with:
        //   - mapView(_:rendererFor:) for route polyline styling
        //   - mapView(_:viewFor:) for destination pin styling
        //   - tap gesture handler that converts touch point → coordinate
        //     and exposes it via a @Binding selectedDestination
    }
}

// MARK: - MapViewPark

/// Holds MKMapView instances alive after SwiftUI hands them back to us
/// via `dismantleUIView`, so the underlying CAMetalLayer command buffer
/// has time to drain on the GPU before the view (and its Metal
/// resources) get dealloc'd.
///
/// Pattern parallels `SnapshotterPark` in MapSnapshotSource.swift — same
/// MTLDebugDevice assertion problem, same bounded-LIFO-ring solution.
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

    /// Harden the view's teardown state, then park it. The hardening
    /// cuts off ongoing Metal work submissions; the parking keeps
    /// already-submitted command buffers from racing ARC release.
    ///
    /// Order matters:
    ///   1. delegate = nil           → stop receiving callbacks first
    ///   2. showsUserLocation = false → kill the user location render
    ///                                  path (its own Metal layer)
    ///   3. removeAnnotations         → drop annotation views (own
    ///   4. removeOverlays            → drop overlay renderers
    ///                                  Metal textures + CBs each)
    ///   5. removeFromSuperview       → UIKit stops asking it to draw;
    ///                                  must come before the park step
    ///                                  or the still-attached view keeps
    ///                                  submitting CBs.
    ///   6. ring.append               → retain for grace period
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
