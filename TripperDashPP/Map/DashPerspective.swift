//
//  DashPerspective.swift
//  TripperDashPP
//
//  Tilted ("3D") dash map. `MapViewSource` draws the usual flat,
//  heading-up map into a larger ground buffer (`groundSize`, puck at
//  `groundAnchor`, same scale as the flat frame), then this camera model
//  maps every dash pixel back onto that ground plane, so the map lies
//  down in the direction of travel and shows more road ahead. The puck
//  stays where it is on the flat frame, at the same scale across.
//
//  Camera: pinhole, `verticalFOV` high, pitched `tilt` degrees away from
//  straight down (0 = the flat map, pixel for pixel). The top
//  `skyFraction` of the frame (scaled with the tilt) is painted as sky:
//  the blurred far map fading into a blue gradient, which hides the far
//  rows, where the raster is minified to mush and the tiles end.
//
//  Pure maths + byte loops, no UIKit / GPU: it runs on the CPU in the
//  background render loop, where iOS forbids GPU work.
//

import CoreGraphics
import Foundation

nonisolated struct DashPerspective: Sendable {

    /// Full tilt, degrees from straight down. Must stay below
    /// 90° − verticalFOV/2 (67.5°) or the top rows look past the horizon.
    static let maxTilt: Double = 55
    static let verticalFOV: Double = 45
    /// Share of the frame height that is sky at full tilt.
    static let skyFraction: Double = 0.20
    /// Haze below the sky line (px at full tilt) where the map fades in.
    static let skyFadePx: Double = 14
    /// Autozoom range for the tilt: full tilt at `fullTiltZoom` and above
    /// (the whole 0.8–2.0 autozoom band), easing to flat at `flatZoom` on
    /// a manual zoom-out, as Google Maps does.
    static let fullTiltZoom: CGFloat = 0.8
    static let flatZoom: CGFloat = 0.4

    /// Ground buffer, in flat-frame px. Holds the visible footprint at every
    /// tilt 0…maxTilt (flat x −358…354, y −788…72 around the puck; the test
    /// `footprintFitsGroundBuffer` guards it). anchor − puck is whole
    /// pixels, so tilt 0 copies pixels 1:1.
    static let groundSize = CGSize(width: 768, height: 896)
    static let groundAnchor = CGPoint(x: 384, y: 800)

    let tilt: Double
    let frame: CGSize
    let puck: CGPoint

    private let sinP: Double, cosP: Double
    private let tx: Double, ty: Double
    /// −rz of the puck row's ray, and the ground→flat-px scale `k`.
    private let nrzPuck: Double, k: Double, groundYPuck: Double

    init(tilt: Double, frame: CGSize, puck: CGPoint) {
        self.tilt = min(max(tilt, 0), Self.maxTilt)
        self.frame = frame
        self.puck = puck
        let pitch = (90 - self.tilt) * .pi / 180     // below the horizon
        sinP = sin(pitch); cosP = cos(pitch)
        ty = tan(Self.verticalFOV / 2 * .pi / 180)
        tx = ty * Double(frame.width) / Double(frame.height)
        let vPuck = 1 - 2 * Double(puck.y) / Double(frame.height)
        nrzPuck = sinP - vPuck * ty * cosP
        k = Double(frame.width) * nrzPuck / (2 * tx)
        groundYPuck = (cosP + vPuck * ty * sinP) / nrzPuck
    }

    /// The tilt for the current zoom (before the tile-coverage cap).
    static func targetTilt(zoom: CGFloat) -> Double {
        let t = (zoom - flatZoom) / (fullTiltZoom - flatZoom)
        return maxTilt * Double(min(max(t, 0), 1))
    }

    // MARK: Projection

    /// For the screen row at `y` (Y-down, pixel centres are +0.5): flat px
    /// per screen px across (1 at the puck, grows towards the top), and the
    /// row's flat y relative to the puck (negative = ahead).
    func row(_ y: Double) -> (scale: Double, flatY: Double) {
        let v = 1 - 2 * y / Double(frame.height)
        let nrz = sinP - v * ty * cosP
        let groundY = (cosP + v * ty * sinP) / nrz
        return (nrzPuck / nrz, -(groundY - groundYPuck) * k)
    }

    /// Screen point → flat-frame point relative to the puck (heading-up,
    /// Y-down px, the space the flat map is drawn in).
    func flat(fromScreen p: CGPoint) -> CGPoint {
        let r = row(Double(p.y))
        return CGPoint(x: (Double(p.x) - Double(frame.width) / 2) * r.scale, y: r.flatY)
    }

    /// Inverse of `flat(fromScreen:)`. nil when the point is at or beyond
    /// the horizon (no screen position).
    func screen(fromFlat p: CGPoint) -> CGPoint? {
        let gx = Double(p.x) / k
        let gy = groundYPuck - Double(p.y) / k
        let den = ty * (sinP + gy * cosP)
        guard den > 0 else { return nil }
        let v = (gy * sinP - cosP) / den
        let nrz = sinP - v * ty * cosP
        guard nrz > 0 else { return nil }
        let u = gx * nrz / tx
        return CGPoint(x: (u + 1) * Double(frame.width) / 2, y: (1 - v) * Double(frame.height) / 2)
    }

    // MARK: Sky

    /// Rows above this are sky (scales with the tilt; 0 when flat).
    var skyRow: Double { Double(frame.height) * Self.skyFraction * tilt / Self.maxTilt }
    var skyBand: Double { skyRow + Self.skyFadePx * tilt / Self.maxTilt }
    /// Rows above this are fully covered by sky, so no map shows there.
    var opaqueRow: Double { skyBand * 0.24 }

    /// Blend weights for row `y`: how much of the blurred map replaces the
    /// sharp one, and how much sky covers the result. Both 0 below the band.
    func skyWeights(row y: Double) -> (blur: Double, sky: Double) {
        let band = skyBand
        guard band > 0, y < band else { return (0, 0) }
        let t = (band - y) / band
        return (min(1, 2 * t), min(1, 1.25 * pow(t, 0.8)))
    }

    // MARK: Coverage

    /// Screen polygon enclosing every pixel the round glass shows below the
    /// opaque sky. Convex, so its corners are enough for a containment test.
    func visibleOutline(glassCenter c: CGPoint, glassRadius radius: CGFloat) -> [CGPoint] {
        let r = Double(radius) + 2                   // the glass geometry's ±3 px
        let cx = Double(c.x), cy = Double(c.y)
        let top = opaqueRow, bottom = Double(frame.height)
        var pts: [CGPoint] = []
        for i in 0..<60 {                            // 6° steps, chord sag < 1 px
            let a = Double(i) * .pi / 30
            let y = cy + r * sin(a)
            if y >= top && y <= bottom { pts.append(CGPoint(x: cx + r * cos(a), y: y)) }
        }
        if top < cy {
            let dx = (r * r - (cy - top) * (cy - top)).squareRoot()
            pts += [CGPoint(x: cx - dx, y: top), CGPoint(x: cx + dx, y: top)]
        }
        pts += [CGPoint(x: 0, y: bottom), CGPoint(x: Double(frame.width), y: bottom)]
        return pts
    }

    /// Do all `points` (flat frame, puck-relative) land on a tile bitmap
    /// `rect` (the tile's own px, rider at the origin) drawn at `scale` and
    /// rotated by −`headingDegrees`, as `MapViewSource` draws it?
    static func covers(rect: CGRect, scale: CGFloat, headingDegrees: CGFloat,
                       points: [CGPoint]) -> Bool {
        let a = Double(headingDegrees) * .pi / 180   // undoes rotate(by: −heading)
        let c = cos(a), s = sin(a), z = Double(scale)
        return points.allSatisfy { p in
            let x = Double(p.x), y = Double(p.y)
            return rect.contains(CGPoint(x: (x * c - y * s) / z, y: (x * s + y * c) / z))
        }
    }

    // MARK: Pixels (BGRA, premultiplied, opaque)

    /// Resample the ground buffer into the frame through the camera
    /// (bilinear). Indices clamp at the buffer edge, so a sizing slip shows
    /// smeared edge pixels, never a crash.
    // ponytail: one bilinear tap per pixel; the far rows are minified up to
    // ~3× and may shimmer. Add 2×2 supersampling there if the dash shows it.
    func warp(ground: UnsafePointer<UInt8>, groundBytesPerRow gbpr: Int,
              groundWidth gw: Int, groundHeight gh: Int, anchor: CGPoint,
              into out: UnsafeMutablePointer<UInt8>, frameBytesPerRow fbpr: Int) {
        let w = Int(frame.width), h = Int(frame.height)
        let ax = Double(anchor.x), ay = Double(anchor.y), cx = Double(frame.width) / 2
        for y in 0..<h {
            let r = row(Double(y) + 0.5)
            let sy = ay + r.flatY - 0.5
            let y0f = sy.rounded(.down), wy = sy - y0f
            let y0 = min(max(Int(y0f), 0), gh - 1), y1 = min(max(Int(y0f) + 1, 0), gh - 1)
            let row0 = ground + y0 * gbpr, row1 = ground + y1 * gbpr
            let dst = out + y * fbpr
            for x in 0..<w {
                let sx = ax + (Double(x) + 0.5 - cx) * r.scale - 0.5
                let x0f = sx.rounded(.down), wx = sx - x0f
                let x0 = min(max(Int(x0f), 0), gw - 1) * 4, x1 = min(max(Int(x0f) + 1, 0), gw - 1) * 4
                for c in 0..<4 {
                    let a = Double(row0[x0 + c]) * (1 - wx) + Double(row0[x1 + c]) * wx
                    let b = Double(row1[x0 + c]) * (1 - wx) + Double(row1[x1 + c]) * wx
                    dst[x * 4 + c] = UInt8(min(255, a * (1 - wy) + b * wy + 0.5))
                }
            }
        }
    }

    /// Paint the sky over the top band: the map blurred (9×9 box), fading
    /// into a vertical gradient from `top` to `horizon` (RGB 0–255).
    func applySky(frame out: UnsafeMutablePointer<UInt8>, bytesPerRow bpr: Int,
                  top: SIMD3<Double>, horizon: SIMD3<Double>) {
        let w = Int(frame.width)
        let band = min(Int(frame.height), Int(skyBand.rounded(.up)))
        guard band > 0 else { return }
        let r = 4
        // Box blur of the band (separable, edge-clamped), B G R only.
        var horiz = [Double](repeating: 0, count: w * band * 3)
        for y in 0..<band {
            let src = out + y * bpr
            for x in 0..<w {
                for c in 0..<3 {
                    var sum = 0.0
                    for d in -r...r { sum += Double(src[min(max(x + d, 0), w - 1) * 4 + c]) }
                    horiz[(y * w + x) * 3 + c] = sum / Double(2 * r + 1)
                }
            }
        }
        let skyLine = max(1, skyRow)
        for y in 0..<band {
            let wt = skyWeights(row: Double(y) + 0.5)
            let g = min(1, (Double(y) + 0.5) / skyLine)
            let rgb = top * (1 - g) + horizon * g
            let bgr = [rgb.z, rgb.y, rgb.x]
            let dst = out + y * bpr
            for x in 0..<w {
                for c in 0..<3 {
                    var sum = 0.0
                    for d in -r...r { sum += horiz[(min(max(y + d, 0), band - 1) * w + x) * 3 + c] }
                    let blurred = sum / Double(2 * r + 1)
                    let mapped = Double(dst[x * 4 + c]) * (1 - wt.blur) + blurred * wt.blur
                    dst[x * 4 + c] = UInt8(min(255, max(0, mapped * (1 - wt.sky) + bgr[c] * wt.sky + 0.5)))
                }
            }
        }
    }
}
