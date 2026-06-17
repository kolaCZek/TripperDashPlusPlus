//
//  FrameSource.swift
//  TripperDashPP
//
//  Pluggable frame producer for the H.264 streamer. Phase 4 ships a
//  `TestPatternSource` (animated clock + counter + colour blocks) so we
//  can validate the encoder → RTP → fake_dash → ffprobe pipeline without
//  any Mapbox dependency. Phase 5 will add `MapSnapshotSource` that
//  feeds Mapbox MapView renders into the same protocol.
//
//  Frames are delivered as `CVPixelBuffer` (BGRA, 526×300 — native
//  Tripper TFT resolution per better-dash captures) at a caller-
//  controlled cadence. The source owns its own dispatch timer and just
//  hands ready buffers to the supplied callback on a background queue;
//  the encoder downstream handles backpressure by dropping if its
//  compression session is busy.
//

import CoreGraphics
import CoreVideo
import Foundation
import os.log
import UIKit

/// Anything that can produce a stream of pixel buffers. Phase 4 has one
/// implementation (TestPatternSource); Phase 5 adds Mapbox.
protocol FrameSource: AnyObject {
    /// Pixel format and dimensions this source emits.
    var frameSize: CGSize { get }
    var targetFps: Int { get }

    /// Begin producing frames. The callback fires on a background queue;
    /// implementations MUST NOT block on it.
    func start(onFrame: @escaping (CVPixelBuffer, CMTime) -> Void)

    /// Stop producing frames. Safe to call multiple times.
    func stop()
}

// MARK: - Test pattern source

import CoreMedia

/// Generates an animated 526×300 BGRA test pattern at 12 fps:
///   - HH:MM:SS.mmm clock in the upper-left
///   - Frame counter "Frame N" below it
///   - 4-bar colour blocks (red / green / blue / yellow) rotating every second
///   - Diagonal moving bar so motion encoders have to *do* something
///
/// Purpose: prove the whole stream pipeline (VideoToolbox → RTP → fake_dash
/// → ffplay) works end-to-end without dragging Mapbox into the loop.
final class TestPatternSource: FrameSource {

    let frameSize = CGSize(width: 526, height: 300)
    let targetFps = 12

    private let log = Logger(subsystem: "TripperDashPP", category: "TestPattern")
    private let queue = DispatchQueue(label: "TripperDashPP.TestPattern", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var frameIndex: UInt64 = 0
    private var startTime: CFTimeInterval = 0

    private var pool: CVPixelBufferPool?
    private var renderer: UIGraphicsImageRenderer?

    deinit { stop() }

    func start(onFrame: @escaping (CVPixelBuffer, CMTime) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            self.frameIndex = 0
            self.startTime = CACurrentMediaTime()
            self.preparePool()

            let interval = 1.0 / Double(self.targetFps)
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(2))
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                if let (buffer, pts) = self.renderFrame() {
                    onFrame(buffer, pts)
                }
            }
            self.timer = timer
            timer.resume()
            self.log.info("TestPatternSource started (\(self.targetFps) fps, \(Int(self.frameSize.width))x\(Int(self.frameSize.height)))")
        }
    }

    func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
            pool = nil
        }
        log.info("TestPatternSource stopped after \(self.frameIndex) frames")
    }

    // MARK: - Rendering

    private func preparePool() {
        let width = Int(frameSize.width)
        let height = Int(frameSize.height)
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:],
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ]
        var p: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &p)
        if status != kCVReturnSuccess {
            log.error("CVPixelBufferPoolCreate failed: \(status)")
        }
        pool = p
    }

    private func renderFrame() -> (CVPixelBuffer, CMTime)? {
        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard status == kCVReturnSuccess, let buffer else {
            log.error("CVPixelBufferPoolCreatePixelBuffer failed: \(status)")
            return nil
        }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: base,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        draw(into: ctx, width: width, height: height)

        let pts = CMTime(value: CMTimeValue(frameIndex), timescale: CMTimeScale(targetFps))
        frameIndex += 1
        return (buffer, pts)
    }

    private func draw(into ctx: CGContext, width: Int, height: Int) {
        let w = CGFloat(width)
        let h = CGFloat(height)

        // Flip CTM tak, aby drawing API mluvilo UIKit-style (y=0 nahoře,
        // y=h dole). Bez tohoto vychází NSAttributedString.draw upside-down,
        // protože UIKit text API předpokládá flipped y-axis context.
        ctx.translateBy(x: 0, y: h)
        ctx.scaleBy(x: 1, y: -1)

        // Black background.
        ctx.setFillColor(red: 0.05, green: 0.05, blue: 0.08, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))

        // Four rotating colour blocks across the top edge so the encoder
        // produces actual P-frame deltas.
        let colours: [CGColor] = [
            CGColor(red: 1.0, green: 0.2, blue: 0.2, alpha: 1),
            CGColor(red: 0.2, green: 1.0, blue: 0.3, alpha: 1),
            CGColor(red: 0.2, green: 0.4, blue: 1.0, alpha: 1),
            CGColor(red: 1.0, green: 0.9, blue: 0.2, alpha: 1),
        ]
        let phase = Int(frameIndex / UInt64(targetFps)) % colours.count
        let blockW = w / 4
        for i in 0..<4 {
            ctx.setFillColor(colours[(i + phase) % colours.count])
            ctx.fill(CGRect(x: CGFloat(i) * blockW, y: 0, width: blockW, height: 40))
        }

        // Title + clock + frame counter (čte se shora dolů).
        let elapsed = CACurrentMediaTime() - startTime
        let totalMs = Int(elapsed * 1000)
        let hh = (totalMs / 3_600_000) % 24
        let mm = (totalMs / 60_000) % 60
        let ss = (totalMs / 1000) % 60
        let ms = totalMs % 1000
        let clock = String(format: "%02d:%02d:%02d.%03d", hh, mm, ss, ms)

        drawText("TripperDash++ test pattern", in: ctx, at: CGPoint(x: 12, y: 50), fontSize: 14, color: .white)
        drawText(clock,                       in: ctx, at: CGPoint(x: 12, y: 80), fontSize: 24, color: .white)
        drawText("Frame \(frameIndex)",       in: ctx, at: CGPoint(x: 12, y: 115), fontSize: 16, color: .white)

        // Moving vertical bar — gives the encoder motion to compress.
        let barX = CGFloat(frameIndex % UInt64(width))
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 0.35)
        ctx.fill(CGRect(x: barX, y: 180, width: 12, height: 60))
    }

    private func drawText(_ s: String, in ctx: CGContext, at origin: CGPoint, fontSize: CGFloat, color: UIColor) {
        // CTM už je flipnuté v draw(into:), takže UIKit text draw vychází
        // čitelně bez další matematiky.
        UIGraphicsPushContext(ctx)
        defer { UIGraphicsPopContext() }
        let font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
        ]
        let attr = NSAttributedString(string: s, attributes: attrs)
        attr.draw(at: origin)
    }
}
