//
//  VoiceNavigator.swift
//  TripperDashPP
//
//  feat/voice-nav — spoken turn-by-turn guidance.
//
//  Speaks maneuver prompts ("In 300 metres, turn right", "Recalculating",
//  "You have arrived") through the phone's speaker / connected Bluetooth
//  headset while the rider follows a route. Offline, keyless, account-free
//  via `AVSpeechSynthesizer` — consistent with the app's free-account
//  stance (no cloud TTS, no API key).
//
//  ── Audio session ownership (the load-bearing detail) ───────────────
//
//  VoiceNavigator OWNS the shared `AVAudioSession` for spoken guidance.
//  It configures the session as `.playback` + `.mixWithOthers` (so the
//  rider's music/podcast keeps playing) and, crucially, keeps it ACTIVE
//  for the whole ride so a prompt can play over the LOCKED screen — the
//  `audio` UIBackgroundMode in Info.plist is what makes that legal, and
//  it is backed by this real audio feature (not a silent-loop wakelock).
//  Right before it speaks it re-asserts the category WITH `.duckOthers`
//  so music dips for the prompt, then restores plain `.mixWithOthers` on
//  `didFinish`. The session is activated on `startSession()` (called when
//  streaming begins) and never torn down mid-ride, so there is no gap
//  where a prompt would be routed to a dead session.
//
//  NOTE: the app's background survival does NOT depend on audio — that is
//  owned entirely by CoreLocation `Always` updates (see `LocationService`).
//  Audio here is purely the spoken-guidance feature.
//
//  ── Queueing / priority ──────────────────────────────────────────────
//
//  Prompts are time-sensitive: a "in 300 m" cue is worthless once the rider
//  is at the turn. So the queue is shallow and priority-ordered — a fresh
//  maneuver/arrival/reroute prompt CANCELS whatever lower-priority thing is
//  mid-sentence rather than waiting behind it. Same-or-higher priority
//  prompts are dropped if one is already speaking within the same beat to
//  avoid stutter.
//
//  Actor isolation: @MainActor — matches AVSpeechSynthesizer's delegate
//  callbacks and the ActiveNavLoop/AppStatus that drive it, so no hops.
//

import AVFoundation
import Foundation
import os.log

@MainActor
final class VoiceNavigator: NSObject {

    private let log = Logger(subsystem: "eu.kolaczek.tripperdashpp", category: "VoiceNav")
    private let synth = AVSpeechSynthesizer()

    /// Priority of a spoken prompt. A higher-priority prompt interrupts a
    /// lower-priority one that is mid-sentence.
    enum Priority: Int, Comparable {
        case maneuver = 1    // "in 300 m, turn right"
        case critical = 2    // arrival, reroute — always cut through
        static func < (l: Priority, r: Priority) -> Bool { l.rawValue < r.rawValue }
    }

    /// Priority of whatever is currently being spoken, for interrupt logic.
    private var speakingPriority: Priority?

    /// Whether voice output is globally enabled (mirrors the user setting;
    /// AppStatus keeps this in sync). When false, `speak` is a no-op.
    var enabled: Bool = true

    override init() {
        super.init()
        synth.delegate = self
    }

    // MARK: - Public API

    /// Speak a phrase in the given BCP-47 language, at the given priority.
    /// Higher priority interrupts a lower-priority utterance in flight;
    /// equal/lower priority is dropped while something is already speaking.
    func speak(_ phrase: String, language: String, priority: Priority) {
        guard enabled else { return }
        let trimmed = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if synth.isSpeaking {
            // Only pre-empt strictly-lower-priority speech; otherwise let
            // the current sentence finish so we don't stutter.
            if let cur = speakingPriority, priority > cur {
                synth.stopSpeaking(at: .immediate)
            } else {
                log.debug("drop prompt (busy, prio \(priority.rawValue) ≤ \(self.speakingPriority?.rawValue ?? -1)): \(trimmed, privacy: .public)")
                return
            }
        }

        duckOthers(true)
        let utt = AVSpeechUtterance(string: trimmed)
        utt.voice = Self.resolveVoice(language: language)
        // Slightly slower than default reads clearer over wind / a helmet
        // intercom without sounding robotic.
        utt.rate = AVSpeechUtteranceDefaultSpeechRate * 0.96
        utt.postUtteranceDelay = 0.0
        speakingPriority = priority
        log.info("speak[\(priority.rawValue)] \(language, privacy: .public): \(trimmed, privacy: .public)")
        synth.speak(utt)
    }

    /// Stop any in-flight speech and un-duck. Called on stop-streaming /
    /// nav teardown so a half-spoken prompt doesn't hang the duck.
    func stop() {
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        speakingPriority = nil
        duckOthers(false)
    }

    // MARK: - Session lifecycle

    /// Activate the shared audio session for the ride. Called when
    /// streaming starts. Configures `.playback` + `.mixWithOthers` and
    /// activates it so spoken prompts can play over the locked screen
    /// (backed by the `audio` UIBackgroundMode). Idempotent — iOS
    /// tolerates re-activating an already-active session.
    func startSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .voicePrompt, options: [.mixWithOthers])
            try session.setActive(true, options: [])
            log.info("audio session active (playback/voicePrompt, mixWithOthers)")
        } catch {
            log.error("startSession failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Deactivate the shared audio session on nav/stream teardown so we
    /// stop holding audio focus. Notifies others so their audio un-ducks.
    func stopSession() {
        stop()
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setActive(false, options: [.notifyOthersOnDeactivation])
            log.info("audio session deactivated")
        } catch {
            log.error("stopSession failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Ducking

    /// Re-assert the shared audio session's category with or without
    /// `.duckOthers`. We never call `setActive(false)` here — the session
    /// stays active for the whole ride (see `startSession`/`stopSession`).
    /// We only flip the ducking option, which iOS applies live.
    private func duckOthers(_ duck: Bool) {
        let session = AVAudioSession.sharedInstance()
        var options: AVAudioSession.CategoryOptions = [.mixWithOthers]
        if duck { options.insert(.duckOthers) }
        do {
            try session.setCategory(.playback, mode: .voicePrompt, options: options)
        } catch {
            log.error("duck(\(duck)) setCategory failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Voice resolution

    /// Resolve a concrete `AVSpeechSynthesisVoice` for a BCP-47 language,
    /// falling back to the language's default voice and finally to the
    /// system default so a missing regional voice never silences guidance.
    nonisolated static func resolveVoice(language: String) -> AVSpeechSynthesisVoice? {
        AVSpeechSynthesisVoice(language: language)
            ?? AVSpeechSynthesisVoice(language: String(language.prefix(2)))
    }
}

// MARK: - AVSpeechSynthesizerDelegate

extension VoiceNavigator: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.speakingPriority = nil
            self.duckOthers(false)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            // A cancel is only from a higher-priority interrupt (which
            // immediately speaks its own utterance and re-ducks) or from
            // stop(). In both cases clearing state is correct; the incoming
            // utterance re-asserts the duck itself.
            self.speakingPriority = nil
        }
    }
}
