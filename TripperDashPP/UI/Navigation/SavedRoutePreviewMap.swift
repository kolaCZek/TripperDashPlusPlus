//
//  SavedRoutePreviewMap.swift
//  TripperDashPP
//
//  feat/saved-routes-gpx — a static thumbnail of a saved route's shape
//  for the detail screen.
//
//  Deliberately NOT a live MKMapView. The detail view lives inside the
//  Saved-routes sheet, which can be pushed/popped while the picker's own
//  MapPreviewView snapshotter and (when streaming) MapViewSource are also
//  competing for Apple's shared Metal pool. A live MKMapView here risks
//  the MTLDebugDevice drain assertion on dismiss — the exact failure
//  MapPreviewView was written to avoid. So we reuse that proven recipe:
//  render the route into a UIImage via MKMapSnapshotter, draw the
//  polyline + start/end pins on top in plain Core Graphics, and park the
//  snapshotter in SnapshotterPark so its command buffer drains safely.
//
//  Unlike MapPreviewView this is a ONE-SHOT snapshot (routes don't move),
//  re-taken only when the point set or the pixel size changes.
//

import CoreLocation
import MapKit
import SwiftUI

struct SavedRoutePreviewMap: View {
    /// Ordered navigable points of the route (already reduced for tracks).
    let points: [RoutePoint]

    @State private var image: UIImage?
    @State private var renderedKey: String?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    ZStack {
                        Color(.secondarySystemBackground)
                        ProgressView()
                    }
                }
            }
            .clipped()
            .onAppear { renderIfNeeded(size: geo.size) }
            .onChange(of: geo.size) { _, newSize in renderIfNeeded(size: newSize) }
            .onChange(of: colorScheme) { _, _ in
                renderedKey = nil
                renderIfNeeded(size: geo.size)
            }
        }
    }

    // MARK: - Rendering

    /// Re-render only when the inputs that affect pixels actually change
    /// (point identities + integer pixel size + colour scheme), so layout
    /// passes that re-emit the same size don't kick off redundant snapshots.
    private func renderIfNeeded(size: CGSize) {
        guard size.width >= 1, size.height >= 1, !points.isEmpty else { return }
        let key = "\(points.count)-\(points.first?.id.uuidString ?? "")-\(points.last?.id.uuidString ?? "")-\(Int(size.width))x\(Int(size.height))-\(colorScheme == .dark ? "d" : "l")"
        guard key != renderedKey else { return }
        renderedKey = key
        render(size: size)
    }

    private func render(size: CGSize) {
        let coords = points.map(\.coordinate)
        guard let span = GPXGeometry.boundingSpan(coords) else { return }

        let options = MKMapSnapshotter.Options()
        options.size = size
        options.scale = UIScreen.main.scale
        options.region = MKCoordinateRegion(
            center: span.center,
            span: MKCoordinateSpan(latitudeDelta: span.latDelta,
                                   longitudeDelta: span.lonDelta)
        )
        if #available(iOS 16.0, *) {
            options.preferredConfiguration = MKStandardMapConfiguration(
                elevationStyle: .flat, emphasisStyle: .default
            )
        }

        let isDark = colorScheme == .dark
        let snapshotter = MKMapSnapshotter(options: options)
        snapshotter.start(with: .main) { snap, _ in
            SnapshotterPark.shared.park(snapshotter)
            guard let snap else { return }
            image = drawRoute(on: snap, coords: coords, isDark: isDark)
        }
    }

    /// Draw the route polyline + start/end markers onto the basemap
    /// snapshot. Plain CG (no MKMapView), matching MapPreviewView's
    /// user-pin approach.
    private func drawRoute(on snap: MKMapSnapshotter.Snapshot,
                           coords: [CLLocationCoordinate2D],
                           isDark: Bool) -> UIImage {
        let base = snap.image
        let renderer = UIGraphicsImageRenderer(size: base.size)
        return renderer.image { ctx in
            base.draw(at: .zero)
            let cg = ctx.cgContext

            let pts = coords.map { snap.point(for: $0) }
            guard pts.count >= 1 else { return }

            // Route line — a casing stroke (white/black halo) under a blue
            // line so it reads on both light and dark basemaps.
            if pts.count >= 2 {
                let path = CGMutablePath()
                path.move(to: pts[0])
                for p in pts.dropFirst() { path.addLine(to: p) }

                cg.setLineJoin(.round)
                cg.setLineCap(.round)
                // Casing.
                cg.addPath(path)
                cg.setStrokeColor((isDark ? UIColor.black : UIColor.white)
                    .withAlphaComponent(0.85).cgColor)
                cg.setLineWidth(7)
                cg.strokePath()
                // Main line.
                cg.addPath(path)
                cg.setStrokeColor(UIColor.systemBlue.cgColor)
                cg.setLineWidth(4)
                cg.strokePath()
            }

            // Start (green) + end (red) dots. For a single-point route the
            // start dot alone is drawn.
            drawDot(cg, at: pts[0], fill: .systemGreen)
            if pts.count >= 2 {
                drawDot(cg, at: pts[pts.count - 1], fill: .systemRed)
            }
        }
    }

    private func drawDot(_ cg: CGContext, at p: CGPoint, fill: UIColor) {
        guard p.x.isFinite, p.y.isFinite else { return }
        cg.setFillColor(UIColor.white.cgColor)
        cg.fillEllipse(in: CGRect(x: p.x - 7, y: p.y - 7, width: 14, height: 14))
        cg.setFillColor(fill.cgColor)
        cg.fillEllipse(in: CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10))
    }
}
