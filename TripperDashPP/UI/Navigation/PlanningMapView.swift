//
//  PlanningMapView.swift
//  TripperDashPP
//
//  feat/route-waypoints — the interactive planning map.
//
//  Shows the whole multi-stop plan on one MKMapView (lives only in the
//  picker's .picking phase, stream OFF — so it never races the
//  MapViewSource snapshotter for Apple's shared GPU pool):
//
//   - every waypoint as a numbered pin (origin / via-N / destination),
//   - for each leg, the selected option as a thick blue line and the
//     alternatives as thin gray lines,
//   - tap a gray alternative -> onPickAlternative(leg, option),
//   - tap a waypoint pin     -> onTapWaypoint(id),
//   - long-press empty map   -> onAddWaypoint(coord).
//
//  Overlay sync mirrors RoutePreviewMap: MapKit caches renderers per
//  overlay, so selection changes remove + re-add overlays (selected
//  last, so it draws on top). Teardown is hardened through the shared
//  MapViewPark (see InteractiveMapView) to avoid the MTLDebugDevice
//  drain assertion on view dismantle.
//

import CoreLocation
import MapKit
import SwiftUI

struct PlanningMapView: UIViewRepresentable {
    /// Live plan. Read for geometry; never mutated here (callbacks ask
    /// the owner to mutate, keeping a single write path).
    var plan: PlannedRoute

    var onPickAlternative: (_ legIndex: Int, _ optionIndex: Int) -> Void
    var onAddWaypoint: (_ coord: CLLocationCoordinate2D) -> Void
    var onTapWaypoint: (_ waypointId: UUID) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView(frame: .zero)
        map.delegate = context.coordinator
        map.showsUserLocation = true
        // Keep the user-location puck the default Apple blue regardless of
        // the app accent colour (explicit product requirement).
        map.tintColor = .systemBlue
        map.showsCompass = true
        map.isRotateEnabled = false   // planning is north-up
        map.isPitchEnabled = false
        if #available(iOS 16.0, *) {
            map.preferredConfiguration = MKStandardMapConfiguration(
                elevationStyle: .flat,
                emphasisStyle: .default
            )
        }
        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handleTap(_:)))
        tap.delegate = context.coordinator
        map.addGestureRecognizer(tap)

        let longPress = UILongPressGestureRecognizer(target: context.coordinator,
                                                     action: #selector(Coordinator.handleLongPress(_:)))
        longPress.minimumPressDuration = 0.45
        longPress.delegate = context.coordinator
        map.addGestureRecognizer(longPress)

        context.coordinator.mapView = map
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.syncWaypointPins(on: map)
        context.coordinator.syncLegOverlays(on: map)
        context.coordinator.fitIfNeeded(on: map)
    }

    static func dismantleUIView(_ map: MKMapView, coordinator: Coordinator) {
        MapViewPark.shared.park(map)
    }

    // MARK: - Annotations

    /// Waypoint pin tagged with its id + ordinal so taps map back and
    /// the marker can render its number/role.
    final class WaypointAnnotation: NSObject, MKAnnotation {
        @objc dynamic var coordinate: CLLocationCoordinate2D
        let waypointId: UUID
        let ordinal: Int        // 0 = origin
        let total: Int
        var title: String?

        init(waypointId: UUID, ordinal: Int, total: Int, coordinate: CLLocationCoordinate2D, title: String?) {
            self.waypointId = waypointId
            self.ordinal = ordinal
            self.total = total
            self.coordinate = coordinate
            self.title = title
        }

        var isOrigin: Bool { ordinal == 0 }
        var isDestination: Bool { ordinal == total - 1 }
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate {
        var parent: PlanningMapView
        weak var mapView: MKMapView?
        private var didFit = false
        /// Signature of the last waypoint layout we fit to, so an
        /// add/remove/reorder re-fits but a mere selection change does
        /// not yank the camera.
        private var lastFitSignature: Int = 0

        init(_ parent: PlanningMapView) { self.parent = parent }

        // MARK: Sync — waypoint pins

        func syncWaypointPins(on map: MKMapView) {
            let wps = parent.plan.waypoints
            let existing = map.annotations.compactMap { $0 as? WaypointAnnotation }
            // Cheap diff: if ids+coords match in order, leave them.
            let sameCount = existing.count == wps.count
            let allMatch = sameCount && zip(
                existing.sorted { $0.ordinal < $1.ordinal }, wps
            ).allSatisfy { ann, wp in
                ann.waypointId == wp.id
                    && ann.coordinate.latitude == wp.coordinate.latitude
                    && ann.coordinate.longitude == wp.coordinate.longitude
            }
            guard !allMatch else { return }
            map.removeAnnotations(existing)
            let fresh = wps.enumerated().map { idx, wp in
                WaypointAnnotation(waypointId: wp.id,
                                   ordinal: idx,
                                   total: wps.count,
                                   coordinate: wp.coordinate,
                                   title: wp.name)
            }
            map.addAnnotations(fresh)
        }

        // MARK: Sync — leg overlays

        func syncLegOverlays(on map: MKMapView) {
            // Rebuild all leg polylines every update. There are at most
            // (legs × 3) of them and this only runs on plan changes /
            // selection taps, so the cost is trivial and it avoids the
            // renderer-cache staleness MapKit exhibits on in-place
            // mutation.
            let stale = map.overlays.compactMap { $0 as? RouteLegPolyline }
            map.removeOverlays(stale)

            var ordered: [RouteLegPolyline] = []
            for (legIndex, leg) in parent.plan.legs.enumerated() {
                for (optionIndex, option) in leg.options.enumerated() {
                    let coords = option.route.polyline.coordinateList()
                    let isSelected = optionIndex == leg.selectedOptionIndex
                    if let poly = RouteLegPolyline.make(coordinates: coords,
                                                        legIndex: legIndex,
                                                        optionIndex: optionIndex,
                                                        isSelected: isSelected) {
                        ordered.append(poly)
                    }
                }
            }
            // Add unselected first, selected last so they draw on top.
            for poly in ordered where !poly.isSelected {
                map.addOverlay(poly, level: .aboveRoads)
            }
            for poly in ordered where poly.isSelected {
                map.addOverlay(poly, level: .aboveRoads)
            }
        }

        // MARK: Initial / re-fit

        func fitIfNeeded(on map: MKMapView) {
            let sig = waypointSignature()
            guard !didFit || sig != lastFitSignature else { return }
            // Prefer the union of leg geometry; fall back to waypoint
            // coordinates before legs are computed.
            var rect = MKMapRect.null
            for leg in parent.plan.legs {
                if let sel = leg.selected {
                    rect = rect.union(sel.route.polyline.boundingMapRect)
                }
            }
            if rect.isNull {
                for wp in parent.plan.waypoints {
                    let p = MKMapPoint(wp.coordinate)
                    rect = rect.union(MKMapRect(x: p.x, y: p.y, width: 0, height: 0))
                }
            }
            guard !rect.isNull else { return }
            map.setVisibleMapRect(rect,
                                  edgePadding: UIEdgeInsets(top: 60, left: 40, bottom: 60, right: 40),
                                  animated: didFit)   // animate re-fits, snap the first
            didFit = true
            lastFitSignature = sig
        }

        private func waypointSignature() -> Int {
            var hasher = Hasher()
            for wp in parent.plan.waypoints { hasher.combine(wp.id) }
            return hasher.finalize()
        }

        // MARK: Renderers

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let poly = overlay as? RouteLegPolyline else {
                return MKOverlayRenderer(overlay: overlay)
            }
            let r = MKPolylineRenderer(polyline: poly)
            r.strokeColor = poly.isSelected
                ? UIColor.systemBlue
                : UIColor.systemGray.withAlphaComponent(0.7)
            r.lineWidth = poly.isSelected ? 7 : 4
            r.lineCap = .round
            r.lineJoin = .round
            return r
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: any MKAnnotation) -> MKAnnotationView? {
            if annotation is MKUserLocation { return nil }
            guard let wp = annotation as? WaypointAnnotation else { return nil }
            let id = "WaypointPin"
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: id) as? MKMarkerAnnotationView
                ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: id)
            view.annotation = annotation
            view.canShowCallout = true
            if wp.isOrigin {
                view.markerTintColor = .systemGreen
                view.glyphImage = UIImage(systemName: "location.fill")
            } else if wp.isDestination {
                view.markerTintColor = .systemRed
                view.glyphImage = UIImage(systemName: "flag.checkered")
            } else {
                view.markerTintColor = .systemBlue
                view.glyphText = "\(wp.ordinal)"
            }
            return view
        }

        // MARK: Gestures

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let map = gesture.view as? MKMapView, gesture.state == .ended else { return }
            let point = gesture.location(in: map)

            // Pin taps are handled by MKMapView selection (didSelect),
            // so only treat this as a route pick.
            let touchCoord = map.convert(point, toCoordinateFrom: map)
            let candidates = map.overlays.compactMap { $0 as? RouteLegPolyline }
            let metersPerPoint = map.metersPerScreenPoint(at: touchCoord.latitude)
            if let pick = pickLegOption(tap: touchCoord,
                                        candidates: candidates,
                                        metersPerPoint: metersPerPoint) {
                // Only act when picking a NON-selected alternative;
                // tapping the already-selected line is a no-op.
                let leg = parent.plan.legs.indices.contains(pick.legIndex) ? parent.plan.legs[pick.legIndex] : nil
                if let leg, pick.optionIndex != leg.selectedOptionIndex {
                    parent.onPickAlternative(pick.legIndex, pick.optionIndex)
                }
            }
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            guard let wp = view.annotation as? WaypointAnnotation else { return }
            // Deselect so a repeat tap fires again.
            mapView.deselectAnnotation(view.annotation, animated: false)
            parent.onTapWaypoint(wp.waypointId)
        }

        @objc func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
            guard gesture.state == .began, let map = gesture.view as? MKMapView else { return }
            let point = gesture.location(in: map)
            let coord = map.convert(point, toCoordinateFrom: map)
            parent.onAddWaypoint(coord)
        }

        // Let our tap/long-press coexist with the map's own gestures.
        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }
}
