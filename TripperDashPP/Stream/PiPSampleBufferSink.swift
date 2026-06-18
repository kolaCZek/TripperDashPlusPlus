//
//  PiPSampleBufferSink.swift
//  TripperDashPP
//
//  Phase 8 — Apple-blessed background runtime via Picture-in-Picture.
//
//  Why this exists:
//  ----------------
//  MKMapSnapshotter is aggressively throttled by iOS when the app is
//  backgrounded (screen lock with the phone in your pocket). The map
//  freezes on the last good frame mid-jízda even though our GPS
//  wakelock keeps the process alive. PiP fixes this end-to-end:
//
//    - PiP marks the app as a "video player" in iOS scheduler eyes.
//    - The process gets full runtime + GPU access while PiP is active,
//      identical to foreground state.
//    - Display power is irrelevant — display off ≠ process suspended.
//      PiP keeps GPU + Metal + tile fetch online with the screen black.
//    - Apple explicitly targets nav apps for this with
//      `canStartPictureInPictureAutomaticallyFromInline = true`
//      (iOS 14.2+). Waze and Google Maps do exactly this.
//
//  Architecture:
//  -------------
//  We expose a tiny `PiPHostView` (UIViewRepresentable wrapping a
//  UIView whose backing layer is an AVSampleBufferDisplayLayer) that
//  StreamingView mounts as a visible preview. RtpStreamer fan-outs
//  encoded CVPixelBuffers into the sink — once to the H.264 encoder
//  (existing path → bike dash), once to this layer (new path → PiP).
//
//  Visible inline = App Store clean. Apple's guideline 2.5.x requires
//  the PiP source to be visible at some point in normal use. The
//  preview also doubles as a "what does the dash see" diagnostic.
//
//  Auto-PiP on background:
//  -----------------------
//  When the app transitions to .background (screen lock, home button,
//  app switcher), iOS auto-promotes our inline layer to floating PiP
//  bubble if `canStartPictureInPictureAutomaticallyFromInline` is set
//  on a ready controller. We never call start() ourselves — iOS does.
//
//  If the user manually dismisses the bubble (tap X), iOS gives us
//  pictureInPictureControllerDidStopPictureInPicture and the app loses
//  background runtime ~30 s later. We log a warning so it's visible in
//  diagnostics, but UX-wise the user explicitly said "stop", so we
//  honour it.
//

import AVKit
import CoreMedia
import CoreVideo
import Foundation
import os.log
import SwiftUI
import UIKit

// MARK: - View backing layer host

/// UIView subclass whose `layer` IS an AVSampleBufferDisplayLayer.
/// Trick from AVFoundation samples — overriding `layerClass` lets the
/// view's backing layer be a sample buffer layer directly, no nested
/// CALayer hierarchy, no z-order surprises.
final class SampleBufferHostView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }

    var displayLayer: AVSampleBufferDisplayLayer {
        // swiftlint:disable:next force_cast
        layer as! AVSampleBufferDisplayLayer
    }
}

// MARK: - Sink

/// Receives CVPixelBuffers from the frame source and:
///   - enqueues them into the AVSampleBufferDisplayLayer (visible
///     preview + PiP source),
///   - drives the AVPictureInPictureController so iOS auto-promotes
///     us to floating PiP on background.
///
/// Threading: enqueue happens off the main thread (RtpStreamer
/// background queue). AVSampleBufferDisplayLayer accepts buffers from
/// any thread — it serialises internally onto the render loop.
/// AVPictureInPictureController mutations MUST be on main; we hop
/// when we wire up the controller.
@MainActor
final class PiPSampleBufferSink: NSObject {

    private let log = Logger(subsystem: "TripperDashPP", category: "PiPSink")

    /// The display layer we feed. Created lazily once the host view
    /// mounts; the host view installs itself here via `attach(_:)`.
    private weak var hostView: SampleBufferHostView?

    /// PiP controller. iOS 15+ initialiser that targets a sample
    /// buffer playback source (vs the old AVPlayer-backed one). We
    /// implement the playback delegate to feed it our own state.
    private var pipController: AVPictureInPictureController?

    /// Whether PiP should start automatically when the app moves to
    /// background. Defaults to true (the whole point of this class).
    var autoPiPOnBackground: Bool = true {
        didSet { pipController?.canStartPictureInPictureAutomaticallyFromInline = autoPiPOnBackground }
    }

    /// Reusable CMVideoFormatDescription. The encoder always emits
    /// 526×300 BGRA so we can cache the description once instead of
    /// rebuilding it per frame.
    private var formatDescription: CMVideoFormatDescription?

    /// Frame counter for synthesising presentation timestamps when
    /// the source's PTS is monotonically increasing inside one stream
    /// session (matches our snapshotter behaviour) but resets across
    /// sessions. AVSampleBufferDisplayLayer hard-fails if PTS goes
    /// backwards.
    private var sessionFrameIndex: Int64 = 0
    private let timescale: CMTimeScale = 600   // generic 600 Hz timebase

    // MARK: Wiring

    /// Called by `PiPHostView` (the SwiftUI representable) once its
    /// UIView is in the hierarchy. We need the layer reference before
    /// we can construct the PiP controller.
    func attach(hostView: SampleBufferHostView) {
        self.hostView = hostView
        hostView.displayLayer.videoGravity = .resizeAspect
        setupPiPController()
    }

    /// Detach when the host view goes away (view torn down, e.g. user
    /// navigates away from StreamingView). PiP itself can keep going
    /// independently of view lifecycle once started — but if the
    /// inline source disappears, iOS will end PiP for us.
    func detach() {
        flushQueue()
        pipController = nil
        hostView = nil
        formatDescription = nil
    }

    private func setupPiPController() {
        guard let hostView else { return }
        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            log.warning("PiP not supported on this device — background map render will degrade")
            return
        }

        // iOS 15+ initialiser that takes a content source. Required
        // for our use-case because we're not playing back an AVAsset
        // — we're pushing live CVPixelBuffers from the snapshotter.
        let source = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: hostView.displayLayer,
            playbackDelegate: self
        )
        let controller = AVPictureInPictureController(contentSource: source)
        controller.canStartPictureInPictureAutomaticallyFromInline = autoPiPOnBackground
        controller.delegate = self
        pipController = controller
        log.info("PiP controller ready (autoStartFromInline=\(self.autoPiPOnBackground))")
    }

    // MARK: Frame ingest

    /// Push a CVPixelBuffer into the layer. Safe to call from any
    /// thread; AVSampleBufferDisplayLayer is thread-safe for enqueue.
    nonisolated func push(_ pixelBuffer: CVPixelBuffer, presentationTime _: CMTime) {
        Task { @MainActor in
            self.enqueue(pixelBuffer)
        }
    }

    private func enqueue(_ pixelBuffer: CVPixelBuffer) {
        guard let layer = hostView?.displayLayer else { return }

        // Build (or reuse) the format description.
        if formatDescription == nil {
            var fmt: CMVideoFormatDescription?
            let status = CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: pixelBuffer,
                formatDescriptionOut: &fmt
            )
            guard status == noErr, let fmt else {
                log.error("CMVideoFormatDescriptionCreateForImageBuffer failed: \(status)")
                return
            }
            formatDescription = fmt
        }

        // Synthesise monotonic PTS in our own timebase so PiP layer
        // doesn't reject frames if the snapshot source resets PTS at
        // session boundaries.
        let pts = CMTime(value: sessionFrameIndex, timescale: timescale)
        let frameDurationTicks = Int64(timescale) / 6   // 6 fps in 600 Hz units = 100
        sessionFrameIndex &+= frameDurationTicks

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: frameDurationTicks, timescale: timescale),
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )

        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription!,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else {
            log.error("CMSampleBufferCreateReadyWithImageBuffer failed: \(status)")
            return
        }

        // Mark "display immediately" so the layer doesn't try to
        // schedule against its own timebase — we're a live feed, not
        // a clip on a timeline.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true) {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }

        layer.enqueue(sampleBuffer)

        // Recover from "failed to decode" state by flushing. Happens
        // if the layer rejected a frame (e.g. PTS regression after
        // app foregrounded). Cheap to call; no-op when healthy.
        if layer.status == .failed {
            log.warning("Display layer failed (\(layer.error?.localizedDescription ?? "nil")) — flushing")
            layer.flush()
            sessionFrameIndex = 0
            formatDescription = nil
        }
    }

    private func flushQueue() {
        hostView?.displayLayer.flushAndRemoveImage()
        sessionFrameIndex = 0
    }
}

// MARK: - PiP playback delegate

extension PiPSampleBufferSink: AVPictureInPictureSampleBufferPlaybackDelegate {

    // We're "playing" as long as frames are being pushed. The
    // controller uses this to draw the play/pause button in the PiP
    // bubble; pausing in PiP isn't meaningful for live nav so we just
    // ignore the user-initiated pause.
    nonisolated func pictureInPictureController(_: AVPictureInPictureController,
                                                setPlaying _: Bool) {
        // No-op. Map is always "live"; there's no pause semantics.
    }

    // Render size hint — iOS asks how big the PiP bubble should be.
    // Match the source frame so the bubble keeps the dash aspect.
    nonisolated func pictureInPictureControllerTimeRangeForPlayback(_: AVPictureInPictureController)
        -> CMTimeRange {
        // Indefinite live stream → use positiveInfinity duration.
        // iOS treats this as "unbounded live".
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }

    nonisolated func pictureInPictureControllerIsPlaybackPaused(_: AVPictureInPictureController) -> Bool {
        false   // always live
    }

    nonisolated func pictureInPictureController(_: AVPictureInPictureController,
                                                didTransitionToRenderSize _: CMVideoDimensions) {
        // We don't react to render-size changes — the snapshotter is
        // fixed at 526×300 regardless of PiP bubble size; iOS scales
        // for us with .resizeAspect on the display layer.
    }

    nonisolated func pictureInPictureController(_: AVPictureInPictureController,
                                                skipByInterval _: CMTime,
                                                completion: @escaping () -> Void) {
        // No-op — live stream has no skip semantics. Acknowledge so
        // the controller doesn't hang waiting on the callback.
        // (iOS 26 renamed `completionHandler:` → `completion:`.)
        completion()
    }
}

// MARK: - PiP lifecycle delegate

extension PiPSampleBufferSink: AVPictureInPictureControllerDelegate {

    nonisolated func pictureInPictureControllerWillStartPictureInPicture(_: AVPictureInPictureController) {
        Task { @MainActor in self.log.info("PiP will start (app backgrounding or user request)") }
    }

    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_: AVPictureInPictureController) {
        Task { @MainActor in self.log.info("PiP started — background runtime granted") }
    }

    nonisolated func pictureInPictureController(_: AVPictureInPictureController,
                                                failedToStartPictureInPictureWithError error: any Error) {
        Task { @MainActor in
            self.log.error("PiP failed to start: \(error.localizedDescription)")
        }
    }

    nonisolated func pictureInPictureControllerWillStopPictureInPicture(_: AVPictureInPictureController) {
        Task { @MainActor in self.log.info("PiP will stop") }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_: AVPictureInPictureController) {
        Task { @MainActor in
            self.log.warning("PiP stopped — app will lose background runtime in ~30 s if it doesn't return to foreground")
        }
    }
}

// MARK: - SwiftUI bridge

/// Mount this in StreamingView. It owns the UIView whose layer is the
/// AVSampleBufferDisplayLayer, and registers itself with the sink so
/// the sink can build the PiP controller against it.
struct PiPHostView: UIViewRepresentable {
    let sink: PiPSampleBufferSink

    func makeUIView(context _: Context) -> SampleBufferHostView {
        let v = SampleBufferHostView()
        v.backgroundColor = .black
        v.layer.cornerRadius = 8
        v.layer.masksToBounds = true
        sink.attach(hostView: v)
        return v
    }

    func updateUIView(_: SampleBufferHostView, context _: Context) {
        // Nothing to update — sink owns lifecycle.
    }

    static func dismantleUIView(_: SampleBufferHostView, coordinator _: ()) {
        // The sink keeps a weak reference; let ARC clean up naturally.
        // Not calling sink.detach() here because the parent view
        // (StreamingView) holds the sink in @State and is responsible
        // for tearing it down when streaming stops.
    }
}
