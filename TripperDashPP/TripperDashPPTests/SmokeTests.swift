//
//  SmokeTests.swift
//  TripperDashPPTests
//
//  Smoke test: proves the TripperDashPPTests bundle builds, links against
//  the app, and can `@testable`-import the app module. This is deliberately
//  the FIRST and only test committed when the target is introduced, so the
//  (Linux-authored, build-unverified) pbxproj target wiring is validated by
//  a green macOS CI run in isolation — before the real weather-along-route
//  logic tests are piled on top.
//
//  Uses Swift Testing (`import Testing`, Xcode 26+), not XCTest.
//

import Testing
@testable import TripperDashPP

struct SmokeTests {
    /// If this compiles and runs, the test target is correctly hosted by
    /// the app and `@testable import` resolves — the whole point of the
    /// scaffolding commit.
    @Test func targetBuildsAndImportsAppModule() {
        #expect(Bool(true))
    }
}
