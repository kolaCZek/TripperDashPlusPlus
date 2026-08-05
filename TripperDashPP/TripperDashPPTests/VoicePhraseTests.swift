//
//  VoicePhraseTests.swift
//  TripperDashPPTests
//
//  Truth-table tests for the spoken-guidance phrase templates. Pure —
//  VoicePhrase has no AVFoundation dependency, so these run headless.
//

import Testing
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
}
