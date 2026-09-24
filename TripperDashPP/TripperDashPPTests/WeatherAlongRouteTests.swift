//
//  WeatherAlongRouteTests.swift
//  TripperDashPPTests
//
//  Unit tests for the weather-along-route pipeline: the pure, network-free
//  logic in `WeatherAlertService` — model shape, along-route sampling,
//  hazard classification, and the nearest-hazard-with-severity picker.
//
//  Uses Swift Testing (`import Testing`, Xcode 26+). Everything under test
//  is `nonisolated static` so no main-actor hop or URLSession is needed.
//

import Testing
import CoreLocation
@testable import TripperDashPP

private typealias Svc = WeatherAlertService
private typealias Sample = WeatherAlertService.Sample

/// Build a Sample with only the field(s) a given test cares about.
private func sample(code: Int = 0,
                    gusts: Double = 0,
                    visibility: Double = 1_000_000,
                    precip: Double = 0,
                    temp: Double? = nil,
                    windFrom: Double? = nil,
                    heading: Double? = nil,
                    dist: CLLocationDistance) -> Sample {
    Sample(weatherCode: code, gustsKmh: gusts, visibilityM: visibility,
           precipitationMm: precip, isAhead: dist > 0, distanceM: dist,
           temperatureC: temp, windDirectionDeg: windFrom, travelBearingDeg: heading)
}

// MARK: - Cold road + crosswind

struct ColdAndCrosswindTests {

    private func at(_ s: Sample) -> WeatherAlert? { Svc.classify(s, isAhead: false) }

    @Test func frostRiskBelowFourDegrees() {
        let a = at(sample(temp: 3.9, dist: 0))
        #expect(a?.title == "Frost risk")
        #expect(a?.severity == .caution)
        #expect(a?.glyph == .ice)
    }

    @Test func fourDegreesIsNotFrost() {
        #expect(at(sample(temp: 4.0, dist: 0)) == nil)
    }

    @Test func missingTemperatureIsNotFrost() {
        #expect(at(sample(temp: nil, dist: 0)) == nil)
    }

    @Test func frostBeatsRain() {
        #expect(at(sample(code: 61, temp: 2, dist: 0))?.title == "Frost risk")
    }

    @Test func freezingRainStillWinsAboveZero() {
        let a = at(sample(code: 66, temp: 2, dist: 0))
        #expect(a?.title == "Ice")
        #expect(a?.severity == .warning)
    }

    @Test func zeroWithMeasuredPrecipIsIce() {
        let a = at(sample(precip: 0.2, temp: 0, dist: 0))
        #expect(a?.title == "Ice")
        #expect(a?.severity == .warning)
    }

    @Test func zeroWithRainCodeIsIce() {
        let a = at(sample(code: 61, temp: 0, dist: 0))
        #expect(a?.title == "Ice")
        #expect(a?.severity == .warning)
    }

    @Test func subZeroFogIsNotPrecipitation() {
        // Fog codes (45/48) are not precipitation → Frost risk, not Ice.
        #expect(at(sample(code: 45, temp: -2, dist: 0))?.title == "Frost risk")
        #expect(at(sample(code: 48, temp: -2, dist: 0))?.title == "Frost risk")
    }

    @Test func iceSpanStopsAtLowerSeverityFrost() {
        // Frost 10 km, Ice 20 km, frost 30…50 km: the red Ice band must not
        // stretch over the surrounding amber frost (same .ice glyph).
        let samples = [
            sample(temp: 8, dist: 0),
            sample(temp: 2, dist: 10_000),
            sample(code: 61, temp: -1, dist: 20_000),
            sample(temp: 2, dist: 30_000),
            sample(temp: 2, dist: 40_000),
        ]
        let a = Svc.pickAlongRoute(samples)
        #expect(a?.title == "Ice")
        #expect(a?.distanceAhead == 20_000)
        #expect(a?.spanStartMeters == nil)
        #expect(a?.spanEndMeters == nil)
    }

    @Test func iceRunStillFormsASpan() {
        let samples = [
            sample(temp: 8, dist: 0),
            sample(code: 71, temp: -2, dist: 10_000),
            sample(code: 71, temp: -2, dist: 20_000),
            sample(temp: 2, dist: 30_000),
        ]
        let a = Svc.pickAlongRoute(samples)
        #expect(a?.spanStartMeters == 10_000)
        #expect(a?.spanEndMeters == 20_000)
    }

    @Test func subZeroSnowReadsIce() {
        let a = at(sample(code: 71, temp: -3, dist: 0))
        #expect(a?.title == "Ice")
        #expect(a?.severity == .warning)
    }

    @Test func zeroWithoutPrecipIsOnlyFrost() {
        let a = at(sample(temp: 0, dist: 0))
        #expect(a?.title == "Frost risk")
        #expect(a?.severity == .caution)
    }

    @Test func justAboveZeroRainIsOnlyFrost() {
        let a = at(sample(code: 61, temp: 0.1, dist: 0))
        #expect(a?.title == "Frost risk")
        #expect(a?.severity == .caution)
    }

    @Test func fullCrosswindWarns() {
        let a = at(sample(gusts: 60, windFrom: 90, heading: 0, dist: 0))
        #expect(a?.title == "Crosswind")
        #expect(a?.severity == .warning)
        #expect(a?.glyph == .wind)
    }

    @Test func moderateCrosswindCautions() {
        let a = at(sample(gusts: 45, windFrom: 270, heading: 0, dist: 0))
        #expect(a?.title == "Crosswind")
        #expect(a?.severity == .caution)
    }

    @Test func obliqueGustIsPlainGustyWind() {
        // 60 km/h at 30° to travel → 30 km/h across: no crosswind,
        // but the direction-blind ≥ 50 km/h gust rule still fires.
        let a = at(sample(gusts: 60, windFrom: 30, heading: 0, dist: 0))
        #expect(a?.title == "Gusty wind")
        #expect(a?.severity == .caution)
    }

    @Test func headwindKeepsStrongWind() {
        #expect(at(sample(gusts: 70, windFrom: 0, heading: 0, dist: 0))?.title == "Strong wind")
    }

    @Test func noRouteNoCrosswind() {
        #expect(at(sample(gusts: 60, windFrom: 90, heading: nil, dist: 0))?.title == "Gusty wind")
    }

    @Test func crosswindIsSymmetric() {
        // Wind from the left or the right, heading either way — same push.
        let l = Svc.crosswindKmh(sample(gusts: 50, windFrom: 45, heading: 315, dist: 0))!
        let r = Svc.crosswindKmh(sample(gusts: 50, windFrom: 225, heading: 315, dist: 0))!
        #expect(abs(l - 50) < 0.001)
        #expect(abs(r - 50) < 0.001)
    }

    @Test func bearingCardinalPoints() {
        let o = CLLocationCoordinate2D(latitude: 50, longitude: 14)
        func b(_ dLat: Double, _ dLon: Double) -> Double {
            Svc.bearing(o, CLLocationCoordinate2D(latitude: 50 + dLat, longitude: 14 + dLon))
        }
        #expect(abs(b(0.01, 0) - 0) < 0.5)
        #expect(abs(b(0, 0.01) - 90) < 0.5)
        #expect(abs(b(-0.01, 0) - 180) < 0.5)
        #expect(abs(b(0, -0.01) - 270) < 0.5)
    }

    @Test func travelBearingFollowsRoute() {
        // East for ~1.4 km, then north.
        let route = [
            CLLocationCoordinate2D(latitude: 50, longitude: 14),
            CLLocationCoordinate2D(latitude: 50, longitude: 14.02),
            CLLocationCoordinate2D(latitude: 50.02, longitude: 14.02),
        ]
        let east = Svc.travelBearing(route, from: route[0], atMeters: 500)!
        let north = Svc.travelBearing(route, from: route[0], atMeters: 2_500)!
        #expect(abs(east - 90) < 1)
        #expect(north < 1 || north > 359)
        #expect(Svc.travelBearing([], from: route[0], atMeters: 0) == nil)
    }

    @Test func routeEndSampleKeepsABearing() {
        // samplesAlong stamps the clamped end point with distanceM up to one
        // spacing PAST the real end (here ~1.4 km route, sample at 2.5 km).
        let route = [
            CLLocationCoordinate2D(latitude: 50, longitude: 14),
            CLLocationCoordinate2D(latitude: 50, longitude: 14.02),
        ]
        let b = Svc.travelBearing(route, from: route[0], atMeters: 2_500)
        #expect(b != nil)
        #expect(abs((b ?? 0) - 90) < 1)
    }

    @Test func crosswindComponentAtObliqueAngles() {
        // sin(30°) = 0.5, sin(150°) = 0.5, sin(0°) = 0.
        let g = 60.0
        #expect(abs(Svc.crosswindKmh(sample(gusts: g, windFrom: 30, heading: 0, dist: 0))! - 30) < 0.001)
        #expect(abs(Svc.crosswindKmh(sample(gusts: g, windFrom: 150, heading: 0, dist: 0))! - 30) < 0.001)
        #expect(Svc.crosswindKmh(sample(gusts: g, windFrom: 180, heading: 0, dist: 0))! < 0.001)
    }
}

// MARK: - Model

struct WeatherAlertModelTests {

    @Test func carriesDistanceAhead() {
        let a = WeatherAlert(title: "Rain", severity: .caution,
                             isAhead: true, glyph: .rain, distanceAhead: 15_000)
        #expect(a.distanceAhead == 15_000)
        #expect(a.isAhead == true)
    }

    @Test func distanceDefaultsToNil() {
        // classify() constructs alerts without a distance — must default nil.
        let a = WeatherAlert(title: "Rain", severity: .caution, isAhead: false, glyph: .rain)
        #expect(a.distanceAhead == nil)
    }

    @Test func severityOrders() {
        #expect(WeatherAlert.Severity.caution < WeatherAlert.Severity.warning)
    }
}

// MARK: - Classification truth table (bare-noun titles, no "ahead" baked in)

struct ClassifyTests {

    @Test func clearIsNil() {
        #expect(Svc.classify(sample(code: 0, dist: 0), isAhead: false) == nil)
        #expect(Svc.classify(sample(code: 3, dist: 0), isAhead: false) == nil)   // cloudy
    }

    @Test func iceAlwaysWarns() {
        for code in [56, 57, 66, 67] {
            let a = Svc.classify(sample(code: code, dist: 0), isAhead: false)
            #expect(a?.severity == .warning)
            #expect(a?.glyph == .ice)
            #expect(a?.title == "Ice")   // no " ahead" suffix any more
        }
    }

    @Test func thunderstormWarns() {
        for code in [95, 96, 99] {
            let a = Svc.classify(sample(code: code, dist: 0), isAhead: true)
            #expect(a?.severity == .warning)
            #expect(a?.glyph == .storm)
            #expect(a?.title == "Storm")
        }
    }

    @Test func ordinaryRainIsCaution() {
        for code in [51, 53, 55, 61, 63, 80, 81] {
            let a = Svc.classify(sample(code: code, dist: 0), isAhead: false)
            #expect(a?.severity == .caution)
            #expect(a?.glyph == .rain)
            #expect(a?.title == "Rain")
        }
    }

    @Test func heavyRainWarns() {
        for code in [65, 82] {
            #expect(Svc.classify(sample(code: code, dist: 0), isAhead: false)?.severity == .warning)
        }
    }

    @Test func strongGustsWarnEvenWhenClear() {
        let a = Svc.classify(sample(code: 0, gusts: 70, dist: 0), isAhead: false)
        #expect(a?.severity == .warning)
        #expect(a?.glyph == .wind)
    }

    @Test func denseFogWarns() {
        let a = Svc.classify(sample(code: 0, visibility: 300, dist: 0), isAhead: false)
        #expect(a?.severity == .warning)
        #expect(a?.glyph == .fog)
        #expect(a?.title == "Dense fog")
    }

    @Test func isAheadThreadsThroughWithoutChangingTitle() {
        let here = Svc.classify(sample(code: 61, dist: 0), isAhead: false)
        let ahead = Svc.classify(sample(code: 61, dist: 20_000), isAhead: true)
        #expect(here?.title == "Rain")
        #expect(ahead?.title == "Rain")       // title identical regardless of isAhead
        #expect(here?.isAhead == false)
        #expect(ahead?.isAhead == true)
    }
}

// MARK: - pickAlongRoute policy

struct PickAlongRouteTests {

    @Test func allClearIsNil() {
        #expect(Svc.pickAlongRoute([sample(code: 0, dist: 0)]) == nil)
        #expect(Svc.pickAlongRoute([]) == nil)
    }

    @Test func hazardAtRiderHasNoDistance() {
        let out = Svc.pickAlongRoute([
            sample(code: 61, dist: 0),          // raining right now
            sample(code: 0,  dist: 10_000),
        ])
        #expect(out?.title == "Rain")
        #expect(out?.isAhead == false)
        #expect(out?.distanceAhead == nil)
    }

    @Test func nearerWarningBeatsFartherNothing() {
        let out = Svc.pickAlongRoute([
            sample(code: 0,  dist: 0),          // clear here
            sample(code: 95, dist: 40_000),     // storm ahead
        ])
        #expect(out?.glyph == .storm)
        #expect(out?.severity == .warning)
        #expect(out?.distanceAhead == 40_000)
        #expect(out?.isAhead == true)
    }

    @Test func fartherWarningBeatsNearerCaution() {
        // Motorcycle-biased: the 40 km storm matters more than the 5 km drizzle.
        let out = Svc.pickAlongRoute([
            sample(code: 0,  dist: 0),
            sample(code: 61, dist: 5_000),      // rain (caution) @5km
            sample(code: 95, dist: 40_000),     // storm (warning) @40km
        ])
        #expect(out?.severity == .warning)
        #expect(out?.glyph == .storm)
        #expect(out?.distanceAhead == 40_000)
    }

    @Test func sameSeverityNearerWins() {
        let out = Svc.pickAlongRoute([
            sample(code: 0,  dist: 0),
            sample(code: 80, dist: 30_000),     // showers (caution) @30km
            sample(code: 61, dist: 12_000),     // rain (caution) @12km
        ])
        #expect(out?.severity == .caution)
        #expect(out?.distanceAhead == 12_000)
    }

    @Test func riderHazardOutranksNothingElse() {
        // Warning at rider position stays distance-nil even with clears ahead.
        let out = Svc.pickAlongRoute([
            sample(code: 95, dist: 0),          // storm right now
            sample(code: 61, dist: 20_000),     // rain ahead
        ])
        #expect(out?.severity == .warning)
        #expect(out?.distanceAhead == nil)      // it's here, not ahead
    }
}

// MARK: - samplesAlong geometry

struct SamplesAlongTests {

    // A near-straight due-east run at 50°N. 0.1° lon ≈ 7.16 km here.
    private let eastLine = [
        CLLocationCoordinate2D(latitude: 50.0, longitude: 14.0),
        CLLocationCoordinate2D(latitude: 50.0, longitude: 15.0),   // ~71.6 km east
    ]

    @Test func spacesPointsAndTagsDistance() {
        let s = Svc.samplesAlong(eastLine, from: eastLine[0],
                                 everyMeters: 10_000, maxMeters: 30_000)
        #expect(s.count == 3)
        #expect(abs(s[0].distanceM - 10_000) < 1)
        #expect(abs(s[1].distanceM - 20_000) < 1)
        #expect(abs(s[2].distanceM - 30_000) < 1)
        // Each successive point is further east (longitude increasing).
        #expect(s[0].coord.longitude < s[1].coord.longitude)
        #expect(s[1].coord.longitude < s[2].coord.longitude)
    }

    @Test func stopsAtRouteEndNoDuplicates() {
        // Route is ~71.6 km; ask for points every 10 km out to 200 km.
        let s = Svc.samplesAlong(eastLine, from: eastLine[0],
                                 everyMeters: 10_000, maxMeters: 200_000)
        // Should stop around the route end (~7 points) and never repeat the
        // terminal coordinate.
        #expect(s.count >= 6)
        #expect(s.count <= 8)
        let last = s.last!
        // No two consecutive samples are the same coordinate.
        for i in 1..<s.count {
            #expect(Svc.haversine(s[i - 1].coord, s[i].coord) > 1)
        }
        // The final sample is at or before the physical route end.
        #expect(Svc.haversine(last.coord, eastLine[1]) < 11_000)
    }

    @Test func emptyOrSingleRouteYieldsNothing() {
        #expect(Svc.samplesAlong([], from: eastLine[0], everyMeters: 10_000, maxMeters: 50_000).isEmpty)
        #expect(Svc.samplesAlong([eastLine[0]], from: eastLine[0], everyMeters: 10_000, maxMeters: 50_000).isEmpty)
    }

    @Test func zeroSpacingIsSafe() {
        #expect(Svc.samplesAlong(eastLine, from: eastLine[0], everyMeters: 0, maxMeters: 50_000).isEmpty)
    }

    @Test func measuresAheadOfRiderNotRouteOrigin() {
        // Rider sits ~40 km along the line; a 10 km look-ahead must land
        // FURTHER east than the rider, not back near the origin.
        let rider = CLLocationCoordinate2D(latitude: 50.0, longitude: 14.55)
        let s = Svc.samplesAlong(eastLine, from: rider, everyMeters: 10_000, maxMeters: 10_000)
        #expect(s.count == 1)
        #expect(s[0].coord.longitude > rider.longitude)
    }
}

// MARK: - formatAheadDistance (pill distance suffix)

struct FormatAheadDistanceTests {

    private func fmt(_ m: Double, imperial: Bool = false) -> String {
        MapViewSource.formatAheadDistance(meters: m, imperial: imperial)
    }

    @Test func wholeKilometresNoFakePrecision() {
        // 14.7 km must not render as "14.7 km" — weather is only accurate
        // to the ~10 km sample spacing, so we round to whole km (decision #4).
        #expect(fmt(14_700) == "15 km")
        #expect(fmt(15_000) == "15 km")
        #expect(fmt(100_000) == "100 km")
        #expect(fmt(1_000) == "1 km")
    }

    @Test func subKilometreRoundsToHundredMetres() {
        #expect(fmt(300) == "300 m")
        #expect(fmt(349) == "300 m")
        #expect(fmt(350) == "400 m")
        #expect(fmt(940) == "900 m")   // rounds to nearest 100, stays < 1 km
    }

    @Test func neverCollapsesToZero() {
        // A very-close hazard must show a floor, not "0 m" / "0 km".
        #expect(fmt(40) == "100 m")
        #expect(fmt(10) == "100 m")
    }

    @Test func imperialWholeMiles() {
        // 15 km ≈ 9.32 mi → "9 mi"
        #expect(fmt(15_000, imperial: true) == "9 mi")
        #expect(fmt(100_000, imperial: true) == "62 mi")
    }

    @Test func imperialShortDistanceUsesFeet() {
        // < 0.5 mi → feet, rounded to 500 ft, floored so it never hits 0.
        let close = fmt(200, imperial: true)   // ~656 ft → 500 ft
        #expect(close.hasSuffix(" ft"))
        #expect(fmt(20, imperial: true) == "500 ft")   // floor
    }
}

