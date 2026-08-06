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
//  ── Audio session coexistence (the load-bearing detail) ──────────────
//
//  `SilentAudioKeeper` already owns the shared `AVAudioSession`, holding it
//  in `.playback` + `.mixWithOthers` so the ride wakelock survives the lock
//  screen without silencing the rider's music. VoiceNavigator MUST share
//  that one session, not open a competing one. The only thing it changes is
//  DUCKING: right before it speaks it re-asserts the category WITH
//  `.duckOthers` so music/podcasts dip for the duration of the prompt, then
//  it restores the plain `.mixWithOthers` category on `didFinish` so the
//  wakelock's silent loop keeps mixing at full level afterwards. Because the
//  synthesizer routes through the same active session, the wakelock is never
//  torn down and re-armed — no gap where iOS could suspend the app.
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
        case info = 0        // reserved (e.g. speed-camera chime) — lowest
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

    // MARK: - Ducking

    /// Re-assert the shared audio session's category with or without
    /// `.duckOthers`. We never call `setActive(false)` here — the session
    /// is owned by `SilentAudioKeeper` and must stay active for the
    /// wakelock. We only flip the ducking option, which iOS applies live.
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
