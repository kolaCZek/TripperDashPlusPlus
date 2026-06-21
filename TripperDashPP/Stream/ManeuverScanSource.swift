//
//  ManeuverScanSource.swift
//  TripperDashPP
//
//  Frame source used during the empirical maneuver-enum scan. Replaces
//  `MapViewSource` while `DashNavSettings.maneuverScanEnabled == true`.
//
//  Renders the current byte huge in the centre of a 526×300 BGRA buffer
//  so a camera pointed at both the iPhone screen and the Tripper TFT
//  can pair the byte with whatever glyph the dash burned in. Two render
//  modes:
//
//   - active byte:  yellow background, hex (`0xNN`) + decimal + index/total
//   - pause:        solid black — clear visual delimiter between bytes
//
//  Cadence: 4 fps is plenty (the content barely changes within a hold
//  window). Matches the dash's own H.264 ingestion rate per better-dash.
//
//  Thread model: ManeuverScannerLoop runs on @MainActor and pokes the
//  current byte / black-frame flag through synchronous setters; the
//  render queue reads those under a lock when composing each frame.
//

import CoreMedia
import CoreVideo
import Foundation
import os.log
import UIKit

final class ManeuverScanSource: FrameSource {

    let frameSize = CGSize(width: 526, height: 300)
    let targetFps = 4

    private let log = Logger(subsystem: "eu.kolaczek.tripperdashpp", category: "ManeuverScanSource")
    private let queue = DispatchQueue(label: "TripperDashPP.ManeuverScanSource", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var frameIndex: UInt64 = 0
    private var pool: CVPixelBufferPool?

    // Shared state mutated by ManeuverScannerLoop (main actor) and
    // read by the render queue. NSLock keeps it simple — these are
    // tiny snapshots, not hot data.
    private let lock = NSLock()
    private var _currentByte: UInt8 = 0
    private var _byteIndex: Int = 0
    private var _byteTotal: Int = 1
    private var _isBlack: Bool = true
    private var _startedAt: Date = Date()

    deinit { stop() }

    // MARK: - Setters called from ManeuverScannerLoop

    func setCurrentByte(_ b: UInt8, index: Int, total: Int) {
        lock.lock()
        _currentByte = b
        _byteIndex = index
        _byteTotal = max(1, total)
        lock.unlock()
    }

    func setBlackFrame(_ black: Bool) {
        lock.lock()
        _isBlack = black
        lock.unlock()
    }

    // MARK: - FrameSource

    func start(onFrame: @escaping (CVPixelBuffer, CMTime) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            self.frameIndex = 0
            self._startedAt = Date()
            self.preparePool()

            let interval = 1.0 / Double(self.targetFps)
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(5))
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                if let (buffer, pts) = self.renderFrame() {
                    onFrame(buffer, pts)
                }
            }
            self.timer = timer
            timer.resume()
            self.log.info("ManeuverScanSource started (\(self.targetFps) fps)")
        }
    }

    func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
            pool = nil
        }
        log.info("ManeuverScanSource stopped after \(self.frameIndex) frames")
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

        // Snapshot shared state under lock so the frame composes from
        // a consistent view even if the loop mutates mid-render.
        lock.lock()
        let byte = _currentByte
        let idx = _byteIndex
        let total = _byteTotal
        let black = _isBlack
        let elapsed = Date().timeIntervalSince(_startedAt)
        lock.unlock()

        draw(into: ctx, width: width, height: height,
             byte: byte, index: idx, total: total,
             isBlack: black, elapsed: elapsed)

        let pts = CMTime(value: CMTimeValue(frameIndex), timescale: CMTimeScale(targetFps))
        frameIndex += 1
        return (buffer, pts)
    }

    private func draw(
        into ctx: CGContext,
        width: Int, height: Int,
        byte: UInt8, index: Int, total: Int,
        isBlack: Bool, elapsed: TimeInterval
    ) {
        let w = CGFloat(width)
        let h = CGFloat(height)

        // Flip CTM so UIKit drawing works unflipped.
        ctx.translateBy(x: 0, y: h)
        ctx.scaleBy(x: 1, y: -1)

        if isBlack {
            ctx.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            return
        }

        // Yellow background. High-contrast: black text on saturated
        // yellow burns into H.264 even at low bitrate, so the video
        // review reads the hex from a single frame grab.
        ctx.setFillColor(red: 1.0, green: 0.92, blue: 0.15, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))

        UIGraphicsPushContext(ctx)
        defer { UIGraphicsPopContext() }

        // Header: scan progress
        let header = String(format: "MANEUVER SCAN  %d / %d", index + 1, total)
        drawText(
            header,
            origin: CGPoint(x: 12, y: 8),
            font: .monospacedSystemFont(ofSize: 16, weight: .bold),
            color: .black
        )

        // Centre: huge hex byte
        let hex = String(format: "0x%02X", byte)
        let hexFont = UIFont(name: "Helvetica-Bold", size: 120)
            ?? .systemFont(ofSize: 120, weight: .heavy)
        let hexAttr: [NSAttributedString.Key: Any] = [
            .font: hexFont,
            .foregroundColor: UIColor.black,
        ]
        let hexAS = NSAttributedString(string: hex, attributes: hexAttr)
        let hexSize = hexAS.size()
        let hexOrigin = CGPoint(
            x: (w - hexSize.width) / 2,
            y: (h - hexSize.height) / 2 - 20
        )
        hexAS.draw(at: hexOrigin)

        // Below hex: decimal value
        let dec = String(format: "dec %d", byte)
        let decFont = UIFont.monospacedSystemFont(ofSize: 22, weight: .semibold)
        let decAS = NSAttributedString(string: dec, attributes: [
            .font: decFont,
            .foregroundColor: UIColor.black,
        ])
        let decSize = decAS.size()
        decAS.draw(at: CGPoint(
            x: (w - decSize.width) / 2,
            y: hexOrigin.y + hexSize.height + 4
        ))

        // Progress bar along the bottom
        let progress = total > 0 ? CGFloat(index + 1) / CGFloat(total) : 0
        let barH: CGFloat = 8
        let barY: CGFloat = h - barH - 6
        ctx.setFillColor(red: 0, green: 0, blue: 0, alpha: 0.25)
        ctx.fill(CGRect(x: 8, y: barY, width: w - 16, height: barH))
        ctx.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: 8, y: barY, width: (w - 16) * progress, height: barH))
    }

    private func drawText(
        _ s: String,
        origin: CGPoint,
        font: UIFont,
        color: UIColor
    ) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
        ]
        NSAttributedString(string: s, attributes: attrs).draw(at: origin)
    }
}
