//
//  VoicePhrase.swift
//  TripperDashPP
//
//  feat/voice-nav — pure phrase templates for spoken guidance.
//
//  Turns a `ManeuverKind` + a distance-prompt tier into a natural-language
//  sentence in Czech or English. Kept deliberately separate from
//  `VoiceNavigator` (which owns the audio session + synthesizer) so this
//  layer is a PURE function of its inputs — unit-testable on Linux with no
//  AVFoundation, and mirror-able in Python the same way the wire helpers
//  are.
//
//  Design choices:
//   - Phrases derive from `ManeuverKind` (the same enum that drives the
//     dash glyph + the phone HUD arrow), NOT Apple's free-text
//     `instructions`. Apple's strings are verb-heavy, locale-inconsistent,
//     and bake the road name into the verb clause — reusing them would make
//     the spoken cue drift from the glyph the rider sees. One enum → one
//     glyph → one phrase keeps all three channels in lock-step.
//   - Distance is expressed as a spoken tier ("in one kilometre", "in 300
//     metres") rather than a live number, so the phrase is stable and
//     doesn't need re-rounding — the caller (`VoicePromptScheduler`) already
//     decides WHEN to fire each tier.
//

import Foundation

/// Distance tier at which a maneuver prompt is announced. The scheduler
/// fires each tier at most once per maneuver as the rider closes in.
enum VoicePromptTier: Equatable {
    case far        // ~1 km out (highway lead-in) — "in one kilometre, …"
    case near       // ~300 m out — "in 300 metres, …"
    case now        // at the maneuver — just the action, no distance
}

/// Spoken language for guidance. BCP-47 code drives `AVSpeechSynthesisVoice`.
enum VoiceLanguage: String, CaseIterable, Identifiable, Codable {
    case czech = "cs-CZ"
    case english = "en-GB"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .czech:   return "Čeština"
        case .english: return "English"
        }
    }
}

enum VoicePhrase {

    // MARK: - Maneuver prompt

    /// Build the spoken sentence for an upcoming maneuver at a given tier.
    /// Pure — no side effects, no actor state. Returns nil for maneuvers we
    /// deliberately don't voice at a tier (e.g. `.straight` far out is noise).
    static func maneuver(_ kind: ManeuverKind,
                         tier: VoicePromptTier,
                         language: VoiceLanguage) -> String? {
        // "Continue straight" is only worth saying if it's a fork/keep
        // decision, not on every long straight leg. Suppress plain straight.
        if case .straight = kind, tier != .now { return nil }

        let action = actionPhrase(kind, language: language)
        // Arrival is handled by its own dedicated phrase; if it slips
        // through here at `.now`, still speak the action.
        switch tier {
        case .now:
            return action
        case .near, .far:
            guard let dist = distancePhrase(tier: tier, language: language) else {
                return action
            }
            switch language {
            case .czech:   return "\(dist) \(action)"
            case .english: return "\(dist), \(action)"
            }
        }
    }

    // MARK: - Non-maneuver prompts

    static func rerouting(_ language: VoiceLanguage) -> String {
        switch language {
        case .czech:   return "Přepočítávám trasu."
        case .english: return "Recalculating route."
        }
    }

    static func arrived(_ language: VoiceLanguage) -> String {
        switch language {
        case .czech:   return "Dojeli jste do cíle."
        case .english: return "You have arrived at your destination."
        }
    }

    static func speedCamera(_ language: VoiceLanguage) -> String {
        switch language {
        case .czech:   return "Pozor, rychlostní radar."
        case .english: return "Caution, speed camera ahead."
        }
    }

    // MARK: - Building blocks

    /// The distance clause for a tier ("za jeden kilometr" / "in 300 metres").
    /// `.now` has no distance clause.
    private static func distancePhrase(tier: VoicePromptTier, language: VoiceLanguage) -> String? {
        switch (tier, language) {
        case (.far, .czech):    return "Za jeden kilometr"
        case (.far, .english):  return "In one kilometre"
        case (.near, .czech):   return "Za tři sta metrů"
        case (.near, .english): return "In 300 metres"
        case (.now, _):         return nil
        }
    }

    /// The action clause for a maneuver ("odbočte vpravo" / "turn right").
    /// Roundabout carries its exit ordinal.
    static func actionPhrase(_ kind: ManeuverKind, language: VoiceLanguage) -> String {
        switch language {
        case .czech:   return czechAction(kind)
        case .english: return englishAction(kind)
        }
    }

    private static func czechAction(_ kind: ManeuverKind) -> String {
        switch kind {
        case .straight:      return "pokračujte rovně"
        case .slightLeft:    return "držte se vlevo"
        case .left:          return "odbočte vlevo"
        case .sharpLeft:     return "ostře vlevo"
        case .slightRight:   return "držte se vpravo"
        case .right:         return "odbočte vpravo"
        case .sharpRight:    return "ostře vpravo"
        case .uTurnLeft, .uTurnRight:
                             return "otočte se do protisměru"
        case .mergeLeft:     return "připojte se zleva"
        case .mergeRight:    return "připojte se zprava"
        case .forkLeft:      return "na křižovatce se držte vlevo"
        case .forkRight:     return "na křižovatce se držte vpravo"
        case .forkStraight:  return "na křižovatce pokračujte rovně"
        case .exitLeft:      return "sjeďte vlevo"
        case .exitRight:     return "sjeďte vpravo"
        case .roundabout(let exit, _):
            return roundaboutCzech(exit: exit)
        case .arrive, .arriveLeft, .arriveRight:
                             return "jste v cíli"
        case .recalculating: return "přepočítávám trasu"
        case .ferry:         return "najeďte na trajekt"
        case .railroad:      return "pozor, železniční přejezd"
        }
    }

    private static func englishAction(_ kind: ManeuverKind) -> String {
        switch kind {
        case .straight:      return "continue straight"
        case .slightLeft:    return "keep left"
        case .left:          return "turn left"
        case .sharpLeft:     return "make a sharp left"
        case .slightRight:   return "keep right"
        case .right:         return "turn right"
        case .sharpRight:    return "make a sharp right"
        case .uTurnLeft, .uTurnRight:
                             return "make a U-turn"
        case .mergeLeft:     return "merge left"
        case .mergeRight:    return "merge right"
        case .forkLeft:      return "at the fork, keep left"
        case .forkRight:     return "at the fork, keep right"
        case .forkStraight:  return "at the fork, continue straight"
        case .exitLeft:      return "take the exit on the left"
        case .exitRight:     return "take the exit on the right"
        case .roundabout(let exit, _):
            return roundaboutEnglish(exit: exit)
        case .arrive, .arriveLeft, .arriveRight:
                             return "you have arrived"
        case .recalculating: return "recalculating route"
        case .ferry:         return "board the ferry"
        case .railroad:      return "caution, railway crossing"
        }
    }

    /// "na kruhovém objezdu <n>. výjezd" with Czech ordinal; exit 0 → generic.
    private static func roundaboutCzech(exit: Int) -> String {
        guard exit >= 1, exit <= 9 else {
            return "na kruhovém objezdu jeďte podle šipky"
        }
        let ord = ["", "první", "druhý", "třetí", "čtvrtý", "pátý",
                   "šestý", "sedmý", "osmý", "devátý"][exit]
        return "na kruhovém objezdu \(ord) výjezd"
    }

    /// "at the roundabout, take the Nth exit"; exit 0 → generic.
    private static func roundaboutEnglish(exit: Int) -> String {
        guard exit >= 1, exit <= 9 else {
            return "at the roundabout, follow the arrow"
        }
        let ord = ["", "first", "second", "third", "fourth", "fifth",
                   "sixth", "seventh", "eighth", "ninth"][exit]
        return "at the roundabout, take the \(ord) exit"
    }
}
