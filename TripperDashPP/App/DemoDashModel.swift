//
//  DemoDashModel.swift
//  TripperDashPP
//
//  Demo-mode presentation model — the on-screen stand-in for the physical
//  Royal Enfield Tripper TFT dash.
//
//  In normal operation the app streams the composited 526×300 map frame to
//  the dash over H.264/RTP and separately pushes the maneuver-glyph + ETA
//  "native bubble" to the dash firmware as K1G TLV bytes. A reviewer or a
//  user without the bike sees NEITHER of those — everything leaves the phone
//  over Wi-Fi/UDP into the void.
//
//  Demo mode (see `BikeLink.demoMode`) fakes the dash link and mirrors BOTH
//  representations back onto the phone screen instead:
//
//   1. `latestFrame` — the exact CVPixelBuffer that would have fed the H.264
//      encoder, converted to a CGImage and published here so the on-screen
//      dash preview shows the burned-in video overlay (map + route + chevron
//      + burned maneuver glyph + progress bar + weather pill).
//
//   2. `bubble` — a semantic snapshot of the native dash bubble (maneuver +
//      ETA + distance-to-next + road name) that the real dash firmware would
//      have drawn from the K1G TLV bytes. These values are NOT in the video
//      frame, so the SwiftUI preview draws them as chrome around the panel.
//
//  Both are written from background callbacks (`ActiveNavLoop.tick`, the
//  MapViewSource frame callback), so this type is @MainActor-isolated and the
//  writers hop to the main actor before touching it. It is @Observable so the
//  `DashPreviewPanel` view redraws as frames and bubbles land.
//

import CoreGraphics
import Foundation
import Observation

/// Semantic snapshot of the "native" dash bubble — the maneuver glyph in a
/// circle + ETA readout the dash firmware draws itself (NOT part of the
/// streamed video). Carries the raw values plus the two formatting flags the
/// preview needs so it renders units/clock identically to the real dash.
struct DemoNavBubble: Equatable, Sendable {
    /// Upcoming maneuver — drives the SF Symbol glyph via `ManeuverKind.sfSymbol`.
    /// nil during the brief pre-first-fix transient / free-ride heartbeat.
    var maneuver: ManeuverKind?
    /// Final-destination ETA (already whole-trip scoped, matching the dash).
    var etaDate: Date?
    /// Metres to the next maneuver (unbucketed — the preview formats it).
    var distanceToNextMeters: Double?
    /// Optional bottom-line label (multi-stop "N min to <place>"), mirrors the
    /// roadName TLV the loop sends. nil on a classic single-destination ride.
    var roadName: String?
    /// Imperial vs metric — honour the user's units when formatting distance.
    var imperial: Bool
    /// 24-hour vs 12-hour clock — honour the user's setting when formatting ETA.
    var is24Hour: Bool
}

@MainActor
@Observable
final class DemoDashModel {

    /// The mirrored video frame (the same buffer that would feed the H.264
    /// encoder), converted to a CGImage for on-screen display. nil until the
    /// first frame lands or after `clear()`.
    var latestFrame: CGImage?

    /// The latest native-bubble snapshot pushed by `ActiveNavLoop`. nil when
    /// not navigating (free-ride heartbeat) or after `clear()`.
    var bubble: DemoNavBubble?

    /// Reset to the empty state — called from `AppStatus.stopStreaming()` when
    /// demo streaming ends so a stale frame/bubble doesn't linger on screen.
    func clear() {
        latestFrame = nil
        bubble = nil
    }
}
