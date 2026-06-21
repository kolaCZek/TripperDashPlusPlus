//
//  ManeuverIcon.swift
//  TripperDashPP
//
//  Asset-free maneuver glyph renderer for the active-nav video
//  compositing layer, plus the wire-byte mapping that drives the
//  dashboard's own bubble glyph via the K1G maneuver TLV
//  (`05 02 00 01 <byte>`).
//
//  Two complementary outputs, one shared `ManeuverKind`:
//
//   1. **Video burn-in** — `ManeuverIcon.draw(_:in:)` renders a 70 × 70
//      glyph into a CGContext from pure path commands (no asset bundle,
//      no SF Symbol rasterisation). Used for the top-left overlay on
//      the H.264 frame so the rider sees the maneuver inside the map
//      view.
//
//   2. **Native dash bubble** — `ManeuverKind.wireByte` returns the
//      catalog byte the dash firmware uses to render its own bubble
//      glyph on the LEFT side of the screen. The mapping is sourced
//      from the user-verified catalog at `docs/maneuver-glyphs/`
//      (90 entries field-walked in 6/2026 against a Guerrilla 450).
//
//  History: until 6/2026 we sent a hardcoded `0x0B` placeholder for
//  every maneuver because the dash's glyph table was undocumented. The
//  Tripper just rendered "roundabout CCW exit 1" for every step, but
//  it didn't matter because the burned-in arrow over the video was the
//  primary signal. With the catalog mapped we can now drive both
//  layers; the dash bubble becomes the authoritative glyph and the
//  video burn-in is the fallback / secondary cue.
//
//  Coordinate convention for the drawer: Y-DOWN canvas where (0,0) is
//  the top-left corner of a 70 × 70 box. Caller is responsible for
//  translating the context to the on-screen target position.
//

import CoreGraphics
import MapKit
import Foundation

/// Semantic maneuver classification, decoupled from the K1G wire format
/// and from the path renderer. The same value drives both the burned
/// video glyph and the dash bubble glyph.
///
/// Cases are intentionally finer-grained than the legacy enum so the
/// `wireByte` mapping can pick a distinct catalog entry per variant.
/// Where MapKit can't disambiguate (e.g. roundabout exit count) we fall
/// back to a "best guess" exit number (0 by default), which renders as
/// a generic CCW roundabout glyph on the dash; F2b will replace that
/// with a proper exit counter.
enum ManeuverKind: Equatable {
    case straight                                  // 0x09 (short) / 0x3B (long)
    case slightLeft                                // 0x18
    case left                                      // 0x14
    case sharpLeft                                 // 0x16
    case slightRight                               // 0x19
    case right                                     // 0x15
    case sharpRight                                // 0x17
    case uTurnLeft                                 // 0x3D — 180° via the left side
    case uTurnRight                                // 0x1A — 180° via the right side
    case mergeLeft                                 // 0x03 — your road merges in from the LEFT
    case mergeRight                                // 0x04 — your road merges in from the RIGHT
    case forkLeft                                  // 0x06 — Y-fork: stay LEFT
    case forkRight                                 // 0x05 — Y-fork: stay RIGHT
    case forkStraight                              // 0x1B — Y-fork: stay STRAIGHT
    case exitLeft                                  // 0x28 — gentle ramp / sjezd left
    case exitRight                                 // 0x27 — gentle ramp / sjezd right
    case roundabout(exit: Int, clockwise: Bool)    // 0x0A-0x13/0x50-0x59 (CCW) or 0x31-0x3A/0x46-0x4F (CW)
    case arrive                                    // 0x00 — destination AHEAD
    case arriveLeft                                // 0x01 — destination ahead-LEFT
    case arriveRight                               // 0x02 — destination ahead-RIGHT
    case recalculating                             // 0x1C — spinning compass
    case ferry                                     // 0x3E — ferry crossing
    case railroad                                  // 0x3F — level / train crossing

    /// Best-effort classification from an `MKRoute.Step.instructions`
    /// string. Mirrors `ManeuverGlyph.symbol(for:)` heuristics but maps
    /// to our own enum so we can render path-based glyphs *and* pick a
    /// catalog wire byte.
    ///
    /// Roundabout cases default to `(exit: 0, clockwise: false)` —
    /// MKRoute.Step does not expose exit number or turn direction, so
    /// without geometry-side computation we render a generic small CCW
    /// roundabout. F2b will replace this with a proper exit counter.
    static func classify(_ step: MKRoute.Step) -> ManeuverKind {
        let s = step.instructions.lowercased()

        // Order matters — "sharp left" must match before "left".
        if s.contains("u-turn") || s.contains("otočte") || s.contains("otočit") {
            // MKRoute doesn't tell us which side, so we assume the
            // local left-hand-drive convention (CZ): U-turn via the
            // left side.
            return .uTurnLeft
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
            // F2a: no exit-count extraction yet. Default to (0, CCW)
            // which renders as a small CCW roundabout on the dash.
            // F2b will plug in the real exit number + direction.
            return .roundabout(exit: 0, clockwise: false)
        }
        if s.contains("merge") || s.contains("zařaďte") || s.contains("připojit") {
            // MKRoute "merge" instruction usually means "the highway
            // you're joining comes in from the left" (you slide right
            // into traffic). We default to mergeRight; a richer parser
            // could look for "from the left/right" qualifiers.
            return .mergeRight
        }
        if s.contains("exit") || s.contains("sjeďte") || s.contains("sjezd") {
            // Default exit side mirrors typical motorway layout (right
            // in right-hand-traffic countries). Pick by "left" hint
            // if present.
            if s.contains("left") || s.contains("vlevo") || s.contains("doleva") {
                return .exitLeft
            }
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

    /// The K1G maneuver byte for the dash bubble glyph.
    ///
    /// Catalog source: `docs/maneuver-glyphs/README.md` (90 entries,
    /// user-verified against a Guerrilla 450 in 6/2026).
    ///
    /// Roundabout exits beyond 19 are clamped to 19 because the
    /// catalog only goes that far. Roundabout exit 0 means "first
    /// available" (some routers count entry as exit 0; others count
    /// exit 0 as a sharp-back / U-turn through the circle).
    var wireByte: UInt8 {
        switch self {
        case .straight:        return 0x09
        case .slightLeft:      return 0x18
        case .left:            return 0x14
        case .sharpLeft:       return 0x16
        case .slightRight:     return 0x19
        case .right:           return 0x15
        case .sharpRight:      return 0x17
        case .uTurnLeft:       return 0x3D
        case .uTurnRight:      return 0x1A
        case .mergeLeft:       return 0x03
        case .mergeRight:      return 0x04
        case .forkLeft:        return 0x06
        case .forkRight:       return 0x05
        case .forkStraight:    return 0x1B
        case .exitLeft:        return 0x28
        case .exitRight:       return 0x27
        case .arrive:          return 0x00
        case .arriveLeft:      return 0x01
        case .arriveRight:     return 0x02
        case .recalculating:   return 0x1C
        case .ferry:           return 0x3E
        case .railroad:        return 0x3F
        case .roundabout(let exit, let clockwise):
            // Clamp to catalog range (0..19). The dash silently
            // ignores out-of-range bytes by hiding the bubble, which
            // would be worse than showing a "wrong" exit count.
            let n = max(0, min(19, exit))
            switch (clockwise, n) {
            case (false, 0...9):  return UInt8(0x0A + n)           // 0x0A..0x13
            case (false, 10...19): return UInt8(0x50 + n - 10)     // 0x50..0x59
            case (true,  0...9):  return UInt8(0x31 + n)           // 0x31..0x3A
            case (true,  10...19): return UInt8(0x46 + n - 10)     // 0x46..0x4F
            default:               return 0x0A                      // unreachable (clamp guarantees range)
            }
        }
    }
}

/// Asset-free path renderer. All draw methods take a CGContext positioned
/// at the top-left of a 70 × 70 glyph box and assume Y-DOWN coords.
///
/// The renderer is intentionally simpler than the dash firmware's glyph
/// table — several wire-byte variants (different roundabout exit counts,
/// arrive-left vs arrive-right, fork variants) collapse to a single
/// drawn glyph here. That's OK: the dash bubble is the authoritative
/// rendering; the video burn-in is a fallback so the rider can still
/// see *something* if the K1G control plane stalls.
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
        case .straight:               drawStraight(ctx)
        case .slightLeft:             drawAngled(ctx, deltaDeg: -25)
        case .left:                   drawTurn(ctx, isLeft: true, sharp: false)
        case .sharpLeft:              drawTurn(ctx, isLeft: true, sharp: true)
        case .slightRight:            drawAngled(ctx, deltaDeg:  25)
        case .right:                  drawTurn(ctx, isLeft: false, sharp: false)
        case .sharpRight:             drawTurn(ctx, isLeft: false, sharp: true)
        case .uTurnLeft, .uTurnRight: drawUTurn(ctx)
        case .mergeLeft, .mergeRight: drawMerge(ctx)
        case .forkLeft, .forkRight, .forkStraight:
                                      drawMerge(ctx) // visually similar
        case .exitLeft, .exitRight:   drawExit(ctx)
        case .roundabout:             drawRoundabout(ctx)
        case .arrive, .arriveLeft, .arriveRight, .recalculating:
                                      drawArrive(ctx)
        case .ferry, .railroad:       drawStraight(ctx) // no specific glyph yet
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
