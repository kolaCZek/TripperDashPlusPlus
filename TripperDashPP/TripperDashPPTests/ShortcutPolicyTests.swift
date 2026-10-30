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
                          shortcutConnect: Bool = true,
                          handConnectedRecently: Bool = false,
                          linkSilent: Bool = false,
                          canConnect: Bool = true) -> ShortcutPolicy.FreeRide {
        ShortcutPolicy.freeRide(rideActive: rideActive, requestPending: requestPending,
                                planStaged: planStaged, link: link,
                                shortcutConnect: shortcutConnect,
                                handConnectedRecently: handConnectedRecently,
                                linkSilent: linkSilent, canConnect: canConnect)
    }

    /// The app's own Wi-Fi join fires the automation: a connect the rider
    /// started by hand (no plan, to pick a destination) stays theirs.
    @Test func aHandStartedConnectIsLeftAlone() {
        #expect(freeRide(link: .connecting, shortcutConnect: false) == .handConnecting)
        #expect(freeRide(link: .handshaking, shortcutConnect: false) == .handConnecting)
        // A handshake that finished before the automation ran.
        #expect(freeRide(link: .connected, handConnectedRecently: true) == .handConnected)
        #expect(freeRide(planStaged: true, link: .connecting, shortcutConnect: false) == .planStaged)
        #expect(freeRide(rideActive: true, link: .reconnecting, shortcutConnect: false) == .alreadyRiding)
        #expect(freeRide(link: .idle, shortcutConnect: false) == .connect)
    }

    /// A reconnect never joins Wi-Fi: the join is the bike coming back
    /// after a stop, so the free ride starts once the link is up.
    @Test func aBikeBackAfterAStopStartsTheRide() {
        #expect(freeRide(link: .reconnecting, shortcutConnect: false) == .waitForLink)
        // The app slept on a .connected link and the dash rebooted.
        #expect(freeRide(link: .connected, linkSilent: true) == .reconnectLink)
        #expect(freeRide(link: .connected, handConnectedRecently: true, linkSilent: true) == .reconnectLink)
        #expect(freeRide(rideActive: true, link: .connected, linkSilent: true) == .alreadyRiding)
    }

    @Test func rejoiningTheBikeWiFiMidRideDoesNothing() {
        // A drop leaves the link reconnecting with the ride still on.
        #expect(freeRide(rideActive: true, link: .reconnecting) == .alreadyRiding)
        #expect(freeRide(rideActive: true, link: .connected) == .alreadyRiding)
    }

    @Test func aRideWhoseLinkGaveUpReconnects() {
        // Bike off past the reconnect budget: the Wi-Fi automation brings it back.
        #expect(freeRide(rideActive: true, link: .error("timed out")) == .reconnect)
        #expect(freeRide(rideActive: true, link: .idle) == .reconnect)
        #expect(freeRide(rideActive: true, link: .error("x"), canConnect: false) == .alreadyRiding)
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
        #expect(ShortcutPolicy.navigate(navigating: true, arrived: false, handPlanStaged: false) == .redirect)
        #expect(ShortcutPolicy.navigate(navigating: false, arrived: false, handPlanStaged: false) == .stage)
        // Between arrival and the switch to free ride, replacePlan refuses.
        #expect(ShortcutPolicy.navigate(navigating: true, arrived: true, handPlanStaged: false) == .finishingArrival)
    }

    @Test func aHandBuiltPlanIsNeverReplaced() {
        #expect(ShortcutPolicy.navigate(navigating: false, arrived: false, handPlanStaged: true) == .handPlanStaged)
        // Mid-navigation a new destination still redirects.
        #expect(ShortcutPolicy.navigate(navigating: true, arrived: false, handPlanStaged: true) == .redirect)
        // The navigation ended or was replaced while Siri asked: never act on another ride.
        #expect(ShortcutPolicy.navigate(navigating: false, arrived: false, handPlanStaged: false, rideChanged: true) == .rideChanged)
        #expect(ShortcutPolicy.navigate(navigating: true, arrived: false, handPlanStaged: false, rideChanged: true) == .rideChanged)
    }
}
