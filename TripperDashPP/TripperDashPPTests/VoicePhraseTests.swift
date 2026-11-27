//
//  VoicePhraseTests.swift
//  TripperDashPPTests
//
//  Truth-table tests for the spoken-guidance phrase templates. Pure —
//  VoicePhrase has no AVFoundation dependency, so these run headless.
//

import Testing
import Foundation
@testable import TripperDashPP

struct VoicePhraseTests {

    // MARK: - Maneuver, English

    @Test func turnRightNearEnglish() {
        #expect(VoicePhrase.maneuver(.right, tier: .near, language: .english)
                == "In 300 metres, turn right")
    }

    @Test func turnLeftNowEnglish() {
        // "now" tier drops the distance clause.
        #expect(VoicePhrase.maneuver(.left, tier: .now, language: .english)
                == "turn left")
    }

    @Test func turnLeftFarEnglish() {
        #expect(VoicePhrase.maneuver(.left, tier: .far, language: .english)
                == "In one kilometre, turn left")
    }

    // MARK: - Maneuver, Czech

    @Test func turnRightNearCzech() {
        #expect(VoicePhrase.maneuver(.right, tier: .near, language: .czech)
                == "Za tři sta metrů odbočte vpravo")
    }

    @Test func turnLeftNowCzech() {
        #expect(VoicePhrase.maneuver(.left, tier: .now, language: .czech)
                == "odbočte vlevo")
    }

    // MARK: - Roundabout ordinals

    @Test func roundaboutExitEnglish() {
        #expect(VoicePhrase.maneuver(.roundabout(exit: 2, clockwise: false),
                                     tier: .now, language: .english)
                == "at the roundabout, take the second exit")
    }

    @Test func roundaboutExitCzech() {
        #expect(VoicePhrase.maneuver(.roundabout(exit: 3, clockwise: false),
                                     tier: .now, language: .czech)
                == "na kruhovém objezdu třetí výjezd")
    }

    @Test func roundaboutOutOfRangeFallsBack() {
        // Exit 0 / >9 → generic "follow the arrow" phrasing, never crash.
        #expect(VoicePhrase.maneuver(.roundabout(exit: 0, clockwise: false),
                                     tier: .now, language: .english)
                == "at the roundabout, follow the arrow")
        #expect(VoicePhrase.maneuver(.roundabout(exit: 12, clockwise: true),
                                     tier: .now, language: .czech)
                == "na kruhovém objezdu jeďte podle šipky")
    }

    // MARK: - Straight suppression

    @Test func straightSuppressedFarAndNear() {
        // Plain "continue straight" is noise far out — nil until `.now`.
        #expect(VoicePhrase.maneuver(.straight, tier: .far, language: .english) == nil)
        #expect(VoicePhrase.maneuver(.straight, tier: .near, language: .czech) == nil)
        #expect(VoicePhrase.maneuver(.straight, tier: .now, language: .english)
                == "continue straight")
    }

    // MARK: - Non-maneuver prompts

    @Test func reroutingPhrases() {
        #expect(VoicePhrase.rerouting(.czech) == "Přepočítávám trasu.")
        #expect(VoicePhrase.rerouting(.english) == "Recalculating route.")
    }

    @Test func arrivedPhrases() {
        #expect(VoicePhrase.arrived(.czech) == "Dojeli jste do cíle.")
        #expect(VoicePhrase.arrived(.english) == "You have arrived at your destination.")
    }

    // MARK: - Additional languages

    @Test func turnRightNearOtherLanguages() {
        #expect(VoicePhrase.maneuver(.right, tier: .near, language: .german)
                == "In 300 Metern, rechts abbiegen")
        #expect(VoicePhrase.maneuver(.right, tier: .near, language: .french)
                == "Dans 300 mètres, tournez à droite")
        #expect(VoicePhrase.maneuver(.left, tier: .now, language: .italian)
                == "svolta a sinistra")
        #expect(VoicePhrase.maneuver(.left, tier: .now, language: .polish)
                == "skręć w lewo")
        #expect(VoicePhrase.maneuver(.right, tier: .now, language: .slovak)
                == "odbočte vpravo")
        #expect(VoicePhrase.maneuver(.left, tier: .now, language: .spanish)
                == "gire a la izquierda")
    }

    @Test func roundaboutOrdinalsOtherLanguages() {
        #expect(VoicePhrase.maneuver(.roundabout(exit: 2, clockwise: false),
                                     tier: .now, language: .german)
                == "im Kreisverkehr die zweite Ausfahrt nehmen")
        #expect(VoicePhrase.maneuver(.roundabout(exit: 3, clockwise: false),
                                     tier: .now, language: .italian)
                == "alla rotonda, prendi la terza uscita")
        #expect(VoicePhrase.maneuver(.roundabout(exit: 2, clockwise: false),
                                     tier: .now, language: .portuguese)
                == "na rotatória, pegue a segunda saída")
        #expect(VoicePhrase.maneuver(.roundabout(exit: 1, clockwise: false),
                                     tier: .now, language: .hindi)
                == "गोल चक्कर पर पहला निकास लें")
    }

    @Test func imperialEnglishSaysMiles() {
        #expect(VoicePhrase.maneuver(.left, tier: .far, language: .english, imperial: true)
                == "In half a mile, turn left")
        #expect(VoicePhrase.maneuver(.right, tier: .near, language: .english, imperial: true)
                == "In 1000 feet, turn right")
        #expect(VoicePhrase.maneuver(.right, tier: .now, language: .english, imperial: true)
                == "turn right")
        // Languages without imperial phrases keep metric.
        #expect(VoicePhrase.maneuver(.right, tier: .near, language: .german, imperial: true)
                == VoicePhrase.maneuver(.right, tier: .near, language: .german))
    }

    @Test func englishOnAnIndianPhoneUsesTheIndianVoice() {
        #expect(VoiceNavigator.voiceCode("en-GB", region: "IN") == "en-IN")
        #expect(VoiceNavigator.voiceCode("en-GB", region: "GB") == "en-GB")
        #expect(VoiceNavigator.voiceCode("en-GB", region: nil) == "en-GB")
        #expect(VoiceNavigator.voiceCode("hi-IN", region: "IN") == "hi-IN")
    }

    @Test func portugueseAndHindiCompose() {
        #expect(VoicePhrase.maneuver(.right, tier: .near, language: .portuguese)
                == "Em 300 metros, vire à direita")
        #expect(VoicePhrase.maneuver(.left, tier: .far, language: .hindi)
                == "एक किलोमीटर बाद, बाएँ मुड़ें")
        #expect(VoicePhrase.speedLimit(60, language: .hindi) == "गति सीमा 60.")
    }

    @Test func everyLanguageHasNonEmptyPromptsForEveryManeuver() {
        let kinds: [ManeuverKind] = [
            .straight, .slightLeft, .left, .sharpLeft, .slightRight, .right,
            .sharpRight, .uTurnLeft, .uTurnRight, .mergeLeft, .mergeRight,
            .forkLeft, .forkRight, .forkStraight, .exitLeft, .exitRight,
            .roundabout(exit: 2, clockwise: false), .arrive, .ferry, .railroad,
        ]
        for lang in VoiceLanguage.allCases {
            #expect(!VoicePhrase.rerouting(lang).isEmpty)
            #expect(!VoicePhrase.arrived(lang).isEmpty)
            #expect(!VoicePhrase.speedCamera(lang).isEmpty)
            #expect(!lang.lexicon.speedLimit.isEmpty)
            #expect(VoicePhrase.speedLimit(50, language: lang) == "\(lang.lexicon.speedLimit) 50.")
            for k in kinds {
                let p = VoicePhrase.maneuver(k, tier: .now, language: lang)
                #expect(p != nil && !(p ?? "").isEmpty,
                        "empty prompt for \(k) in \(lang.rawValue)")
            }
        }
    }

    // MARK: - Device-language default resolution

    @Test func matchingResolvesSupportedLanguagesRegionAgnostic() {
        #expect(VoiceLanguage.matching(Locale(identifier: "cs_CZ")) == .czech)
        #expect(VoiceLanguage.matching(Locale(identifier: "sk_SK")) == .slovak)
        #expect(VoiceLanguage.matching(Locale(identifier: "de_AT")) == .german)
        #expect(VoiceLanguage.matching(Locale(identifier: "pl_PL")) == .polish)
        #expect(VoiceLanguage.matching(Locale(identifier: "fr_CA")) == .french)
        #expect(VoiceLanguage.matching(Locale(identifier: "es_MX")) == .spanish)
        #expect(VoiceLanguage.matching(Locale(identifier: "it_IT")) == .italian)
        #expect(VoiceLanguage.matching(Locale(identifier: "pt_BR")) == .portuguese)
        #expect(VoiceLanguage.matching(Locale(identifier: "pt_PT")) == .portuguese)
        #expect(VoiceLanguage.matching(Locale(identifier: "hi_IN")) == .hindi)
        // Indian English stays English (most Indian iPhones run English).
        #expect(VoiceLanguage.matching(Locale(identifier: "en_IN")) == .english)
        // English regions all collapse to English.
        #expect(VoiceLanguage.matching(Locale(identifier: "en_US")) == .english)
        #expect(VoiceLanguage.matching(Locale(identifier: "en_GB")) == .english)
    }

    @Test func matchingFallsBackToEnglishForUnsupported() {
        #expect(VoiceLanguage.matching(Locale(identifier: "ja_JP")) == .english)
        #expect(VoiceLanguage.matching(Locale(identifier: "nb_NO")) == .english)
        #expect(VoiceLanguage.matching(Locale(identifier: "nl_NL")) == .english)
    }
}
