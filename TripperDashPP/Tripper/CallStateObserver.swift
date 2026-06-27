//
//  CallStateObserver.swift
//  TripperDashPP
//
//  Bridges iOS CallKit (`CXCallObserver`) to the Tripper dash call-state
//  card. When a phone call comes in / is answered / ends, we push the
//  matching K1G `05 21` call-state TLV to the dash via `BikeLink`, so the
//  rider sees the same incoming-call card the stock Royal Enfield app shows.
//
//  Why CXCallObserver (not a CallKit *provider*):
//    - `CXCallObserver` is READ-ONLY call state. It needs NO special
//      entitlement, works for regular cellular calls, and keeps running
//      while the app is backgrounded / the screen is locked — exactly our
//      ride scenario. A CXProvider, by contrast, is for VoIP apps that
//      originate calls and would require the VoIP background mode.
//    - Privacy trade-off: for ordinary cellular calls CallKit does NOT
//      hand us the caller's name or number (`CXCall` has only a UUID +
//      bool flags). That's fine — the dash card we drive is state-only
//      (ringing / in-call / ended), matching what's achievable. The OEM
//      caller-NAME card (`05 22`) is AES-encrypted and unreachable here,
//      see `K1GPacket.CallState` docs + the skill reference
//      `call-notification-wire-protocol.md`.
//
//  Mapping (CXCall → K1GPacket.CallState), mirroring the OEM `km3.u()`:
//
//      hasEnded == true                      → .none      (clear the card)
//      hasConnected == true                  → .active    (answered / in call)
//      isOutgoing == true  (not connected)   → .outgoing  (we dialed out)
//      else (new, inbound, not connected)    → .incoming  (ringing)
//
//  BikeLink de-dups repeated identical states, so the several `callChanged`
//  events CallKit fires for one logical transition collapse to one burst.
//

import Foundation
import os

#if canImport(CallKit)
import CallKit
#endif

/// Observes system call state and forwards it to the dash. Owns its
/// `CXCallObserver` for the app's lifetime. Main-actor because it pokes
/// the `@MainActor BikeLink`; CallKit delivers callbacks on a queue we
/// specify, and we hop to the main actor inside the delegate.
@MainActor
final class CallStateObserver: NSObject {

    private let link: BikeLink
    private let log = Logger(subsystem: "eu.kolaczek.tripperdashpp", category: "CallState")

    #if canImport(CallKit)
    private let observer = CXCallObserver()
    #endif

    init(link: BikeLink) {
        self.link = link
        super.init()
    }

    /// Start observing system call state. Idempotent-ish: setting the
    /// delegate again just re-registers the same object. Safe to call from
    /// app startup. On platforms without CallKit (shouldn't happen on iOS,
    /// but keeps the type compiling for tests / previews) this is a no-op.
    func start() {
        #if canImport(CallKit)
        // Deliver callbacks straight onto the main queue so the delegate's
        // main-actor hop is trivial and ordering is preserved.
        observer.setDelegate(self, queue: nil)
        log.info("CallStateObserver started (CXCallObserver)")
        #else
        log.info("CallStateObserver: CallKit unavailable — call-state card disabled")
        #endif
    }

    #if canImport(CallKit)
    /// Pure mapping from a CallKit call to our wire call-state. Static and
    /// side-effect-free so the unit/logic tests (and the Python wire mirror)
    /// can pin the exact truth table without standing up CallKit.
    static func callState(hasEnded: Bool,
                          hasConnected: Bool,
                          isOutgoing: Bool) -> K1GPacket.CallState {
        if hasEnded { return .none }
        if hasConnected { return .active }
        if isOutgoing { return .outgoing }
        return .incoming
    }
    #endif
}

#if canImport(CallKit)
extension CallStateObserver: CXCallObserverDelegate {
    nonisolated func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
        // Snapshot the value-type flags now (CXCall is a reference type but
        // these are cheap bools) and hop to the main actor to touch BikeLink.
        let state = CallStateObserver.callState(
            hasEnded: call.hasEnded,
            hasConnected: call.hasConnected,
            isOutgoing: call.isOutgoing
        )
        Task { @MainActor [link] in
            await link.sendCallState(state)
        }
    }
}
#endif
