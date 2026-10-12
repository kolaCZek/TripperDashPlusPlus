//
//  ShortcutPolicyTests.swift
//  TripperDashPPTests
//
//  `ShortcutPolicy` decides what a Shortcuts / Siri action does in each app
//  state. The case that matters most: a "joined the bike's Wi-Fi"
//  automation fires again when the phone rejoins after a drop mid-ride, and
//  must not start a second ride or throw away a planned route.
//

import Testing
@testable import TripperDashPP

@MainActor
struct ShortcutPolicyTests {

    private func freeRide(rideActive: Bool = false,
                          requestPending: Bool = false,
                          planStaged: Bool = false,
                          link: BikeLink.LinkState = .idle,
                          canConnect: Bool = true) -> ShortcutPolicy.FreeRide {
        ShortcutPolicy.freeRide(rideActive: rideActive, requestPending: requestPending,
                                planStaged: planStaged, link: link, canConnect: canConnect)
    }

    @Test func rejoiningTheBikeWiFiMidRideDoesNothing() {
        // A drop leaves the link reconnecting with the ride still on.
        #expect(freeRide(rideActive: true, link: .reconnecting) == .alreadyRiding)
        #expect(freeRide(rideActive: true, link: .connected) == .alreadyRiding)
    }

    @Test func aSecondTriggerWhileStartingDoesNothing() {
        #expect(freeRide(requestPending: true, link: .connecting) == .alreadyStarting)
    }

    @Test func aPlannedRouteIsKept() {
        #expect(freeRide(planStaged: true, link: .connected) == .planStaged)
    }

    @Test func startsByLinkState() {
        #expect(freeRide(link: .connected) == .startNow)
        #expect(freeRide(link: .connecting) == .waitForLink)
        #expect(freeRide(link: .handshaking) == .waitForLink)
        #expect(freeRide(link: .reconnecting) == .waitForLink)
        #expect(freeRide(link: .idle) == .connect)
        #expect(freeRide(link: .error("x")) == .connect)
        #expect(freeRide(link: .idle, canConnect: false) == .noBike)
    }

    @Test func aNewDestinationRedirectsARunningNavigation() {
        #expect(ShortcutPolicy.navigate(navigating: true, arrived: false) == .redirect)
        #expect(ShortcutPolicy.navigate(navigating: false, arrived: false) == .stage)
        // Between arrival and the switch to free ride, replacePlan refuses.
        #expect(ShortcutPolicy.navigate(navigating: true, arrived: true) == .finishingArrival)
    }
}
