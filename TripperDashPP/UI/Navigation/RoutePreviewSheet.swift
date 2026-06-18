//
//  RoutePreviewSheet.swift
//  TripperDashPP
//
//  Phase 7e+7g — full-screen sheet that shows up to 3 alternative
//  routes to the chosen destination on an interactive map (top half),
//  with selectable rows underneath (bottom). Tap a row OR a route on
//  the map → that route highlights, "Start navigation" CTA enables.
//
//  Why map-first: matches the Royal Enfield app's UX (and Apple Maps')
//  — riders need to SEE where the candidate routes go before committing.
//  Numeric ETA + distance alone isn't enough when the choice is between
//  e.g. fast-but-toll vs. scenic-via-D-roads.
//

import MapKit
import SwiftUI

struct RoutePreviewSheet: View {
    @Environment(AppStatus.self) private var status
    @Environment(NavigationStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let destination: Destination
    let onStart: (MKRoute, Destination) -> Void

    @State private var routes: [RouteOption] = []
    @State private var selected: RouteOption?
    @State private var loading: Bool = false
    @State private var loadError: String?

    private let router = RoutingService()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                RoutePreviewMap(
                    routes: routes,
                    selected: selected,
                    destination: destination.coordinate,
                    origin: status.locationService.lastFix?.coordinate,
                    onTapRoute: { opt in selected = opt }
                )
                .frame(maxHeight: .infinity)
                .overlay(alignment: .top) {
                    if loading {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Calculating routes…").font(.footnote)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.top, 8)
                    }
                    if let err = loadError {
                        Label(err, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(.regularMaterial, in: Capsule())
                            .padding(.top, 8)
                    }
                }

                Divider()

                // Bottom panel: destination header + route list + CTA.
                VStack(spacing: 0) {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "mappin.circle.fill")
                            .foregroundStyle(.red).font(.title3)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(destination.name).font(.subheadline.weight(.semibold))
                            if let addr = destination.addressLine {
                                Text(addr).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 16).padding(.vertical, 8)

                    if !routes.isEmpty {
                        Divider()
                        ScrollView {
                            VStack(spacing: 0) {
                                ForEach(routes) { opt in
                                    routeRow(opt)
                                        .padding(.horizontal, 16).padding(.vertical, 10)
                                        .background(opt == selected ? Color.accentColor.opacity(0.10) : .clear)
                                        .contentShape(Rectangle())
                                        .onTapGesture { selected = opt }
                                    Divider().padding(.leading, 44)
                                }
                            }
                        }
                        .frame(maxHeight: 220)
                    }

                    Button {
                        if let sel = selected {
                            onStart(sel.route, destination)
                            dismiss()
                        }
                    } label: {
                        Label("Start navigation", systemImage: "play.circle.fill")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(selected == nil)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                }
                .background(.regularMaterial)
            }
            .navigationTitle("Route preview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        RoutePreferencesView()
                            .environment(store)
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                }
            }
            .task { await calculate() }
        }
    }

    private func routeRow(_ opt: RouteOption) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: opt == selected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(opt == selected ? Color.accentColor : Color.secondary)
                .font(.title3)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(opt.label).font(.subheadline.weight(.semibold))
                    if !opt.summary.isEmpty {
                        Text(opt.summary).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 10) {
                    Label(opt.travelTimeDisplay, systemImage: "clock")
                    Label(opt.distanceDisplay, systemImage: "ruler")
                    Label(opt.arrivalDisplay, systemImage: "flag.checkered")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if !opt.advisoryNotices.isEmpty {
                    Text(opt.advisoryNotices.joined(separator: " · "))
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private func calculate() async {
        loading = true
        loadError = nil
        defer { loading = false }
        do {
            let origin = status.locationService.lastFix?.coordinate
            let opts = try await router.calculate(
                from: origin,
                to: destination,
                preferences: store.routePreferences
            )
            self.routes = opts
            self.selected = opts.first
        } catch {
            self.loadError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

// MARK: - Map with all 3 routes drawn (selected one thicker / coloured)

struct RoutePreviewMap: UIViewRepresentable {
    let routes: [RouteOption]
    let selected: RouteOption?
    let destination: CLLocationCoordinate2D
    let origin: CLLocationCoordinate2D?
    let onTapRoute: (RouteOption) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsUserLocation = true
        map.showsCompass = false
        map.isRotateEnabled = false
        map.isPitchEnabled = false
        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handleTap(_:)))
        tap.delegate = context.coordinator
        map.addGestureRecognizer(tap)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.parent = self

        // Sync overlays
        let desiredIds = Set(routes.map(\.id))
        let stalePolylines = map.overlays.compactMap { $0 as? RoutePolyline }
            .filter { !desiredIds.contains($0.routeId) }
        map.removeOverlays(stalePolylines)

        let existingIds = Set(map.overlays.compactMap { ($0 as? RoutePolyline)?.routeId })
        for opt in routes where !existingIds.contains(opt.id) {
            let poly = RoutePolyline(points: opt.route.polyline.points(),
                                     count: opt.route.polyline.pointCount)
            poly.routeId = opt.id
            map.addOverlay(poly, level: .aboveRoads)
        }

        // Re-render selected styling: MapKit caches renderers per
        // overlay, so re-add when selection changes to force colour
        // refresh. Cheaper than digging into renderer state.
        if context.coordinator.lastSelectedId != selected?.id {
            let polys = map.overlays.compactMap { $0 as? RoutePolyline }
            map.removeOverlays(polys)
            // Re-add with selected last so it draws on top.
            let sortedOpts = routes.sorted { l, _ in l.id != selected?.id }
            for opt in sortedOpts {
                let poly = RoutePolyline(points: opt.route.polyline.points(),
                                         count: opt.route.polyline.pointCount)
                poly.routeId = opt.id
                map.addOverlay(poly, level: .aboveRoads)
            }
            context.coordinator.lastSelectedId = selected?.id
        }

        // Sync destination annotation (keep stable, just update coord).
        if let pin = map.annotations.first(where: { $0 is DestinationPin }) as? DestinationPin {
            if pin.coordinate.latitude != destination.latitude
                || pin.coordinate.longitude != destination.longitude {
                pin.coordinate = destination
            }
        } else {
            let pin = DestinationPin()
            pin.coordinate = destination
            map.addAnnotation(pin)
        }

        // First fit: zoom to selected route or bounding rect of all.
        if !context.coordinator.didFitInitial, !routes.isEmpty {
            let rect = routes.map(\.route.polyline.boundingMapRect)
                .reduce(MKMapRect.null) { $0.union($1) }
            if !rect.isNull {
                map.setVisibleMapRect(rect,
                                      edgePadding: UIEdgeInsets(top: 60, left: 40, bottom: 60, right: 40),
                                      animated: false)
                context.coordinator.didFitInitial = true
            }
        }
    }

    // MARK: - Helpers

    /// Subclass so we can correlate the polyline back to its RouteOption.
    final class RoutePolyline: MKPolyline {
        var routeId: UUID = UUID()
    }

    final class DestinationPin: NSObject, MKAnnotation {
        @objc dynamic var coordinate: CLLocationCoordinate2D = .init()
        var title: String? { "Destination" }
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate {
        var parent: RoutePreviewMap
        var didFitInitial = false
        var lastSelectedId: UUID?

        init(_ parent: RoutePreviewMap) { self.parent = parent }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let poly = overlay as? RoutePolyline else {
                return MKOverlayRenderer(overlay: overlay)
            }
            let r = MKPolylineRenderer(polyline: poly)
            let isSelected = (poly.routeId == parent.selected?.id)
            r.strokeColor = isSelected
                ? UIColor.systemBlue
                : UIColor.systemGray.withAlphaComponent(0.7)
            r.lineWidth = isSelected ? 7 : 4
            r.lineCap = .round
            r.lineJoin = .round
            return r
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard annotation is DestinationPin else { return nil }
            let id = "DestPin"
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: id)
                ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: id)
            (view as? MKMarkerAnnotationView)?.markerTintColor = .systemRed
            (view as? MKMarkerAnnotationView)?.glyphImage = UIImage(systemName: "mappin")
            view.canShowCallout = false
            return view
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let map = gesture.view as? MKMapView else { return }
            let point = gesture.location(in: map)
            let touch = map.convert(point, toCoordinateFrom: map)
            // Find the polyline whose nearest vertex is closest to the
            // tap. Cheap & good-enough: we'd want a real "hit-test on
            // rendered line" but for picking between 3 routes the
            // vertex distance heuristic works fine at any zoom.
            var best: (id: UUID, dist: CLLocationDistance)?
            for overlay in map.overlays {
                guard let poly = overlay as? RoutePolyline else { continue }
                let coords = poly.coordinates()
                let touchLoc = CLLocation(latitude: touch.latitude, longitude: touch.longitude)
                if let nearest = coords.map({ CLLocation(latitude: $0.latitude, longitude: $0.longitude)
                                                .distance(from: touchLoc) }).min() {
                    if best == nil || nearest < best!.dist {
                        best = (poly.routeId, nearest)
                    }
                }
            }
            guard let pick = best else { return }
            // Threshold: ~ a 30 m-on-the-ground radius at the current
            // zoom. Convert by sampling 1 pixel = ? meters via
            // metersPerMapPoint at the touch point.
            let pointsPerMeter = MKMapPointsPerMeterAtLatitude(touch.latitude)
            let onePixelInMeters = (1.0 / pointsPerMeter) * Double(map.visibleMapRect.size.width / Double(map.bounds.width))
            let thresholdMeters = max(30.0, onePixelInMeters * 22)  // ~22px tolerance
            if pick.dist <= thresholdMeters,
               let opt = parent.routes.first(where: { $0.id == pick.id }) {
                parent.onTapRoute(opt)
            }
        }

        // Allow tap to coexist with map's own pan/zoom recognizers.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }
}

private extension MKPolyline {
    func coordinates() -> [CLLocationCoordinate2D] {
        var coords = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid,
                                              count: pointCount)
        getCoordinates(&coords, range: NSRange(location: 0, length: pointCount))
        return coords
    }
}

// MARK: - Preferences sub-view

struct RoutePreferencesView: View {
    @Environment(NavigationStore.self) private var store

    var body: some View {
        Form {
            Section("Route preferences") {
                Toggle("Avoid highways", isOn: Binding(
                    get: { store.settings.avoidHighways },
                    set: { store.setAvoidHighways($0) }
                ))
                Toggle("Avoid tolls", isOn: Binding(
                    get: { store.settings.avoidTolls },
                    set: { store.setAvoidTolls($0) }
                ))
                Text("Apple's MKDirections returns the best matches Apple Maps would for a car. Czech Republic toll preference applies to D-roads where stamped vignettes are required.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Preferences")
        .navigationBarTitleDisplayMode(.inline)
    }
}
