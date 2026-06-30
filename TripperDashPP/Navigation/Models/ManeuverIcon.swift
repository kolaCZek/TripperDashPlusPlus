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

    /// HYBRID classification of the maneuver at a route node.
    ///
    /// `MKRoute.Step` exposes no structured maneuver type — only a
    /// localized free-text `instructions` string. AND, critically, Apple
    /// puts that string on the step whose polyline ENDS at the maneuver
    /// node: `instructions` names the turn ONTO the next road, i.e. the
    /// maneuver at the END of THIS step's polyline, not at its start. So
    /// the step the rider is currently TRAVERSING — the one whose polyline
    /// ends at the upcoming node (`arrivingStep`) — is the one whose
    /// `.instructions` describe the upcoming maneuver. Reading the text
    /// from the *following* step (whose polyline LEAVES the node) was one
    /// maneuver too far ahead: the off-by-one that showed "Turn right onto
    /// Mlýnská" on the dash while the rider should still have been told to
    /// turn left onto Papírenská (field logs, 6/2026).
    ///
    /// Responsibilities, split so neither road names nor locale can flip a
    /// turn:
    ///   - **Text** (`arrivingStep.instructions`) decides the maneuver
    ///     FAMILY: roundabout? U-turn? merge? exit/ramp? ferry/railroad?
    ///     arrival? plain turn?
    ///   - **Geometry** decides the DIRECTION + sharpness of a plain turn,
    ///     from the signed angle at the node between the incoming leg
    ///     (`arrivingStep.polyline`, ending at the node) and the outgoing
    ///     leg (`departingStep.polyline`, leaving the node). Language-
    ///     independent, immune to road names containing "left"/"right".
    ///
    /// Roundabout EXIT NUMBER stays text-derived — the route polyline
    /// passes through the circle but never traces the arms we don't take,
    /// so the exit count is geometrically unknowable (see
    /// `RoundaboutInstructionParser`).
    ///
    /// - Parameters:
    ///   - arrivingStep: the step the rider is COMPLETING; its polyline
    ///     ENDS at the maneuver node and its `.instructions` name the
    ///     upcoming maneuver (text + family + the incoming heading).
    ///   - departingStep: the step that LEAVES the node (its polyline
    ///     starts there), supplying the outgoing heading for the turn
    ///     angle. `nil` at the final maneuver (arrival has no outgoing
    ///     leg) — direction then falls back to text.
    ///   - precedingStep: the step BEFORE `arrivingStep`. Used only to
    ///     carry a roundabout's exit ordinal forward across MapKit's split
    ///     entry/exit roundabout steps.
    static func classify(arrivingStep: MKRoute.Step,
                         departingStep: MKRoute.Step?,
                         precedingStep: MKRoute.Step? = nil) -> ManeuverKind {
        let s = arrivingStep.instructions.lowercased()

        // Turn geometry at the node = end of `arrivingStep.polyline` =
        // start of `departingStep.polyline`. `nil` when there's no outgoing
        // leg (final/arrival step) — direction then falls back to text.
        let geoTurn: ManeuverGeometry.Turn? = departingStep.flatMap { dep in
            ManeuverGeometry.turn(previousStepPolyline: arrivingStep.polyline,
                                  currentStepPolyline: dep.polyline)
        }

        // ---- Family detection (text) -----------------------------------
        // Roundabout first: roundabout strings also contain "exit", so
        // this must precede the exit/ramp branch below.
        if Keywords.isRoundabout(s) {
            // Exit number is text-only (geometry can't see untaken arms).
            //
            // MapKit often splits a roundabout into an ENTRY step that
            // carries the ordinal ("At the roundabout, take the 1st exit")
            // and a follow-on EXIT step ("Exit the roundabout onto …")
            // that keeps the roundabout keyword but DROPS the ordinal.
            // Parsing the exit step alone yields nil → exit 0 → a generic
            // numberless circle glyph appears mid-maneuver and the bubble
            // looks like it "lost" the exit count partway through (field
            // ride 6/2026). Carry the ordinal forward from the PRECEDING
            // roundabout step so the whole maneuver shows one stable,
            // correct exit number from entry through exit. When NO step in
            // the chain carries an ordinal (Apple often emits only "turn
            // left/continue/right onto …"), fall back to a direction-based
            // estimate so the dash draws a numbered arc, not a blank circle.
            let exit = RoundaboutInstructionParser.parseExitNumber(from: arrivingStep.instructions)
                ?? precedingStep.flatMap { prev -> Int? in
                    guard Keywords.isRoundabout(prev.instructions.lowercased()) else { return nil }
                    return RoundaboutInstructionParser.parseExitNumber(from: prev.instructions)
                }
                ?? RoundaboutInstructionParser.inferExitFromDirection(arrivingStep.instructions)
                ?? 0
            // Rotation: CCW for right-hand-traffic (Continental Europe),
            // which is where this bike rides. A future enhancement can
            // derive CW/CCW from the in-circle polyline winding.
            return .roundabout(exit: exit, clockwise: false)
        }

        if Keywords.isUTurn(s) {
            // Resolve side geometrically when we can; default to the
            // local (right-hand-traffic) convention of a left U-turn.
            switch geoTurn {
            case .uTurnRight, .sharpRight, .right, .slightRight:
                return .uTurnRight
            default:
                return .uTurnLeft
            }
        }

        if Keywords.isMerge(s) {
            return geometricSide(geoTurn: geoTurn,
                                 left: .mergeLeft, right: .mergeRight,
                                 textDefault: .mergeRight, instruction: s)
        }

        if Keywords.isExitRamp(s) {
            return geometricSide(geoTurn: geoTurn,
                                 left: .exitLeft, right: .exitRight,
                                 textDefault: .exitRight, instruction: s)
        }

        if Keywords.isFerry(s)    { return .ferry }
        if Keywords.isRailroad(s) { return .railroad }
        if Keywords.isArrive(s)   { return .arrive }

        // ---- Plain turn: DIRECTION from geometry -----------------------
        if let turn = geoTurn {
            switch turn {
            case .straight:    return .straight
            case .slightLeft:  return .slightLeft
            case .left:        return .left
            case .sharpLeft:   return .sharpLeft
            case .slightRight: return .slightRight
            case .right:       return .right
            case .sharpRight:  return .sharpRight
            case .uTurnLeft:   return .uTurnLeft
            case .uTurnRight:  return .uTurnRight
            }
        }

        // ---- Fallback: text direction (first step / degenerate geometry)
        // Earliest-token wins, with word boundaries, so a road name later
        // in the clause can't override the actual turn verb.
        return Keywords.textualTurn(s)
    }

    /// Pick a left/right variant from a precomputed geometry `Turn`,
    /// falling back to a textual "left" hint and finally a sensible
    /// default. Used for families where the glyph has a handed pair (merge,
    /// exit) but the angle alone is enough to tell the side.
    private static func geometricSide(geoTurn: ManeuverGeometry.Turn?,
                                      left: ManeuverKind,
                                      right: ManeuverKind,
                                      textDefault: ManeuverKind,
                                      instruction s: String) -> ManeuverKind {
        switch geoTurn {
        case .slightLeft?, .left?, .sharpLeft?, .uTurnLeft?:
            return left
        case .slightRight?, .right?, .sharpRight?, .uTurnRight?:
            return right
        case .straight?, nil:
            // Angle is ~straight or unavailable — fall back to a textual
            // side hint, then the family default.
            if Keywords.hasLeftToken(s) && !Keywords.hasRightToken(s) { return left }
            if Keywords.hasRightToken(s) && !Keywords.hasLeftToken(s) { return right }
            return textDefault
        }
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

    /// SF Symbol name for the in-app SwiftUI HUD. Derived from the SAME
    /// `ManeuverKind` that drives the dash bubble, so the phone HUD and the
    /// dash can never disagree on direction (they used to: both had their
    /// own substring classifier and the HUD's matched road names too).
    var sfSymbol: String {
        switch self {
        case .straight:                 return "arrow.up"
        case .slightLeft:               return "arrow.up.left"
        case .left:                     return "arrow.turn.up.left"
        case .sharpLeft:                return "arrow.uturn.left"
        case .slightRight:              return "arrow.up.right"
        case .right:                    return "arrow.turn.up.right"
        case .sharpRight:               return "arrow.uturn.right"
        case .uTurnLeft:                return "arrow.uturn.down"
        case .uTurnRight:               return "arrow.uturn.down"
        case .mergeLeft, .mergeRight:   return "arrow.merge"
        case .forkLeft:                 return "arrow.up.left"
        case .forkRight:                return "arrow.up.right"
        case .forkStraight:             return "arrow.up"
        case .exitLeft:                 return "arrow.up.left.square"
        case .exitRight:                return "arrow.up.right.square"
        case .roundabout:               return "arrow.triangle.2.circlepath"
        case .arrive, .arriveLeft, .arriveRight:
                                        return "flag.checkered"
        case .recalculating:            return "arrow.triangle.2.circlepath"
        case .ferry:                    return "ferry"
        case .railroad:                 return "tram.fill"
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
        case .recalculating:          drawRecalculating(ctx)
        case .arrive, .arriveLeft, .arriveRight:
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

    /// Spinning-compass "recalculating" glyph: a near-closed circular
    /// arrow. Matches the dash's 0x1C bubble icon so the burned-in
    /// fallback (if re-enabled) reads the same as the native bubble while
    /// a reroute is in flight.
    private static func drawRecalculating(_ ctx: CGContext) {
        ctx.beginPath()
        // Open circular arc (gap at the top-right where the arrowhead is).
        ctx.addArc(center: CGPoint(x: 35, y: 35),
                   radius: 17,
                   startAngle: -.pi / 4,      // start just past 1 o'clock
                   endAngle: 3 * .pi / 2,     // sweep almost all the way round
                   clockwise: false)
        ctx.strokePath()
        // Arrowhead at the open end (top-right), pointing clockwise.
        ctx.beginPath()
        let tip = CGPoint(x: 35 + 17 * cos(-.pi / 4), y: 35 + 17 * sin(-.pi / 4))
        ctx.move(to: tip)
        ctx.addLine(to: CGPoint(x: tip.x - 10, y: tip.y - 2))
        ctx.move(to: tip)
        ctx.addLine(to: CGPoint(x: tip.x + 1, y: tip.y + 11))
        ctx.strokePath()
    }
}
