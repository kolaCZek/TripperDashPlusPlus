//
//  TlvEtaFormatTests.swift
//  TripperDashPPTests
//
//  The ETA TLV (`05 08`) carries the arrival time as 4 ASCII digits HHMM.
//  Real-bike ground truth (Martin, 8/2026): the dash renders ETA per its
//  OWN clock menu and there is no wire flag we can drive, so we format the
//  VALUE to match the OEM app — 24-hour keeps the hour as-is, 12-hour sends
//  `hour % 12` (noon/midnight → 12), no AM/PM. These tests pin the ASCII
//  payload for both conventions across the tricky boundaries.
//

import Testing
import Foundation
@testable import TripperDashPP

struct TlvEtaFormatTests {

    private func utcCalendar() -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    private func eta(_ h: Int, _ m: Int, is24Hour: Bool) -> String {
        let cal = utcCalendar()
        let d = cal.date(from: DateComponents(year: 2000, month: 1, day: 1, hour: h, minute: m))!
        let seg = K1GPacket.tlvEta(date: d, is24Hour: is24Hour, calendar: cal)
        return String(decoding: seg.payload, as: UTF8.self)
    }

    // MARK: 24-hour

    @Test func eta24HourAfternoon() {
        #expect(eta(14, 33, is24Hour: true) == "1433")
    }

    @Test func eta24HourMorningZeroPads() {
        #expect(eta(2, 5, is24Hour: true) == "0205")
    }

    @Test func eta24HourMidnight() {
        #expect(eta(0, 0, is24Hour: true) == "0000")
    }

    // MARK: 12-hour (hour % 12, noon/midnight → 12, no AM/PM)

    @Test func eta12HourAfternoonWraps() {
        // 14:33 → 02:33 on the dash — Martin's exact observation.
        #expect(eta(14, 33, is24Hour: false) == "0233")
    }

    @Test func eta12HourMorningUnchanged() {
        #expect(eta(9, 15, is24Hour: false) == "0915")
    }

    @Test func eta12HourNoonIsTwelve() {
        #expect(eta(12, 0, is24Hour: false) == "1200")
    }

    @Test func eta12HourMidnightIsTwelve() {
        #expect(eta(0, 45, is24Hour: false) == "1245")
    }

    @Test func eta12HourLateEveningWraps() {
        // 23:59 → 11:59
        #expect(eta(23, 59, is24Hour: false) == "1159")
    }

    // MARK: TLV shape

    @Test func etaSegmentTypeAndSub() {
        let cal = utcCalendar()
        let d = cal.date(from: DateComponents(year: 2000, month: 1, day: 1, hour: 8, minute: 30))!
        let seg = K1GPacket.tlvEta(date: d, is24Hour: true, calendar: cal)
        #expect(seg.type == 0x05)
        #expect(seg.sub == 0x08)
        #expect(seg.payload.count == 4)
    }
}
