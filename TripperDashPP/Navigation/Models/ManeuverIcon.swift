//
//  ManeuverIcon.swift
//  TripperDashPP
//
//  Phase 9e — asset-free maneuver glyph renderer for the active-nav
//  video compositing layer.
//
//  The dash's stock maneuver-arrow enum is largely undocumented (only
//  `0x0B` = continue and `0x3C` = bear-right have been confirmed against
//  real hardware), so we can't trust the dash to render the right arrow
//  for an arbitrary `MKRoute.Step`. Instead we send `0x0B` as a safe
//  placeholder over the wire and burn the actual arrow directly into the
//  video stream as a 70 × 70 pixel glyph in the top-left corner of the
//  526 × 300 frame.
//
//  All glyphs are drawn from CGContext paths — no asset catalog, no SF
//  Symbol rasterisation, nothing the rendering thread can fail to load.
//  This keeps the encoder hot-path allocation-free and guarantees the
//  glyph survives any iOS theme or asset bundling change.
//
//  Coordinate convention: the renderer assumes a Y-DOWN canvas where
//  (0,0) is the top-left corner of a 70 × 70 box. Caller is responsible
//  for translating the context to wherever on-screen the glyph should
//  appear (typically `(12, 12)` for a 12 px margin from the top-left).
//

import CoreGraphics
import MapKit
import Foundation

enum ManeuverKind: Equatable {
    case straight        // continue / go ahead
    case slightLeft
    case left
    case sharpLeft
    case uTurn           // left-side U-turn (right-hand-drive countries: mirror)
    case slightRight
    case right
    case sharpRight
    case merge
    case exitRight       // motorway exit slip
    case roundabout      // generic — exit number unknown
    case arrive          // destination flag / pin

    /// Best-effort classification from an `MKRoute.Step.instructions` string.
    /// Mirrors `ManeuverGlyph.symbol(for:)` heuristics but maps to our
    /// own enum so we can render path-based glyphs instead of SF Symbols.
    static func classify(_ step: MKRoute.Step) -> ManeuverKind {
        let s = step.instructions.lowercased()

        // Order matters — "sharp left" must match before "left".
        if s.contains("u-turn") || s.contains("otočte") || s.contains("otočit") {
            return .uTurn
        }
        if s.contains("sharp left") || s.contains("ostře vlevo") || s.contains("ostře doleva") {
            return .sharpLeft
        }
        if s.contains("sharp right") || s.contains("ostře vpravo") || s.contains("ostře doprava") {
            return .sharpRight
        }
        if s.contains("slight left") || s.contains("mírně vlevo") || s.contains("mírně doleva") {
            return .slightLeft
        }
        if s.contains("slight right") || s.contains("mírně vpravo") || s.contains("mírně doprava") {
            return .slightRight
        }
        if s.contains("roundabout") || s.contains("kruhový") || s.contains("kruháč") {
            return .roundabout
        }
        if s.contains("merge") || s.contains("zařaďte") || s.contains("připojit") {
            return .merge
        }
        if s.contains("exit") || s.contains("sjeďte") || s.contains("sjezd") {
            return .exitRight
        }
        if s.contains("arrive") || s.contains("destination") || s.contains("cíl") {
            return .arrive
        }
        if s.contains("left") || s.contains("vlevo") || s.contains("doleva") {
            return .left
        }
        if s.contains("right") || s.contains("vpravo") || s.contains("doprava") {
            return .right
        }
        return .straight
    }

    /// The K1G wire-byte to send for this maneuver via TLV `05 02`.
    /// **Only `.straight` (0x0B) is verified.** Everything else falls
    /// back to 0x0B so the dash bubble renders a benign placeholder
    /// (the actual arrow is burned into the video). When the full
    /// maneuver-enum table gets extracted we extend this switch.
    var wireByte: UInt8 {
        // 0x3C = bear-right is confirmed but we already render that
        // glyph in the video. Keeping the wire safe-mode for now —
        // change to real codes only after pcap verification.
        return 0x0B
    }
}

/// Asset-free path renderer. All draw methods take a CGContext positioned
/// at the top-left of a 70 × 70 glyph box and assume Y-DOWN coords.
enum ManeuverIcon {
    /// Standard glyph size. Tuned to read cleanly at 526 × 300 on the
    /// dash TFT (rider distance ~50 cm).
    static let size: CGFloat = 70

    /// Draws the given maneuver glyph into the provided context. Caller
    /// is responsible for positioning (use ctx.translateBy beforehand).
    /// Pen colour comes from `ctx.strokeColor` / `ctx.fillColor`.
    static func draw(_ kind: ManeuverKind, in ctx: CGContext) {
        ctx.saveGState()
        defer { ctx.restoreGState() }

        // Common pen settings — bold white-on-dark arrow body with a
        // 1 px black halo so it stays legible over any map background.
        ctx.setLineWidth(8)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setStrokeColor(red: 1, green: 1, blue: 1, alpha: 1)
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)

        switch kind {
        case .straight:     drawStraight(ctx)
        case .slightLeft:   drawAngled(ctx, deltaDeg: -25)
        case .left:         drawTurn(ctx, isLeft: true, sharp: false)
        case .sharpLeft:    drawTurn(ctx, isLeft: true, sharp: true)
        case .slightRight:  drawAngled(ctx, deltaDeg:  25)
        case .right:        drawTurn(ctx, isLeft: false, sharp: false)
        case .sharpRight:   drawTurn(ctx, isLeft: false, sharp: true)
        case .uTurn:        drawUTurn(ctx)
        case .merge:        drawMerge(ctx)
        case .exitRight:    drawExit(ctx)
        case .roundabout:   drawRoundabout(ctx)
        case .arrive:       drawArrive(ctx)
        }
    }

    // MARK: - Individual glyph paths
    //
    // Coordinate system: 70 × 70 box, (0,0) top-left, Y down.
    // Centre is at (35, 35). All arrows are drawn pointing in their
    // canonical direction; rotation/mirroring is handled inline.

    private static func drawStraight(_ ctx: CGContext) {
        ctx.beginPath()
        // Shaft
        ctx.move(to: CGPoint(x: 35, y: 60))
        ctx.addLine(to: CGPoint(x: 35, y: 18))
        // Arrowhead (V shape)
        ctx.move(to: CGPoint(x: 20, y: 30))
        ctx.addLine(to: CGPoint(x: 35, y: 14))
        ctx.addLine(to: CGPoint(x: 50, y: 30))
        ctx.strokePath()
    }

    /// Diagonal arrow — used for slight left / slight right. `deltaDeg`
    /// is the heading offset from "straight up" (negative = left).
    private static func drawAngled(_ ctx: CGContext, deltaDeg: CGFloat) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.translateBy(x: 35, y: 35)
        ctx.rotate(by: deltaDeg * .pi / 180)
        ctx.translateBy(x: -35, y: -35)
        drawStraight(ctx)
    }

    /// 90° turn — used for left/right (sharp variant rotates harder).
    private static func drawTurn(_ ctx: CGContext, isLeft: Bool, sharp: Bool) {
        ctx.beginPath()
        // Shaft starts at bottom centre, rises to mid, then hooks to the side.
        let hookY: CGFloat = sharp ? 36 : 28
        let endX: CGFloat = isLeft ? 16 : 54

        ctx.move(to: CGPoint(x: 35, y: 60))
        ctx.addLine(to: CGPoint(x: 35, y: hookY))
        ctx.addLine(to: CGPoint(x: endX, y: hookY))
        // Arrowhead at endX,hookY pointing horizontally (left or right).
        let dir: CGFloat = isLeft ? -1 : 1
        ctx.move(to: CGPoint(x: endX, y: hookY))
        ctx.addLine(to: CGPoint(x: endX - dir * 8, y: hookY - 8))
        ctx.move(to: CGPoint(x: endX, y: hookY))
        ctx.addLine(to: CGPoint(x: endX - dir * 8, y: hookY + 8))
        ctx.strokePath()
    }

    private static func drawUTurn(_ ctx: CGContext) {
        ctx.beginPath()
        // Right-side starting shaft going up, then 180° arc, then short
        // left-side shaft pointing down with arrowhead.
        ctx.move(to: CGPoint(x: 47, y: 60))
        ctx.addLine(to: CGPoint(x: 47, y: 30))
        // 180° arc from (47,30) clockwise to (23,30) with center (35,30) r=12.
        ctx.addArc(center: CGPoint(x: 35, y: 30),
                   radius: 12,
                   startAngle: 0,
                   endAngle: .pi,
                   clockwise: true)
        ctx.addLine(to: CGPoint(x: 23, y: 48))
        // Arrowhead at (23,48) pointing down.
        ctx.move(to: CGPoint(x: 23, y: 48))
        ctx.addLine(to: CGPoint(x: 16, y: 40))
        ctx.move(to: CGPoint(x: 23, y: 48))
        ctx.addLine(to: CGPoint(x: 30, y: 40))
        ctx.strokePath()
    }

    private static func drawMerge(_ ctx: CGContext) {
        ctx.beginPath()
        // Two shafts converging upward: one straight from (35,60) up,
        // one diagonal from (18,55) up-right meeting at (35,30), then
        // continuing up with arrowhead.
        ctx.move(to: CGPoint(x: 18, y: 58))
        ctx.addLine(to: CGPoint(x: 35, y: 30))
        ctx.move(to: CGPoint(x: 35, y: 30))
        ctx.addLine(to: CGPoint(x: 35, y: 14))
        ctx.move(to: CGPoint(x: 22, y: 26))
        ctx.addLine(to: CGPoint(x: 35, y: 14))
        ctx.addLine(to: CGPoint(x: 48, y: 26))
        ctx.strokePath()
    }

    private static func drawExit(_ ctx: CGContext) {
        ctx.beginPath()
        // Mainline goes up, exit branches off to the right at 30°.
        // Mainline shaft (gets cut off — feels like "leaving" it).
        ctx.move(to: CGPoint(x: 35, y: 60))
        ctx.addLine(to: CGPoint(x: 35, y: 42))
        // Exit branch
        ctx.addLine(to: CGPoint(x: 55, y: 18))
        // Arrowhead at (55,18) pointing up-right.
        ctx.move(to: CGPoint(x: 55, y: 18))
        ctx.addLine(to: CGPoint(x: 45, y: 17))
        ctx.move(to: CGPoint(x: 55, y: 18))
        ctx.addLine(to: CGPoint(x: 53, y: 28))
        ctx.strokePath()
    }

    private static func drawRoundabout(_ ctx: CGContext) {
        ctx.beginPath()
        // Bottom entry shaft.
        ctx.move(to: CGPoint(x: 35, y: 60))
        ctx.addLine(to: CGPoint(x: 35, y: 50))
        ctx.strokePath()
        // Circle.
        ctx.strokeEllipse(in: CGRect(x: 18, y: 18, width: 34, height: 34))
        // Exit shaft to top-right with arrowhead.
        ctx.beginPath()
        ctx.move(to: CGPoint(x: 48, y: 22))
        ctx.addLine(to: CGPoint(x: 60, y: 10))
        ctx.move(to: CGPoint(x: 60, y: 10))
        ctx.addLine(to: CGPoint(x: 50, y: 10))
        ctx.move(to: CGPoint(x: 60, y: 10))
        ctx.addLine(to: CGPoint(x: 60, y: 20))
        ctx.strokePath()
    }

    private static func drawArrive(_ ctx: CGContext) {
        // Pin shape: lollipop + tip.
        ctx.beginPath()
        ctx.strokeEllipse(in: CGRect(x: 23, y: 14, width: 24, height: 24))
        ctx.move(to: CGPoint(x: 35, y: 38))
        ctx.addLine(to: CGPoint(x: 35, y: 58))
        ctx.strokePath()
        // Inner dot
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        ctx.fillEllipse(in: CGRect(x: 31, y: 22, width: 8, height: 8))
    }
}
