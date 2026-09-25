//
//  FrameSource.swift
//  TripperDashPP
//
//  Pluggable frame producer for the H.264 streamer. The active
//  navigation pipeline ships a single implementation (`MapViewSource`)
//  that feeds the live MKMapView snapshot stream into the encoder.
//  The protocol stays generic so future sources (offline-tile renderer,
//  diagnostic overlays, etc.) can drop in without touching the streamer.
//
//  Frames are delivered as `CVPixelBuffer` (BGRA, 526×300 — native
//  Tripper TFT resolution per better-dash captures) at a caller-
//  controlled cadence. The source owns its own render loop (MapViewSource:
//  a Swift `Task` ticking on the main actor) and hands ready buffers to the
//  supplied callback;
//  the encoder downstream handles backpressure by dropping if its
//  compression session is busy.
//

import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation

/// Anything that can produce a stream of pixel buffers for the H.264
/// encoder. Implementations: `MapViewSource` (production).
protocol FrameSource: AnyObject {
    /// Pixel format and dimensions this source emits.
    var frameSize: CGSize { get }
    var targetFps: Int { get }

    /// Begin producing frames. The callback fires on the source's own
    /// thread (MapViewSource: main actor); implementations MUST NOT block
    /// on it.
    func start(onFrame: @escaping (CVPixelBuffer, CMTime) -> Void)

    /// Stop producing frames. Safe to call multiple times.
    func stop()
}
