//
//  DashNotice.swift
//  TripperDashPP
//
//  A short, centred notice burned into the streamed dash video — the
//  universal "tell the rider something" primitive. Any part of the app can
//  raise one via `MapViewSource.showNotice(_:)`; it renders as a centred
//  card over the live map for `duration` seconds, then clears itself.
//
//  Three severity levels, each with its own accent colour + glyph, mirroring
//  the familiar iOS/road-sign vocabulary so a rider reads it at a glance:
//
//    - .info     → blue circle with an "i"   (e.g. "You've arrived")
//    - .warning  → amber triangle with "!"   (e.g. "Weak GPS signal")
//    - .critical → red circle with an "x"    (e.g. "Lost dash connection")
//
//  Design notes:
//    - Text is folded to ASCII at draw time (the dash font is ASCII-only,
//      same constraint as every other burned-in overlay — see
//      MapViewSource.drawText).
//    - Rendered in the flat outer CGContext (transform-independent) so it
//      sits dead-centre regardless of map rotation/zoom, like the weather
//      pill and speed-limit sign.
//    - Auto-dismiss is time-based off the render clock, not a timer: the
//      notice carries an expiry set when it's shown, and the draw path skips
//      it once expired. No background timers, nothing to cancel on teardown.
//

import CoreGraphics
import Foundation

/// Severity of a dash notice. Drives the accent colour and glyph.
enum DashNoticeLevel: String, Sendable, CaseIterable {
    case info
    case warning
    case critical

    /// Accent colour: blue / amber / red. Used for the glyph and the card's
    /// border so the level reads at a glance over both map palettes.
    var accent: CGColor {
        switch self {
        case .info:     return CGColor(red: 0.16, green: 0.53, blue: 0.96, alpha: 1.0) // blue
        case .warning:  return CGColor(red: 1.00, green: 0.66, blue: 0.05, alpha: 1.0) // amber
        case .critical: return CGColor(red: 0.93, green: 0.20, blue: 0.18, alpha: 1.0) // red
        }
    }
}

/// A single centred notice to burn into the dash video for a fixed duration.
///
/// Construct with the text, a level, and how long it should stay up; hand it
/// to `MapViewSource.showNotice(_:)`. The map source stamps the expiry when
/// it accepts the notice, so the same value is safe to build anywhere (the
/// `duration` is what matters, not wall-clock at construction).
struct DashNotice: Sendable {
    /// One-line message. Folded to ASCII at draw time; keep it short so the
    /// card fits the 526-px-wide dash without wrapping off-screen.
    let text: String

    /// Severity → colour + glyph.
    let level: DashNoticeLevel

    /// How long the notice stays on the dash, in seconds. Clamped to a sane
    /// band by the renderer.
    let duration: TimeInterval

    init(text: String, level: DashNoticeLevel, duration: TimeInterval = 4) {
        self.text = text
        self.level = level
        self.duration = duration
    }
}
