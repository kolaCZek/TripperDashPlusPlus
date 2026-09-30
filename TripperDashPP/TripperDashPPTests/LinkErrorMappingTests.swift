//
//  LinkErrorMappingTests.swift
//  TripperDashPPTests
//
//  Bike-link error classification: which heartbeat send errnos are a
//  transient hiccup (not a link drop), and how NEHotspotConfiguration apply
//  errors map to rider-readable join outcomes.
//

import Testing
import Foundation
import NetworkExtension
@testable import TripperDashPP

@MainActor
struct LinkErrorMappingTests {

    private func sendError(_ code: Int32) -> NSError {
        NSError(domain: "DashSocket", code: Int(code))
    }

    @Test func fullSendBufferIsTransient() {
        #expect(HeartbeatLoop.isTransientSendError(sendError(ENOBUFS)))
        #expect(HeartbeatLoop.isTransientSendError(sendError(EAGAIN)))
        #expect(HeartbeatLoop.isTransientSendError(sendError(EWOULDBLOCK)))
    }

    @Test func realSendFailuresAreNotTransient() {
        #expect(!HeartbeatLoop.isTransientSendError(sendError(ENETUNREACH)))
        #expect(!HeartbeatLoop.isTransientSendError(sendError(EHOSTUNREACH)))
        #expect(!HeartbeatLoop.isTransientSendError(NSError(domain: "DashSocket", code: -4)))
        // Same number, different domain: not a sendto errno.
        #expect(!HeartbeatLoop.isTransientSendError(NSError(domain: "Other", code: Int(ENOBUFS))))
    }

    private func joinError(_ code: NEHotspotConfigurationError) -> NSError {
        NSError(domain: NEHotspotConfigurationErrorDomain, code: code.rawValue)
    }

    @Test func alreadyAssociatedIsSuccess() {
        #expect(WiFiJoiner.outcome(forApplyError: joinError(.alreadyAssociated)) == .alreadyJoined)
    }

    @Test func pendingKeepsWaiting() {
        #expect(WiFiJoiner.outcome(forApplyError: joinError(.pending)) == nil)
    }

    @Test func knownCodesGetReadableText() {
        #expect(WiFiJoiner.outcome(forApplyError: joinError(.userDenied)) == .failed("the join was declined"))
        #expect(WiFiJoiner.outcome(forApplyError: joinError(.invalidSSID)) == .failed("the Wi-Fi name looks wrong"))
    }

    @Test func unknownCodeKeepsTheNumber() {
        #expect(WiFiJoiner.outcome(forApplyError: joinError(.internal)) == .failed("error \(NEHotspotConfigurationError.internal.rawValue)"))
    }
}
