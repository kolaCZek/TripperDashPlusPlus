//
//  RouteProgressMap.swift
//  TripperDashPP
//
//  feat/nav-route-overview-map — a static "progress bar" thumbnail shown
//  on the phone HUD during active navigation. Frames the WHOLE planned
//  route and overlays:
//    - the travelled trace (grey)   — where the rider has actually been
//    - the route ahead (blue)       — what's left to ride (post-reroute
//                                     this is the NEW line; the grey past
//                                     is kept, so the bar never loses its
//                                     covered start)
//    - start (green) / end (red) dots + a blue position puck for "you are
//      here".
//
//  Design mirrors `SavedRoutePreviewMap` (the editor's route thumbnail
//  the rider already knows) on purpose — same MKMapSnapshotter recipe,
//  same SnapshotterPark drain-safety, same plain-CoreGraphics overlay,
//  no live MKMapView (so no MTLDebugDevice drain assertion racing the
//  picker's snapshotter / the dash MapViewSource for Apple's shared
//  Metal pool).
//
//  The ONE difference that matters for a live HUD: the basemap snapshot
//  is taken ONCE per framing (an expensive GPU op) and cached, while the
//  grey/blue split + position puck — which move every GPS fix — are
//  redrawn in a cheap CPU CoreGraphics recomposite on top of that cached
//  basemap. The route frame is union(travelled, ahead) ≈ the full
//  original route, so it stays rock-stable fix-to-fix (the route's
//  extremes are preserved as the split point slides along it) and the
//  snapshot is only retaken on a reroute detour that grows the box.
//
//  Background safety: MKMapSnapshotter is GPU-bound and fails when the
//  app is backgrounded / the screen is locked. That's fine here — this
//  view is only on screen when the rider is actively looking at the
//  phone (foreground). When no basemap is ready yet it shows a
//  placeholder; the snapshot is (re)taken on the next appearance.
//

import CoreLocation
import MapKit
import SwiftUI

struct RouteProgressMap: View {
    /// Where the rider has actually been (thinned GPS breadcrumb).
    let traveled: [CLLocationCoordinate2D]
    /// The route still ahead (current route from the rider's position
    /// onward + any subsequent plan legs).
    let ahead: [CLLocationCoordinate2D]
    /// Current rider position — the "you are here" puck.
    let position: CLLocationCoordinate2D?

    /// Cached basemap snapshot. Holding the `Snapshot` (not just its
    /// UIImage) lets every recomposite re-project coordinates with
    /// `snap.point(for:)` without retaking the snapshot.
    @State private var snapshot: MKMapSnapshotter.Snapshot?
    /// The fully composited image actually shown (basemap + lines + dots).
    @State private var image: UIImage?
    /// Framing identity of the cached snapshot — re-snapshot only when
    /// this changes (size / colour scheme / a reroute that grew the box).
    @State private var framedKey: String?
    /// Guards against overlapping snapshot starts.
    @State private var isSnapshotting = false
    @Environment(\.colorScheme) private var colorScheme

    /// Cap on points drawn per polyline. A 150 pt thumbnail needs nowhere
    /// near a dense MKPolyline's thousands of vertices; striding down to
    /// this bounds the per-fix projection+stroke cost regardless of route
    /// length (a 300 km route and a 3 km route cost the same to draw).
    private let drawPointCap = 400

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
            .onAppear { update(size: geo.size) }
            .onChange(of: geo.size) { _, s in update(size: s) }
            .onChange(of: colorScheme) { _, _ in
                framedKey = nil          // force a fresh basemap snapshot
                update(size: geo.size)
            }
            // Position / line changes → cheap recomposite on the cached
            // basemap (no new snapshot). `position` is the per-fix driver;
            // `traveled.count` / `ahead.count` cover reroute + leg-advance
            // reshaping the lines without the position having moved yet.
            .onChange(of: positionKey) { _, _ in update(size: geo.size) }
            .onChange(of: traveled.count) { _, _ in update(size: geo.size) }
            .onChange(of: ahead.count) { _, _ in update(size: geo.size) }
        }
    }

    /// A cheap, change-detecting key for the rider position (CLLocation-
    /// Coordinate2D isn't Equatable). Rounded to ~1 m so sub-metre GPS
    /// jitter doesn't trigger pointless recomposites.
    private var positionKey: String {
        guard let p = position else { return "nil" }
        return "\(Int(p.latitude * 1e5)),\(Int(p.longitude * 1e5))"
    }

    // MARK: - Update pipeline

    /// Decide whether a fresh basemap snapshot is needed (framing changed)
    /// or the cached one can be reused for a cheap recomposite.
    private func update(size: CGSize) {
        guard size.width >= 1, size.height >= 1 else { return }
        // Frame the whole route: union of travelled + ahead. As the split
        // slides along the route this union stays ~constant (the route's
        // extremes are always present), so the key is stable and we don't
        // re-snapshot every fix.
        let framing = traveled + ahead
        guard let span = GPXGeometry.boundingSpan(framing) else { return }

        let key = framingKey(span: span, size: size)
        if key == framedKey, let snap = snapshot {
            // Same frame → just redraw the moving overlay (CPU only).
            image = composite(on: snap, size: size)
            return
        }
        // Framing changed (first run, resize, colour flip, reroute detour)
        // → take a new basemap snapshot, then composite.
        takeSnapshot(span: span, size: size, key: key)
    }

    private func framingKey(span: (center: CLLocationCoordinate2D, latDelta: Double, lonDelta: Double),
                            size: CGSize) -> String {
        // Round generously so floating jitter in the union bounds doesn't
        // bust the cache; a reroute that meaningfully grows the box still
        // changes these and forces a fresh snapshot.
        let c = "\(Int(span.center.latitude * 1e3)),\(Int(span.center.longitude * 1e3))"
        let d = "\(Int(span.latDelta * 1e3))x\(Int(span.lonDelta * 1e3))"
        let s = "\(Int(size.width))x\(Int(size.height))"
        return "\(c)|\(d)|\(s)|\(colorScheme == .dark ? "d" : "l")"
    }

    /// Take the basemap-only snapshot (no overlay baked in — the overlay
    /// moves every fix and is drawn in `composite`). Parks the snapshotter
    /// so its Metal command buffer drains safely, exactly like
    /// SavedRoutePreviewMap / MapPreviewView.
    private func takeSnapshot(span: (center: CLLocationCoordinate2D, latDelta: Double, lonDelta: Double),
                              size: CGSize, key: String) {
        guard !isSnapshotting else { return }
        isSnapshotting = true

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

        let snapshotter = MKMapSnapshotter(options: options)
        snapshotter.start(with: .main) { snap, _ in
            SnapshotterPark.shared.park(snapshotter)
            isSnapshotting = false
            guard let snap else { return }
            snapshot = snap
            framedKey = key
            image = composite(on: snap, size: size)
        }
    }

    // MARK: - Overlay compositing (cheap, CPU CoreGraphics)

    /// Draw the moving overlay — travelled (grey) + ahead (blue) lines,
    /// start/end dots, and the position puck — on top of the cached
    /// basemap snapshot. No MKMapView, no new snapshot: pure CG, so it's
    /// safe to run on every fix and (if ever needed) off the GPU.
    private func composite(on snap: MKMapSnapshotter.Snapshot, size: CGSize) -> UIImage {
        let isDark = colorScheme == .dark
        let base = snap.image
        let renderer = UIGraphicsImageRenderer(size: base.size)
        return renderer.image { ctx in
            base.draw(at: .zero)
            let cg = ctx.cgContext
            cg.setLineJoin(.round)
            cg.setLineCap(.round)

            let traveledPts = projected(strideSampled(traveled), snap)
            let aheadPts = projected(strideSampled(ahead), snap)

            // Travelled trace — muted grey, drawn first (under the blue
            // line so the join at the rider's position reads cleanly).
            strokeLine(cg, points: traveledPts,
                       casing: isDark ? .black : .white,
                       color: UIColor.systemGray.withAlphaComponent(0.9),
                       width: 4)

            // Route ahead — the same blue the editor preview + dash use.
            strokeLine(cg, points: aheadPts,
                       casing: isDark ? .black : .white,
                       color: .systemBlue,
                       width: 4)

            // Whole-route start (green) + end (red): start is the first
            // travelled point if we have one, else the first ahead point;
            // end is the last ahead point.
            if let startPt = traveledPts.first ?? aheadPts.first {
                drawDot(cg, at: startPt, fill: .systemGreen, radius: 5)
            }
            if let endPt = aheadPts.last {
                drawDot(cg, at: endPt, fill: .systemRed, radius: 5)
            }

            // "You are here" puck — drawn last so it sits on top.
            if let position {
                let p = snap.point(for: position)
                drawPuck(cg, at: p)
            }
        }
    }

    /// Stroke a casing (halo) then the main coloured line over an array
    /// of already-projected points. Skips when fewer than 2 points.
    private func strokeLine(_ cg: CGContext, points: [CGPoint],
                            casing: UIColor, color: UIColor, width: CGFloat) {
        guard points.count >= 2 else { return }
        let path = CGMutablePath()
        path.move(to: points[0])
        for p in points.dropFirst() { path.addLine(to: p) }

        cg.addPath(path)
        cg.setStrokeColor(casing.withAlphaComponent(0.85).cgColor)
        cg.setLineWidth(width + 3)
        cg.strokePath()

        cg.addPath(path)
        cg.setStrokeColor(color.cgColor)
        cg.setLineWidth(width)
        cg.strokePath()
    }

    private func drawDot(_ cg: CGContext, at p: CGPoint, fill: UIColor, radius: CGFloat) {
        guard p.x.isFinite, p.y.isFinite else { return }
        cg.setFillColor(UIColor.white.cgColor)
        cg.fillEllipse(in: CGRect(x: p.x - radius - 2, y: p.y - radius - 2,
                                  width: (radius + 2) * 2, height: (radius + 2) * 2))
        cg.setFillColor(fill.cgColor)
        cg.fillEllipse(in: CGRect(x: p.x - radius, y: p.y - radius,
                                  width: radius * 2, height: radius * 2))
    }

    /// The Apple-style location puck: a white ring around a blue dot,
    /// larger than the start/end markers so "you are here" pops.
    private func drawPuck(_ cg: CGContext, at p: CGPoint) {
        guard p.x.isFinite, p.y.isFinite else { return }
        // White halo with a soft shadow, scoped so the shadow can't bleed
        // onto the inner dot or anything drawn after.
        cg.saveGState()
        cg.setShadow(offset: .zero, blur: 3,
                     color: UIColor.black.withAlphaComponent(0.4).cgColor)
        cg.setFillColor(UIColor.white.cgColor)
        cg.fillEllipse(in: CGRect(x: p.x - 8, y: p.y - 8, width: 16, height: 16))
        cg.restoreGState()
        cg.setFillColor(UIColor.systemBlue.cgColor)
        cg.fillEllipse(in: CGRect(x: p.x - 5.5, y: p.y - 5.5, width: 11, height: 11))
    }

    // MARK: - Geometry helpers

    /// Project geo coords to image points via the snapshot's projection.
    private func projected(_ coords: [CLLocationCoordinate2D],
                           _ snap: MKMapSnapshotter.Snapshot) -> [CGPoint] {
        coords.map { snap.point(for: $0) }
    }

    /// Stride-sample a coordinate list down to at most `drawPointCap`
    /// points, always keeping the first and last. Shape-preserving enough
    /// for a thumbnail and keeps the per-fix draw cost flat for any route
    /// length. (Uniform stride, not RDP — a thumbnail doesn't need the
    /// extra fidelity and uniform stride is O(n) with no allocation churn.)
    private func strideSampled(_ coords: [CLLocationCoordinate2D]) -> [CLLocationCoordinate2D] {
        guard coords.count > drawPointCap else { return coords }
        let step = Double(coords.count - 1) / Double(drawPointCap - 1)
        var out: [CLLocationCoordinate2D] = []
        out.reserveCapacity(drawPointCap)
        for i in 0..<drawPointCap {
            out.append(coords[Int((Double(i) * step).rounded())])
        }
        // Guarantee the true last point is present (rounding can drop it).
        if let last = coords.last, out.last?.latitude != last.latitude
            || out.last?.longitude != last.longitude {
            out[out.count - 1] = last
        }
        return out
    }
}
