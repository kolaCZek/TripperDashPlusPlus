//
//  DashPerspectiveTests.swift
//  TripperDashPPTests
//
//  The tilted (3D) dash map's camera: tilt 0 is the flat frame pixel for
//  pixel, the puck stays put, every tilt's visible footprint fits the
//  ground buffer, and the coarse layer covers full tilt in any direction
//  (the "never black on the glass" guarantee rests on that).
//

import Testing
import CoreGraphics
import Foundation
@testable import TripperDashPP

@MainActor
struct DashPerspectiveTests {

    private let frame = CGSize(width: 526, height: 300)
    private let puck = CGPoint(x: 263, y: 234)
    private func cam(_ tilt: Double) -> DashPerspective {
        DashPerspective(tilt: tilt, frame: frame, puck: puck)
    }
    private func footprint(_ p: DashPerspective) -> [CGPoint] {
        p.visibleOutline(glassCenter: MapViewSource.visibleCenter, glassRadius: MapViewSource.visibleRadius)
            .map(p.flat(fromScreen:))
    }

    @Test func zeroTiltIsTheFlatFrame() {
        let p = cam(0)
        let f = p.flat(fromScreen: CGPoint(x: 100.5, y: 50.5))
        #expect(abs(f.x - (100.5 - 263)) < 1e-9)
        #expect(abs(f.y - (50.5 - 234)) < 1e-9)
        #expect(p.skyBand == 0)
    }

    @Test func screenAndFlatRoundTrip() {
        for tilt in [10.0, 30, 55] {
            let p = cam(tilt)
            for s in [CGPoint(x: 10, y: 200), CGPoint(x: 263, y: 20), CGPoint(x: 500, y: 299), puck] {
                let back = p.screen(fromFlat: p.flat(fromScreen: s))
                #expect(back != nil)
                if let back {
                    #expect(abs(back.x - s.x) < 1e-6)
                    #expect(abs(back.y - s.y) < 1e-6)
                }
            }
        }
    }

    @Test func puckStaysPutAtFlatScale() {
        let p = cam(55)
        let f = p.flat(fromScreen: puck)
        #expect(abs(f.x) < 1e-9 && abs(f.y) < 1e-9)
        #expect(abs(p.row(Double(puck.y)).scale - 1) < 1e-9)
        // More road per pixel towards the top, further ahead.
        #expect(p.row(0).scale > p.row(150).scale)
        #expect(p.row(150).scale > 1)
        #expect(p.row(0).flatY < p.row(150).flatY)
    }

    @Test func tiltFollowsZoom() {
        #expect(DashPerspective.targetTilt(zoom: 2.9) == 55)
        #expect(DashPerspective.targetTilt(zoom: 0.8) == 55)
        #expect(abs(DashPerspective.targetTilt(zoom: 0.6) - 27.5) < 1e-9)
        #expect(DashPerspective.targetTilt(zoom: 0.4) == 0)
        #expect(DashPerspective.targetTilt(zoom: 0.12) == 0)
    }

    @Test func footprintFitsGroundBuffer() {
        let g = DashPerspective.groundSize, a = DashPerspective.groundAnchor
        let corners = [CGPoint(x: 0, y: 0), CGPoint(x: 526, y: 0),
                       CGPoint(x: 0, y: 300), CGPoint(x: 526, y: 300)]
        var outside = 0
        for i in 0...110 {
            let p = cam(Double(i) / 2)
            for f in footprint(p) + corners.map(cam(0).flat(fromScreen:)) {
                let x = a.x + f.x, y = a.y + f.y
                if x < 4 || x > g.width - 4 || y < 4 || y > g.height - 4 { outside += 1 }
            }
        }
        #expect(outside == 0)
    }

    @Test func zeroTiltWarpCopiesPixels() {
        let gw = Int(DashPerspective.groundSize.width), gh = Int(DashPerspective.groundSize.height)
        let gbpr = gw * 4, fw = 526, fh = 300, fbpr = fw * 4
        var ground = [UInt8](repeating: 0, count: gbpr * gh)
        for i in ground.indices { ground[i] = UInt8(truncatingIfNeeded: (i &* 2_654_435_761) >> 13) }
        var out = [UInt8](repeating: 0, count: fbpr * fh)
        let p = cam(0)
        ground.withUnsafeBufferPointer { g in
            out.withUnsafeMutableBufferPointer { f in
                p.warp(ground: g.baseAddress!, groundBytesPerRow: gbpr, groundWidth: gw, groundHeight: gh,
                       anchor: DashPerspective.groundAnchor, into: f.baseAddress!, frameBytesPerRow: fbpr)
            }
        }
        let ox = Int(DashPerspective.groundAnchor.x - puck.x), oy = Int(DashPerspective.groundAnchor.y - puck.y)
        var diff = 0
        for y in 0..<fh {
            for x in 0..<(fw * 4) where out[y * fbpr + x] != ground[(y + oy) * gbpr + ox * 4 + x] { diff += 1 }
        }
        #expect(diff == 0)
    }

    @Test func skyCoversTheTopOnly() {
        let p = cam(55)
        #expect(p.skyWeights(row: p.opaqueRow).sky == 1)
        #expect(p.skyWeights(row: p.skyBand + 1).sky == 0)
        let bpr = 526 * 4
        var out = [UInt8](repeating: 128, count: bpr * 300)
        var scratch: [Double] = []
        out.withUnsafeMutableBufferPointer { f in
            p.applySky(frame: f.baseAddress!, bytesPerRow: bpr,
                       top: SIMD3(52, 120, 214), horizon: SIMD3(170, 205, 240), scratch: &scratch)
        }
        // Top-left pixel is the sky colour (BGRA)…
        #expect(abs(Int(out[0]) - 214) <= 1)
        #expect(abs(Int(out[1]) - 120) <= 1)
        #expect(abs(Int(out[2]) - 52) <= 2)
        // …and the map under the band is untouched.
        let below = Int(p.skyBand.rounded(.up)) + 1
        #expect(out[(below * bpr)..<((below + 1) * bpr)].allSatisfy { $0 == 128 })
    }

    @Test func coarseLayerCoversFullTiltInAnyDirection() {
        let pts = footprint(cam(55))
        // Coarse: 7×7 z=13 composite (1792 px), rider up to half its 1400 m
        // stride from the centre, at the autozoom floor 0.8 (× 2^(15−13)).
        let coarseMPerPx = 156_543.03392 * cos(50.0 * .pi / 180) / 8192
        let off = 700 / coarseMPerPx
        var misses = 0
        for heading in stride(from: 0.0, to: 360, by: 15) {
            for dir in stride(from: 0.0, to: 360, by: 45) {
                let c = CGPoint(x: off * cos(dir * .pi / 180), y: off * sin(dir * .pi / 180))
                let rect = CGRect(x: c.x - 896, y: c.y - 896, width: 1792, height: 1792)
                if !DashPerspective.covers(rect: rect, scale: 0.8 * 4, headingDegrees: heading, points: pts) {
                    misses += 1
                }
            }
        }
        #expect(misses == 0)
        // The base layer alone (5×5 z=15, centre 350 m behind) can't reach
        // that far: that is what the tilt cap is for.
        let baseOff = 350 / (156_543.03392 * cos(50.0 * .pi / 180) / 32768)
        let base = CGRect(x: -640, y: baseOff - 640, width: 1280, height: 1280)
        #expect(!DashPerspective.covers(rect: base, scale: 0.8, headingDegrees: 0, points: pts))
        #expect(DashPerspective.covers(rect: base, scale: 0.8, headingDegrees: 0, points: footprint(cam(0))))
    }
}
