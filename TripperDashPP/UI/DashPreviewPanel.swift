//
//  DashPreviewPanel.swift
//  TripperDashPP
//
//  On-screen stand-in for the Royal Enfield Tripper TFT dash, shown only in
//  Demo mode (see `BikeLink.demoMode` / `AppStatus` frame mirror). It mimics
//  what the rider sees on the real dash (docs/dash-visible-area.md):
//
//   1. The burned-in video — the SAME 526×300 composited frame that would
//      feed the H.264 encoder (`DemoDashModel.latestFrame`), seen through the
//      dash's round glass: only a circle of the frame is visible.
//
//   2. What the dash FIRMWARE draws itself from the K1G TLV bytes, which is
//      not in the video: the turn card (maneuver glyph + distance in a disc,
//      bottom-left, over the stream) and the gold status band below the
//      frame with the checkered flag + ETA. Drawn here as SwiftUI from the
//      semantic `DemoDashModel.bubble` snapshot.
//
//  Everything is laid out in stream-frame pixels and scaled to the width
//  given, so the measured dash geometry applies 1:1. A "DEMO" badge in the
//  band keeps it from being mistaken for a live hardware feed.
//

import SwiftUI

struct DashPreviewPanel: View {
    /// The shared demo presentation model — frame + native-bubble snapshot.
    /// Observed, so the panel redraws as new frames (4 Hz) and bubbles (1 Hz)
    /// land.
    let demoModel: DemoDashModel

    // Stream-frame pixels. The glass and the turn card are the measured
    // `MapViewSource` constants; the band was measured from the same photos.
    private static let width: CGFloat = 526
    private static let frameHeight: CGFloat = 300
    /// The frame plus the gold band (y 303–347) below it.
    private static let height: CGFloat = 350
    private static let bandY: CGFloat = 303
    private static let bandHeight: CGFloat = 44
    private static let gold = Color(red: 0.80, green: 0.74, blue: 0.47)
    private static let cardFill = Color(red: 0.83, green: 0.85, blue: 0.87)

    /// The visible circle of the round glass.
    private static var glass: Path {
        let c = MapViewSource.visibleCenter, r = MapViewSource.visibleRadius
        return Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
    }

    var body: some View {
        GeometryReader { geo in
            dash.scaleEffect(geo.size.width / Self.width, anchor: .topLeading)
        }
        .aspectRatio(Self.width / Self.height, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Simulated dash preview")
    }

    /// The dash face in frame pixels, clipped to the round glass.
    private var dash: some View {
        ZStack(alignment: .topLeading) {
            Color.black
            videoLayer
                .frame(width: Self.width, height: Self.frameHeight)
            band
            if let bubble = demoModel.bubble, let maneuver = bubble.maneuver {
                turnCard(maneuver, distance: distanceText(bubble))
            }
        }
        .frame(width: Self.width, height: Self.height)
        .clipShape(Self.glass)
    }

    // MARK: - Video layer

    @ViewBuilder
    private var videoLayer: some View {
        if let frame = demoModel.latestFrame {
            // `Image(decorative:)` — the frame is purely visual (the map
            // it depicts is already summarised by the surrounding UI), so
            // it carries no accessibility text of its own.
            Image(decorative: frame, scale: 1.0, orientation: .up)
                .resizable()
        } else {
            VStack(spacing: 6) {
                ProgressView()
                Text("Waiting for map frames…")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(white: 0.06))
        }
    }

    // MARK: - Firmware chrome

    /// Gold status band below the frame: checkered flag (free ride too) +
    /// ETA on the right, DEMO badge on the left.
    private var band: some View {
        ZStack {
            Self.gold
            Text("DEMO")
                .font(.system(size: 16, weight: .black, design: .rounded))
                .foregroundStyle(.black)
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.yellow))
                .position(x: 160, y: Self.bandHeight / 2)
            Image(systemName: "flag.checkered")
                .font(.system(size: 22))
                .foregroundStyle(.white)
                .position(x: 368, y: Self.bandHeight / 2)
            if let eta = demoModel.bubble.flatMap({ etaText($0) }) {
                Text(eta)
                    .font(.system(size: 28))
                    .foregroundStyle(.white)
                    .position(x: 440, y: Self.bandHeight / 2)
            }
        }
        .frame(width: Self.width, height: Self.bandHeight)
        .offset(y: Self.bandY)
    }

    /// The dash's turn card: a light disc with a gold rim, the maneuver glyph
    /// above the distance. The glyph is the app's SF Symbol for the maneuver,
    /// not the firmware's own artwork (grey arrow, red head).
    private func turnCard(_ maneuver: ManeuverKind, distance: String?) -> some View {
        let r = MapViewSource.navCardRadius
        return ZStack {
            Circle().fill(Self.cardFill)
            Circle().strokeBorder(Self.gold, lineWidth: 3)
            VStack(spacing: 0) {
                Image(systemName: maneuver.sfSymbol)
                    .font(.system(size: 50, weight: .bold))
                    .foregroundStyle(Color(white: 0.35))
                    .frame(height: 70)
                if let distance {
                    distanceLabel(distance)
                }
            }
            .offset(y: 8)
        }
        .frame(width: 2 * r, height: 2 * r)
        .position(MapViewSource.navCardCenter)
    }

    /// "888 m" with the unit smaller, as on the dash.
    private func distanceLabel(_ text: String) -> some View {
        let parts = text.split(separator: " ", maxSplits: 1).map(String.init)
        return HStack(alignment: .firstTextBaseline, spacing: 1) {
            Text(parts.first ?? text).font(.system(size: 30, weight: .medium))
            if parts.count > 1 {
                Text(parts[1]).font(.system(size: 17, weight: .medium))
            }
        }
        .foregroundStyle(.black)
    }

    /// Distance-to-next maneuver, via the Live Activity formatter (rounded
    /// like the dash's turn card) so the preview and the Lock Screen agree.
    private func distanceText(_ bubble: DemoNavBubble) -> String? {
        guard let m = bubble.distanceToNextMeters, m >= 0 else { return nil }
        return LiveActivityController.distanceText(meters: m, imperial: bubble.imperial)
    }

    /// ETA as the dash shows it: the HHMM the ETA TLV carries (12-hour is
    /// the hour mod 12, no AM/PM), with the colon the dash draws.
    private func etaText(_ bubble: DemoNavBubble) -> String? {
        guard let date = bubble.etaDate else { return nil }
        let hhmm = String(decoding: K1GPacket.tlvEta(date: date, is24Hour: bubble.is24Hour).payload,
                          as: UTF8.self)
        return "\(hhmm.prefix(2)):\(hhmm.suffix(2))"
    }
}
