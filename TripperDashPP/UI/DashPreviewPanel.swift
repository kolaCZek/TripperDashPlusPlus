//
//  DashPreviewPanel.swift
//  TripperDashPP
//
//  On-screen stand-in for the Royal Enfield Tripper TFT dash, shown only in
//  Demo mode (see `BikeLink.demoMode` / `AppStatus` frame mirror). It renders
//  the two things the physical dash would show, which a reviewer/user without
//  the bike otherwise never sees:
//
//   1. The burned-in video — the SAME 526×300 composited frame that would
//      feed the H.264 encoder, drawn edge-to-edge inside a stylized TFT bezel
//      (`DemoDashModel.latestFrame`).
//
//   2. The "native bubble" the dash firmware draws itself from the K1G TLV
//      bytes — the maneuver glyph-in-a-circle + ETA + distance-to-next. These
//      are NOT part of the video frame, so we draw them as SwiftUI chrome
//      overlaid on the panel from the semantic `DemoDashModel.bubble` snapshot.
//
//  Everything here is presentation-only and @MainActor (SwiftUI). The panel
//  keeps the dash's real 526:300 aspect ratio so the preview reads like the
//  hardware, and carries a small "DEMO" badge so nobody mistakes it for a live
//  hardware feed.
//

import SwiftUI

struct DashPreviewPanel: View {
    /// The shared demo presentation model — frame + native-bubble snapshot.
    /// Observed, so the panel redraws as new frames (6 Hz) and bubbles (1 Hz)
    /// land.
    let demoModel: DemoDashModel

    /// The Tripper TFT is 526×300 — keep that exact aspect so the preview
    /// matches the hardware the video was composited for.
    private let dashAspect: CGFloat = 526.0 / 300.0

    var body: some View {
        // The TFT panel itself: black bezel + rounded frame around the live
        // (mirrored) video, with the native-bubble chrome + DEMO badge on top.
        ZStack {
            // Bezel / frame — a chunky black surround like the dash housing.
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.black)

            // The mirrored video frame, inset inside the bezel and clipped to
            // the inner screen shape.
            videoLayer
                .padding(6)

            // Native dash bubble (maneuver glyph + ETA + distance-to-next),
            // drawn by the dash FIRMWARE on real hardware — reproduced here as
            // SwiftUI chrome from the semantic snapshot.
            if let bubble = demoModel.bubble {
                bubbleOverlay(bubble)
                    .padding(12)
            }

            // "DEMO" badge so the on-screen dash is never mistaken for a live
            // hardware feed.
            demoBadge
                .padding(10)
        }
        // Lock the panel to the dash's real 526:300 aspect so it reads like
        // the hardware regardless of the width it's given.
        .aspectRatio(dashAspect, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .shadow(radius: 6, y: 3)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Simulated dash preview")
    }

    // MARK: - Video layer

    @ViewBuilder
    private var videoLayer: some View {
        // Inner screen: rounded black rectangle showing the mirrored frame, or
        // a "waiting for frames" placeholder before the first frame lands.
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(white: 0.06))

            if let frame = demoModel.latestFrame {
                // `Image(decorative:)` — the frame is purely visual (the map
                // it depicts is already summarised by the surrounding UI), so
                // it carries no accessibility text of its own.
                Image(decorative: frame, scale: 1.0, orientation: .up)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                VStack(spacing: 6) {
                    ProgressView()
                    Text("Waiting for map frames…")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    // MARK: - Native bubble chrome

    /// Reproduces the dash firmware's native nav bubble: a maneuver glyph in a
    /// circle (top-left) plus an ETA + distance-to-next readout. Positioned in
    /// the top-left corner, matching the OEM dash layout the burned-in video
    /// deliberately leaves room for.
    @ViewBuilder
    private func bubbleOverlay(_ bubble: DemoNavBubble) -> some View {
        VStack {
            HStack(alignment: .top, spacing: 8) {
                // Glyph-in-a-circle — uses the SAME `ManeuverKind.sfSymbol`
                // mapping the phone HUD uses, so the on-screen dash and the
                // rest of the app can never disagree on direction.
                if let maneuver = bubble.maneuver {
                    Image(systemName: maneuver.sfSymbol)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 42, height: 42)
                        .background(Circle().fill(Color.black.opacity(0.65)))
                        .overlay(Circle().stroke(Color.white.opacity(0.85), lineWidth: 2))
                }

                // Distance-to-next + ETA readout, stacked, on a dark scrim so
                // they stay legible over any map background.
                VStack(alignment: .leading, spacing: 2) {
                    if let dist = distanceText(bubble) {
                        Text(dist)
                            .font(.system(size: 16, weight: .heavy, design: .rounded))
                            .foregroundStyle(.white)
                    }
                    if let eta = etaText(bubble) {
                        Text(eta)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.black.opacity(0.55))
                )

                Spacer(minLength: 0)
            }
            Spacer(minLength: 0)
        }
    }

    /// Distance-to-next maneuver, formatted honouring the user's units. Under
    /// 1 km we show fine metres/feet (dash-parity close-in), matching the
    /// NavigationHUD's convention; at/above 1 km we hand off to the shared
    /// km/mi formatter so the whole app agrees.
    private func distanceText(_ bubble: DemoNavBubble) -> String? {
        guard let m = bubble.distanceToNextMeters, m >= 0 else { return nil }
        if m < 1000 {
            if bubble.imperial {
                let feet = m * 3.280839895013123
                return String(format: "%.0f ft", (feet / 10).rounded() * 10)
            }
            return String(format: "%.0f m", (m / 10).rounded() * 10)
        }
        return RideStatsFormatting.distance(m, imperial: bubble.imperial)
    }

    /// ETA clock string, honouring the 24-hour vs 12-hour setting.
    private func etaText(_ bubble: DemoNavBubble) -> String? {
        guard let eta = bubble.etaDate else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: bubble.is24Hour ? "en_GB" : "en_US")
        f.dateFormat = bubble.is24Hour ? "HH:mm" : "h:mm a"
        return "ETA \(f.string(from: eta))"
    }

    // MARK: - DEMO badge

    private var demoBadge: some View {
        VStack {
            HStack {
                Spacer()
                Text("DEMO")
                    .font(.system(size: 11, weight: .black, design: .rounded))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.yellow))
            }
            Spacer()
        }
    }
}
