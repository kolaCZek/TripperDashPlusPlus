//
//  ReconnectBudgetTests.swift
//  TripperDashPPTests
//
//  `BikeLink.dropEpisodeDeadline` decides whether a link drop starts a fresh
//  reconnect budget or carries the running one over. A dash that handshakes
//  and then goes quiet used to reset the budget on every connect → drop
//  cycle and reconnect forever; these tests pin the carry-over.
//

import Testing
import Foundation
@testable import TripperDashPP

struct ReconnectBudgetTests {

    private let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

    @Test func shortLivedLinkKeepsTheRunningDeadline() {
        let carried = now.addingTimeInterval(600)
        let deadline = BikeLink.dropEpisodeDeadline(
            now: now,
            connectedAt: now.addingTimeInterval(-10),
            carriedDeadline: carried)
        #expect(deadline == carried)
    }

    @Test func stableLinkStartsAFreshBudget() {
        let deadline = BikeLink.dropEpisodeDeadline(
            now: now,
            connectedAt: now.addingTimeInterval(-(K1G.stableLinkDuration + 1)),
            carriedDeadline: now.addingTimeInterval(600))
        #expect(deadline == now.addingTimeInterval(K1G.reconnectMaxDuration))
    }

    @Test func firstDropStartsAFreshBudget() {
        let deadline = BikeLink.dropEpisodeDeadline(
            now: now,
            connectedAt: now.addingTimeInterval(-10),
            carriedDeadline: nil)
        #expect(deadline == now.addingTimeInterval(K1G.reconnectMaxDuration))
    }
}
