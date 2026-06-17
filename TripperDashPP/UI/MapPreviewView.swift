//
//  MapPreviewView.swift
//  TripperDashPP
//
//  Phase 5 — replacement for SwiftUI `Map(position:)` in MapPickerView.
//
//  Why this exists: the SwiftUI `Map` view wraps MKMapView with its own
//  GPU/Metal lifecycle that we don't control. When the user navigates
//  away (NavigationLink push → StreamingView, then pop back), SwiftUI
//  dealloc's the underlying MKMapView while its Metal command buffer
//  is still in flight, triggering the MTLDebugDevice assertion and
//  freezing the app.
//
//  This view instead renders MKMapSnapshotter at 1 Hz into a regular
//  UIImage. No live MKMapView, no MetalKit view, no Core Animation
//  Metal layer attached to anything UIKit owns — just an image. The
//  snapshotter itself is parked in SnapshotterPark so its Metal CB
//  has time to drain on every refresh, same pattern that fixed the
//  streaming path.
//
//  Visually: the preview refreshes once per second instead of 6× per
//  second. For a "what the dash sees" sanity check view that's plenty
//  — the rider isn't looking at it while moving.
//

import CoreLocation
import MapKit
import SwiftUI

struct MapPreviewView: View {
    /// Center coordinate. nil → render a wide overview of central Europe
    /// as a placeholder so the view never goes blank.
    let coordinate: CLLocationCoordinate2D?

    /// Heading in degrees clockwise from true north, or nil for "north
    /// up" preview. Streaming path uses bike/phone heading; here we
    /// always render north-up to make the picker easier to read.
    let heading: CLLocationDirection?

    @State private var image: UIImage?
    @State private var timer: Timer?
    /// Per-view generation counter so a slow snapshot from a previous
    /// onAppear cycle doesn't overwrite a fresh one after the view
    /// reappeared.
    @State private var generation: UInt64 = 0

    var body: some View {
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
        .onAppear { startRefreshing() }
        .onDisappear { stopRefreshing() }
        .onChange(of: coordinate?.latitude) { _, _ in refresh() }
        .onChange(of: coordinate?.longitude) { _, _ in refresh() }
    }

    private func startRefreshing() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            // Hop to main actor explicitly — Timer fires on whatever
            // run loop scheduled it, which is main here, but be safe.
            DispatchQueue.main.async { refresh() }
        }
    }

    private func stopRefreshing() {
        timer?.invalidate()
        timer = nil
        // Bump generation so any in-flight snapshot's completion drops
        // its result instead of stamping a stale image after reappear.
        generation &+= 1
    }

    private func refresh() {
        let center = coordinate ?? CLLocationCoordinate2D(latitude: 50.08, longitude: 14.43)
        let distance: CLLocationDistance = coordinate == nil ? 500_000 : 800

        let options = MKMapSnapshotter.Options()
        // Pick a size that comfortably fills any iPhone viewport without
        // being absurdly big. SwiftUI .aspectRatio(.fill) handles the rest.
        options.size = CGSize(width: 600, height: 600)
        options.scale = UIScreen.main.scale
        options.camera = MKMapCamera(
            lookingAtCenter: center,
            fromDistance: distance,
            pitch: 0,
            heading: heading ?? 0
        )
        if #available(iOS 16.0, *) {
            options.preferredConfiguration = MKStandardMapConfiguration(
                elevationStyle: .flat,
                emphasisStyle: .default
            )
        }

        let myGen = generation
        let snapshotter = MKMapSnapshotter(options: options)
        snapshotter.start(with: .main) { snap, _ in
            // Always park, regardless of whether we use the result —
            // the Metal command buffer needs to drain either way.
            SnapshotterPark.shared.park(snapshotter)
            guard myGen == generation else { return }
            guard let snap else { return }
            // Annotate user location as a simple blue dot since we're
            // not using UserAnnotation() / MKUserLocationView (those
            // need a live MKMapView).
            if let coord = coordinate {
                let annotated = drawUserPin(on: snap.image, at: snap.point(for: coord))
                image = annotated
            } else {
                image = snap.image
            }
        }
    }

    /// Draws a blue location dot at the given pixel coordinate on top
    /// of the snapshot image. Plain CG since we don't have a live
    /// MKMapView to host MKUserLocationView.
    private func drawUserPin(on baseImage: UIImage, at point: CGPoint) -> UIImage {
        let size = baseImage.size
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            baseImage.draw(at: .zero)

            // Skip if the point fell off-canvas (snapshot center outside
            // the rendered region — rare but possible at extreme zoom).
            guard point.x.isFinite, point.y.isFinite,
                  point.x >= 0, point.y >= 0,
                  point.x <= size.width, point.y <= size.height else {
                return
            }

            let cg = ctx.cgContext
            // White halo
            cg.setFillColor(UIColor.white.cgColor)
            cg.fillEllipse(in: CGRect(x: point.x - 11, y: point.y - 11, width: 22, height: 22))
            // Blue dot
            cg.setFillColor(UIColor.systemBlue.cgColor)
            cg.fillEllipse(in: CGRect(x: point.x - 8, y: point.y - 8, width: 16, height: 16))
        }
    }
}
