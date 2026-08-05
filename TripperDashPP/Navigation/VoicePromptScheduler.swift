//
//  VoicePromptScheduler.swift
//  TripperDashPP
//
//  feat/voice-nav — decides WHEN to fire each spoken maneuver prompt.
//
//  Pure decision logic, isolated from both the synthesizer (`VoiceNavigator`)
//  and the phrase templates (`VoicePhrase`) so it's unit-testable on Linux
//  with no AVFoundation and mirror-able in Python (same discipline as the
//  wire-encoding helpers).
//
//  ── The problem it solves ─────────────────────────────────────────────
//
//  `ActiveNavLoop` ticks at 1 Hz with the current maneuver + distance. If we
//  naively spoke every tick we'd get a machine-gun of "turn right… turn
//  right… turn right". Instead we announce a maneuver at up to THREE
//  distance tiers as the rider closes in — far (~1 km), near (~300 m), now
//  (at the turn) — and each tier fires AT MOST ONCE per maneuver.
//
//  Maneuver identity is tracked by a caller-supplied token (the arriving
//  step's polyline hash / index). When the token changes the rider has
//  advanced to a new maneuver, so the fired-tier set resets.
//
//  ── Tier thresholds ──────────────────────────────────────────────────
//
//  Far tier only makes sense at speed (a 1 km callout in town is absurd),
//  so it's gated on a minimum approach distance AND only fires if the rider
//  actually entered the window from above (we don't blurt "in 1 km" for a
//  maneuver that was already 200 m away when nav started). Near + now always
//  apply. All thresholds are plain constants here; if they ever need to be
//  user-tunable they move to DashNavSettings.
//

import Foundation

/// A decision the scheduler emits on a given tick: speak this tier for the
/// current maneuver, or stay silent.
struct VoicePromptDecision: Equatable {
    var tier: VoicePromptTier
}

/// Pure, value-type scheduler. One instance per active-nav session; the
/// caller feeds it (maneuverToken, distanceMeters) each tick and it returns
/// a tier to speak or nil.
struct VoicePromptScheduler {

    // Tier windows (metres). A tier fires when the rider FIRST crosses below
    // its upper bound (and, for far, is still above the next tier's bound).
    static let farUpperMeters: Double = 1050    // announce ~1 km, with slack
    static let farLowerMeters: Double = 800     // ...but not once inside 800 m
    static let nearUpperMeters: Double = 350    // announce ~300 m, with slack
    static let nearLowerMeters: Double = 180
    static let nowMeters: Double = 40           // "now" — at the turn

    /// Identity of the maneuver the fired-set currently belongs to. When the
    /// incoming token differs, we've advanced → reset fired tiers.
    private var currentToken: Int?

    /// Tiers already spoken for `currentToken`.
    private var fired: Set<Int> = []

    /// Last distance seen for the current maneuver, so we only fire a tier
    /// when the rider is CLOSING (distance decreasing across the bound), not
    /// when a reroute momentarily inflates the distance.
    private var lastDistance: Double = .infinity

    init() {}

    /// Feed one tick. Returns the tier to speak, or nil.
    ///
    /// - Parameters:
    ///   - token: stable identity of the current upcoming maneuver (e.g.
    ///     the arriving step's polyline hash). A change resets fired tiers.
    ///   - distanceMeters: rider→maneuver distance this tick.
    mutating func onTick(token: Int, distanceMeters d: Double) -> VoicePromptTier? {
        if token != currentToken {
            currentToken = token
            fired.removeAll(keepingCapacity: true)
            lastDistance = .infinity
        }
        defer { lastDistance = d }
        guard d.isFinite, d >= 0 else { return nil }

        // Only ever fire while CLOSING in (or on the first finite reading).
        let closing = d <= lastDistance

        // "now" — highest urgency, fire once inside the turn radius.
        if closing, d <= Self.nowMeters, !fired.contains(tierKey(.now)) {
            fired.insert(tierKey(.now))
            return .now
        }
        // "near" — ~300 m.
        if closing, d <= Self.nearUpperMeters, d > Self.nowMeters,
           !fired.contains(tierKey(.near)) {
            fired.insert(tierKey(.near))
            // Once near fires, suppress a late far (rider started inside it).
            fired.insert(tierKey(.far))
            return .near
        }
        // "far" — ~1 km, only when genuinely approaching from distance.
        if closing, d <= Self.farUpperMeters, d > Self.farLowerMeters,
           !fired.contains(tierKey(.far)) {
            fired.insert(tierKey(.far))
            return .far
        }
        return nil
    }

    /// Forget all state (e.g. nav stopped). Next tick starts fresh.
    mutating func reset() {
        currentToken = nil
        fired.removeAll(keepingCapacity: true)
        lastDistance = .infinity
    }

    private func tierKey(_ t: VoicePromptTier) -> Int {
        switch t {
        case .far:  return 0
        case .near: return 1
        case .now:  return 2
        }
    }
}
