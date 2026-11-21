//
//  SmokeTests.swift
//  TripperDashPPTests
//
//  Smoke test: proves the TripperDashPPTests bundle builds, links against
//  the app, and can `@testable`-import the app module. It was the first
//  test committed when the target was introduced, so the pbxproj target
//  wiring was validated by a green macOS CI run in isolation; it stays as
//  the minimal "target links and hosts" canary.
//
//  Uses Swift Testing (`import Testing`, Xcode 26+), not XCTest.
//

import Testing
@testable import TripperDashPP

struct SmokeTests {
    /// If this compiles and runs, the test target is correctly hosted by
    /// the app and `@testable import` resolves.
    @Test func targetBuildsAndImportsAppModule() {
        #expect(Bool(true))
    }
}
