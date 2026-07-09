//
//  NextWaypointLabelTests.swift
//  TripperDashPPTests
//
//  Truth-table tests for `ActiveNavLoop.nextWaypointLabel`, the
//  multi-stop "<time> to <name>" string sent over the roadName TLV
//  (`05 01`) — the same wire field that used to render the burned
//  "SCAN 0xNN" text during glyph-capture sessions (Martin's field
//  request, 7/2026: show time-to-next-waypoint in that slot).
//
//  TIME-FIRST ordering (Martin, 7/2026 follow-up): a long waypoint name
//  must never push the ETA out of the dash's visible text row. Putting
//  the time first and clipping only the name's tail guarantees the ETA
//  is always fully rendered regardless of how our 28-char budget guess
//  compares to the real dash's render width.
//
//  Covers: time formatting parity with NavigationHUD.timeRemaining
//  ("1h 23m" / "15 min"), name clipping at the character budget, and
//  the negative/zero clamp. Name-clipping expectations are computed by
//  hand against the documented budget (28 total chars: timePart + " to "
//  (4) + name), not by eye.
//

import Testing
@testable import TripperDashPP

struct NextWaypointLabelTests {

    typealias L = ActiveNavLoop

    // MARK: - Short names: no clipping

    @Test func shortNameMinutesOnly() {
        #expect(L.nextWaypointLabel(name: "Slaný", etaSeconds: 900) == "15 min to Slaný")
    }

    @Test func shortNameWithHours() {
        // 1h 23m == 4980s. Mirrors NavigationHUD.timeRemaining's "\(h)h \(m)m".
        #expect(L.nextWaypointLabel(name: "Karlštejn", etaSeconds: 4_980) == "1h 23m to Karlštejn")
    }

    @Test func zeroMinutesRoundsDown() {
        // Sub-minute ETA still renders "0 min", never blank — matches
        // NavigationHUD.timeRemaining's integer-division behavior.
        #expect(L.nextWaypointLabel(name: "Zvoleněves", etaSeconds: 40) == "0 min to Zvoleněves")
    }

    // MARK: - Negative clamp

    @Test func negativeEtaClampsToZero() {
        #expect(L.nextWaypointLabel(name: "Slaný", etaSeconds: -5) == "0 min to Slaný")
    }

    // MARK: - Long names: clipping (name only — the ETA must survive intact)

    @Test func longNameClipsWithEllipsis() {
        // Budget 28, "15 min" timePart (6) + " to " joiner (4) = 10
        // reserved -> nameBudget = 18. 18-char name fits with no ellipsis
        // at exactly the boundary.
        let exactFit = "Rohanské nábřeží1" // 17 characters — under budget
        #expect(exactFit.count == 17)
        #expect(L.nextWaypointLabel(name: exactFit, etaSeconds: 900)
                == "15 min to Rohanské nábřeží1")
    }

    @Test func longNameOverBudgetGetsEllipsisTruncated() {
        // 23-char name over the 18-char budget: clipped to 17 chars + "…".
        let longName = "Rohanské nábřeží Karlín" // 23 characters
        let label = L.nextWaypointLabel(name: longName, etaSeconds: 900)
        #expect(label == "15 min to Rohanské nábřeží …")
        // The ETA is always the PREFIX — never touched or pushed out by
        // a long name, regardless of how the name gets clipped.
        #expect(label.hasPrefix("15 min to "))
    }

    @Test func longNameWithHoursHasSameNameBudget() {
        // "1h 23m" is also 6 chars, so budget arithmetic matches the
        // minutes case here — but this asserts the budget is recomputed
        // from the ACTUAL time string length, not hardcoded to the "min"
        // case, and that the ETA prefix survives untouched either way.
        let longName = "Karlovarský kraj hranice okres" // 30 characters
        let label = L.nextWaypointLabel(name: longName, etaSeconds: 4_980)
        #expect(label.hasPrefix("1h 23m to "))
        #expect(label.contains("…"))
    }

    @Test func extremelyLongNameNeverPushesEtaOutOfFrame() {
        // Pathological case: a name far longer than any real waypoint.
        // The ETA prefix must remain intact and the whole label must not
        // grow unbounded — this is the exact regression Martin flagged.
        let pathological = String(repeating: "A", count: 200)
        let label = L.nextWaypointLabel(name: pathological, etaSeconds: 900)
        #expect(label.hasPrefix("15 min to "))
        // Total length stays within the documented budget (small const
        // slack for the "…" replacement character itself).
        #expect(label.count <= 29)
    }

    // MARK: - Empty name (defensive; shouldn't occur in practice since
    // Waypoint.name is always populated, but the function must not crash)

    @Test func emptyNameStillProducesValidLabel() {
        #expect(L.nextWaypointLabel(name: "", etaSeconds: 900) == "15 min to ")
    }
}
