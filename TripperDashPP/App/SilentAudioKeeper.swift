//
//  SilentAudioKeeper.swift
//  TripperDashPP
//
//  Phase 6 — fallback wakelock via the `audio` UIBackgroundMode.
//
//  CoreLocation `Always` is the primary screen-off wakelock (see
//  `BackgroundLocationKeeper`). This file adds a belt-and-braces
//  fallback: an `AVAudioEngine` that loops a silent PCM buffer through
//  the system mixer. As long as something is actively playing audio
//  with the `audio` background mode declared in Info.plist, iOS will
//  not suspend the app — even if GPS drops out (tunnel, garage).
//
//  We're explicitly mixing with others (`.mixWithOthers`) and ducking
//  nothing, so the user's music / podcast / Mapbox spoken nav keeps
//  playing untouched. The buffer is generated programmatically so
//  there is no .caf / .wav asset to ship.
//
//  Required Info.plist keys (already present in TripperDashPP-Info.plist):
//    - UIBackgroundModes contains "audio"
//

import AVFoundation
import Foundation
import os.log

@MainActor
final class SilentAudioKeeper {

    private let log = Logger(subsystem: "eu.kolaczek.tripperdashpp", category: "SilentAudio")
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var buffer: AVAudioPCMBuffer?
    private(set) var isRunning = false

    // MARK: - Lifecycle

    /// Start the silent-audio wakelock. Idempotent.
    func start() {
        guard !isRunning else { return }

        do {
            try configureSession()
            try setupEngine()
            scheduleLoop()
            try engine.start()
            player.play()
            isRunning = true
            log.info("SilentAudioKeeper started (mixWithOthers, 1 s silent loop)")
        } catch {
            log.error("Failed to start: \(error.localizedDescription)")
            try? AVAudioSession.sharedInstance().setActive(false)
        }

        // If iOS interrupts us (phone call, Siri), AVAudioEngine stops.
        // Resume on `.ended` so the wakelock comes back.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )
    }

    /// Stop the silent-audio wakelock. Idempotent.
    func stop() {
        guard isRunning else { return }
        player.stop()
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        NotificationCenter.default.removeObserver(self, name: AVAudioSession.interruptionNotification, object: nil)
        isRunning = false
        log.info("SilentAudioKeeper stopped")
    }

    // MARK: - Setup

    private func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        // .playback: required for background audio (matches the
        // UIBackgroundModes "audio" entry).
        // .mixWithOthers: let the user keep listening to music, podcasts,
        // or Mapbox spoken nav while we hold the wakelock silently.
        try session.setCategory(
            .playback,
            mode: .default,
            options: [.mixWithOthers]
        )
        try session.setActive(true, options: [])
    }

    private func setupEngine() throws {
        engine.attach(player)
        // Use the engine's main mixer sample rate so we don't pay for
        // any internal rate conversion.
        let format = engine.mainMixerNode.outputFormat(forBus: 0)
        engine.connect(player, to: engine.mainMixerNode, format: format)

        // 1-second PCM buffer of pure silence. The buffer is implicitly
        // zeroed by AVAudioPCMBuffer's initialiser, but we set
        // frameLength explicitly so scheduleBuffer plays the full second.
        guard let buf = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(format.sampleRate)
        ) else {
            throw NSError(
                domain: "TripperDashPP.SilentAudio",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to allocate silent PCM buffer"]
            )
        }
        buf.frameLength = buf.frameCapacity
        self.buffer = buf
    }

    private func scheduleLoop() {
        guard let buffer else { return }
        // .loops: scheduler re-enqueues the same buffer back-to-back
        // until the player is stopped — no callback gymnastics needed.
        player.scheduleBuffer(buffer, at: nil, options: .loops, completionHandler: nil)
    }

    // MARK: - Interruptions

    @objc private func handleInterruption(_ note: Notification) {
        guard
            let info = note.userInfo,
            let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: raw)
        else { return }

        switch type {
        case .began:
            log.info("Audio session interrupted — wakelock paused")
        case .ended:
            log.info("Audio session interruption ended — restoring wakelock")
            do {
                try AVAudioSession.sharedInstance().setActive(true, options: [])
                if !engine.isRunning { try engine.start() }
                player.play()
            } catch {
                log.error("Failed to restore audio session: \(error.localizedDescription)")
            }
        @unknown default:
            break
        }
    }
}
