//
//  VoicePromptSchedulerTests.swift
//  TripperDashPPTests
//
//  Tests the "when to speak" decision logic: each tier fires at most once
//  per maneuver, tiers reset when the maneuver identity changes, and a
//  reroute that inflates distance doesn't re-fire a tier. Pure value type,
//  runs headless.
//

import Testing
@testable import TripperDashPP

struct VoicePromptSchedulerTests {

    @Test func firesFarNearNowOnceEachClosingIn() {
        var s = VoicePromptScheduler()
        let tok = 42
        // Approaching from 1500 m → far window (~1 km).
        #expect(s.onTick(token: tok, distanceMeters: 1500) == nil)
        #expect(s.onTick(token: tok, distanceMeters: 1000) == .far)
        // Still in far window next tick → no repeat.
        #expect(s.onTick(token: tok, distanceMeters: 900) == nil)
        // Near window (~300 m).
        #expect(s.onTick(token: tok, distanceMeters: 300) == .near)
        #expect(s.onTick(token: tok, distanceMeters: 250) == nil)
        // At the turn.
        #expect(s.onTick(token: tok, distanceMeters: 30) == .now)
        #expect(s.onTick(token: tok, distanceMeters: 10) == nil)
    }

    @Test func newManeuverResetsFiredTiers() {
        var s = VoicePromptScheduler()
        #expect(s.onTick(token: 1, distanceMeters: 300) == .near)
        #expect(s.onTick(token: 1, distanceMeters: 30) == .now)
        // Advance to a new maneuver → tiers available again.
        #expect(s.onTick(token: 2, distanceMeters: 300) == .near)
    }

    @Test func startingInsideNearSuppressesLateFar() {
        var s = VoicePromptScheduler()
        // Nav starts with the maneuver already 300 m away — we should get
        // near, and NOT later blurt a far cue if distance briefly rises.
        #expect(s.onTick(token: 7, distanceMeters: 300) == .near)
        // A reroute inflates distance back to 1000 m — not closing, and far
        // was suppressed, so silence.
        #expect(s.onTick(token: 7, distanceMeters: 1000) == nil)
    }

    @Test func onlyFiresWhileClosing() {
        var s = VoicePromptScheduler()
        // First reading establishes lastDistance; a rising distance (moving
        // away, e.g. wrong turn before reroute) must not fire.
        #expect(s.onTick(token: 3, distanceMeters: 250) == .near)
        #expect(s.onTick(token: 3, distanceMeters: 400) == nil)
    }

    @Test func resetClearsEverything() {
        var s = VoicePromptScheduler()
        #expect(s.onTick(token: 5, distanceMeters: 300) == .near)
        s.reset()
        // After reset the same token+distance is treated as fresh.
        #expect(s.onTick(token: 5, distanceMeters: 300) == .near)
    }

    @Test func ignoresNonFiniteAndNegative() {
        var s = VoicePromptScheduler()
        #expect(s.onTick(token: 9, distanceMeters: .infinity) == nil)
        #expect(s.onTick(token: 9, distanceMeters: -1) == nil)
    }
}
