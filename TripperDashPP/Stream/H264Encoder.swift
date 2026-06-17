//
//  H264Encoder.swift
//  TripperDashPP
//
//  Hardware H.264 encoder built on VideoToolbox's VTCompressionSession.
//
//  Output shape: for every input CVPixelBuffer the caller receives one or
//  more `EncodedNAL`s. Each NAL is delivered as raw bytes (no Annex-B
//  start codes, no length prefix) along with metadata the RTP packetizer
//  needs (type, isKey, timestamp). The encoder extracts SPS+PPS from the
//  format description on keyframes and emits them as separate NALs so the
//  packetizer can either bundle them with the IDR (Tripper expects this)
//  or send them standalone.
//
//  Configuration: baseline profile, 6 fps, ~450 kbps, keyframe every
//  12 frames (2 s). These match what the Tripper dash tolerates per
//  better-dash captures — stock phone app jede 4 fps, 8–12 je horní
//  reliable mez (výš dash decoder blikne), bitrate 300–450 kbps drží
//  Wi-Fi i jitter buffer dashe v pohodě. High profile + B-frames
//  break the firmware decoder. Match snapshotFps in MapSnapshotSource.
//

import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox
import os.log

/// One H.264 NAL unit emitted by the encoder.
struct EncodedNAL {
    enum Kind {
        case sps        // Sequence parameter set (type 7)
        case pps        // Picture parameter set (type 8)
        case idr        // Keyframe (type 5)
        case nonIDR     // P/B frame (type 1)
        case other(UInt8)
    }
    let kind: Kind
    let bytes: Data            // RAW NAL — no start code, no length prefix
    let timestamp: CMTime
    let isKeyframe: Bool

    var nalType: UInt8 {
        bytes.first.map { $0 & 0x1F } ?? 0
    }
}

final class H264Encoder {

    let width: Int32
    let height: Int32
    let fps: Int32
    let bitrate: Int32  // bits / second
    let keyframeInterval: Int32

    /// Set by the owner before `start()`. Called on the encoder's
    /// callback thread for every emitted NAL.
    var onNAL: ((EncodedNAL) -> Void)?

    private let log = Logger(subsystem: "TripperDashPP", category: "H264")
    private var session: VTCompressionSession?
    private var lastFormatDescription: CMFormatDescription?
    /// Set when the next emitted frame must be an IDR. Used after a
    /// session rebuild so the depacketizer can resynchronise without
    /// waiting for the regular keyframe cadence.
    private var pendingForceKeyframe = false
    /// Throttle for noisy `VTCompressionSessionEncodeFrame` errors —
    /// when iOS suspends the app the encoder fails ~12 fps until we
    /// rebuild the session, and we don't want to spam the log file.
    private var consecutiveEncodeErrors = 0

    init(
        width: Int32 = 526,
        height: Int32 = 300,
        fps: Int32 = 6,
        bitrate: Int32 = 450_000,
        keyframeInterval: Int32 = 12
    ) {
        self.width = width
        self.height = height
        self.fps = fps
        self.bitrate = bitrate
        self.keyframeInterval = keyframeInterval
    }

    deinit { stop() }

    // MARK: - Lifecycle

    func start() throws {
        guard session == nil else { return }
        try createSession()
    }

    func stop() {
        guard let session else { return }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)
        self.session = nil
        lastFormatDescription = nil
        pendingForceKeyframe = false
        consecutiveEncodeErrors = 0
        log.info("H264Encoder stopped")
    }

    func forceKeyframeNext() {
        pendingForceKeyframe = true
    }

    // MARK: - Session (re)creation

    private func createSession() throws {
        var s: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil,
            width: width,
            height: height,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &s
        )
        guard status == noErr, let session = s else {
            throw EncoderError.sessionCreateFailed(status)
        }
        self.session = session

        // Property bag — baseline profile, low latency, fixed bitrate.
        let props: [(CFString, CFTypeRef)] = [
            (kVTCompressionPropertyKey_RealTime, kCFBooleanTrue),
            (kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse),
            (kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_Baseline_AutoLevel),
            (kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: bitrate)),
            (kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: fps)),
            (kVTCompressionPropertyKey_MaxKeyFrameInterval, NSNumber(value: keyframeInterval)),
            (kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, NSNumber(value: keyframeInterval / fps)),
            // Data-rate limit: keep bursts close to target bitrate so we
            // don't overflow the Tripper's small jitter buffer.
            (kVTCompressionPropertyKey_DataRateLimits, [NSNumber(value: bitrate / 8 * 2), NSNumber(value: 1)] as CFArray),
        ]
        for (key, value) in props {
            let s = VTSessionSetProperty(session, key: key, value: value)
            if s != noErr {
                log.warning("VTSessionSetProperty \(key as String) failed: \(s)")
            }
        }
        VTCompressionSessionPrepareToEncodeFrames(session)
        // The format description rotates with the rebuilt session, so
        // force the next coded slice to be an IDR + re-emit SPS/PPS.
        lastFormatDescription = nil
        pendingForceKeyframe = true
        log.info("H264Encoder session ready \(self.width)x\(self.height) @ \(self.fps)fps, \(self.bitrate / 1000) kbps")
    }

    /// Tear the current VT session down and build a fresh one. Called
    /// when `VTCompressionSessionEncodeFrame` returns
    /// `kVTInvalidSessionErr` (-12903), which happens any time iOS
    /// briefly suspends the app and reclaims GPU access — most commonly
    /// when the screen locks while streaming. The session itself is
    /// unrecoverable; only a rebuild restores hardware encoding.
    private func rebuildSession() {
        if let s = session {
            VTCompressionSessionInvalidate(s)
            self.session = nil
        }
        do {
            try createSession()
            log.notice("H264Encoder session rebuilt after invalidation")
        } catch {
            log.error("H264Encoder session rebuild failed: \(String(describing: error))")
        }
    }

    // MARK: - Encode

    func encode(pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
        guard let session else { return }
        // Phase 6: when iOS resumes us, the first frame after a session
        // rebuild MUST be an IDR so the dash can re-sync. Same flag is
        // set by createSession() so the very first frame is always a key.
        var frameProperties: [CFString: Any] = [:]
        if pendingForceKeyframe {
            frameProperties[kVTEncodeFrameOptionKey_ForceKeyFrame] = kCFBooleanTrue
            pendingForceKeyframe = false
        }
        var infoFlags = VTEncodeInfoFlags()
        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: presentationTime,
            duration: CMTime(value: 1, timescale: fps),
            frameProperties: frameProperties as CFDictionary,
            infoFlagsOut: &infoFlags
        ) { [weak self] status, _, sampleBuffer in
            self?.handleEncoded(status: status, sampleBuffer: sampleBuffer)
        }
        if status != noErr {
            consecutiveEncodeErrors += 1
            // -12903 kVTInvalidSessionErr — most common cause: app got
            // suspended (screen lock) and lost GPU access. Rebuild the
            // session once; subsequent frames will succeed.
            // -12902 kVTSessionMalfunctionErr — same recovery path.
            if status == -12903 || status == -12902 {
                if consecutiveEncodeErrors == 1 {
                    log.notice("VTCompressionSessionEncodeFrame failed: \(status) — rebuilding session")
                }
                rebuildSession()
            } else if consecutiveEncodeErrors == 1 {
                log.error("VTCompressionSessionEncodeFrame failed: \(status)")
            }
        } else {
            consecutiveEncodeErrors = 0
        }
    }

    // MARK: - Callback

    private func handleEncoded(status: OSStatus, sampleBuffer: CMSampleBuffer?) {
        guard status == noErr, let sampleBuffer, CMSampleBufferDataIsReady(sampleBuffer) else {
            return
        }

        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [[CFString: Any]]
        let isKey: Bool
        if let first = attachments?.first,
           let notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool {
            isKey = !notSync
        } else {
            isKey = true
        }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        // On keyframes, extract SPS+PPS from the format description and
        // emit them BEFORE the IDR so the depacketizer can build a decoder.
        if isKey,
           let fmt = CMSampleBufferGetFormatDescription(sampleBuffer) {
            if !areFormatDescriptionsEqual(fmt, lastFormatDescription) {
                emitParameterSets(from: fmt, at: pts)
                lastFormatDescription = fmt
            } else {
                // Same SPS/PPS, but still re-send on every IDR so a late
                // joiner can pick up the stream without waiting for an
                // encoder restart.
                emitParameterSets(from: fmt, at: pts)
            }
        }

        // The compressed sample buffer holds NALs in AVCC format — each
        // NAL prefixed by a 4-byte big-endian length. Split into raw NALs.
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let bbStatus = CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &length,
            dataPointerOut: &dataPointer
        )
        guard bbStatus == kCMBlockBufferNoErr, let dataPointer else { return }

        let base = UnsafeRawPointer(dataPointer).assumingMemoryBound(to: UInt8.self)
        var offset = 0
        while offset + 4 < length {
            let nalLength = Int(UInt32(base[offset]) << 24 |
                                UInt32(base[offset + 1]) << 16 |
                                UInt32(base[offset + 2]) << 8 |
                                UInt32(base[offset + 3]))
            offset += 4
            guard nalLength > 0, offset + nalLength <= length else { break }
            let bytes = Data(bytes: base.advanced(by: offset), count: nalLength)
            offset += nalLength

            let nalType = bytes.first.map { $0 & 0x1F } ?? 0
            let kind: EncodedNAL.Kind
            switch nalType {
            case 5: kind = .idr
            case 1: kind = .nonIDR
            case 7: kind = .sps
            case 8: kind = .pps
            default: kind = .other(nalType)
            }
            onNAL?(EncodedNAL(kind: kind, bytes: bytes, timestamp: pts, isKeyframe: isKey))
        }
    }

    private func emitParameterSets(from fmt: CMFormatDescription, at pts: CMTime) {
        var spsCount = 0
        let _ = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            fmt, parameterSetIndex: 0,
            parameterSetPointerOut: nil, parameterSetSizeOut: nil,
            parameterSetCountOut: &spsCount, nalUnitHeaderLengthOut: nil
        )
        for i in 0..<spsCount {
            var ptr: UnsafePointer<UInt8>?
            var size = 0
            let s = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                fmt, parameterSetIndex: i,
                parameterSetPointerOut: &ptr, parameterSetSizeOut: &size,
                parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil
            )
            guard s == noErr, let ptr else { continue }
            let bytes = Data(bytes: ptr, count: size)
            let nalType = bytes.first.map { $0 & 0x1F } ?? 0
            let kind: EncodedNAL.Kind = (nalType == 7) ? .sps : (nalType == 8) ? .pps : .other(nalType)
            onNAL?(EncodedNAL(kind: kind, bytes: bytes, timestamp: pts, isKeyframe: true))
        }
    }

    private func areFormatDescriptionsEqual(_ a: CMFormatDescription?, _ b: CMFormatDescription?) -> Bool {
        guard let a, let b else { return false }
        return CMFormatDescriptionEqual(a, otherFormatDescription: b)
    }

    enum EncoderError: Error {
        case sessionCreateFailed(OSStatus)
    }
}
