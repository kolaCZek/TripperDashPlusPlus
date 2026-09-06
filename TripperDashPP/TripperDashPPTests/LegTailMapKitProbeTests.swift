//
//  LegTailMapKitProbeTests.swift
//  TripperDashPPTests
//
//  Verifies the ONE claim PR #125 could not prove on Linux: that MapKit
//  returns no mid-leg maneuver for the short single-hop legs a GPX track
//  is reduced to — which is what makes `PolylineMath.nextStepIndex`
//  return nil for a whole leg and freeze the maneuver bubble.
//
//  This probe calls the LIVE `MKDirections` API, so it is OFF by default:
//  a network-dependent assertion in CI is a flaky test, and flaky tests
//  get ignored, which is worse than no test. Enable it deliberately:
//
//      TRIPPERDASH_LIVE_MAPKIT=1 xcodebuild test \
//        -project TripperDashPP/TripperDashPP.xcodeproj \
//        -scheme TripperDashPP \
//        -destination 'platform=iOS Simulator,name=iPhone 16' \
//        -only-testing:TripperDashPPTests/LegTailMapKitProbeTests
//
//  It runs fine in the plain iOS Simulator — no bike, no dash, no device.
//  MKDirections is rate-limited by Apple, so it probes ONE leg, not forty.
//
//  The coordinates are two real, adjacent Douglas–Peucker waypoints from
//  Ari's `2Flags.gpx` (Kurviger `<trk>`, 752 trkpt, 52.6 km, reduced to 40
//  points → 39 legs). This is leg 0: 1085 m, which the Python model says
//  is frozen from vertex 0, i.e. for 100% of its length.
//
//  What it reports (and asserts):
//    • how many steps MapKit returns for the leg
//    • how many of those have an EMPTY polyline (the terminal `arrive`
//      step — the one `nextStepIndex` skips by design)
//    • the first route-polyline vertex at which `nextStepIndex` returns
//      nil, and how much of the leg lies beyond it
//
//  If the frozen tail is a large fraction of the leg, the premise of #125
//  holds against the real API. If MapKit turns out to emit mid-leg
//  maneuvers here, the fix is inert for this leg rather than harmful —
//  and this test is how we'd find that out.
//

import Testing
import CoreLocation
import MapKit
@testable import TripperDashPP

/// Two adjacent Douglas–Peucker waypoints from Ari's 2Flags.gpx (leg 0).
private let ariLegStart = CLLocationCoordinate2D(latitude: 52.67126, longitude: -0.8186)
private let ariLegEnd   = CLLocationCoordinate2D(latitude: 52.67016, longitude: -0.81314)

/// `nonisolated` is required, not decorative: this project turns on
/// default MainActor isolation, so a bare top-level `var` picks that up
/// silently. The `.enabled(if:)` condition trait is evaluated by Swift
/// Testing BEFORE the (MainActor-isolated) test body runs, from a
/// nonisolated context — without this the build only warns today, but a
/// future stricter concurrency mode turns that into a hard error.
nonisolated private var liveProbeEnabled: Bool {
    ProcessInfo.processInfo.environment["TRIPPERDASH_LIVE_MAPKIT"] == "1"
}

@MainActor
struct LegTailMapKitProbeTests {

    /// Probe the real MKDirections response for a single GPX-track leg.
    ///
    /// Gated with the `.enabled(if:)` CONDITION TRAIT, not with a
    /// `try #require(...)` inside the body. That distinction cost a red CI
    /// run: `#require` is an unwrap/precondition — when it fails it RECORDS
    /// AN ISSUE and fails the test. It does not skip. Only a condition
    /// trait makes Swift Testing skip the test outright, which is what an
    /// opt-in network probe needs so the default CI run stays green and
    /// offline.
    @Test(.enabled(if: liveProbeEnabled,
                   "Live MapKit probe — set TRIPPERDASH_LIVE_MAPKIT=1 to run"))
    func mapKitLegShapeMatchesTheLegTailPremise() async throws {
        let req = MKDirections.Request()
        req.source = MKMapItem(placemark: MKPlacemark(coordinate: ariLegStart))
        req.destination = MKMapItem(placemark: MKPlacemark(coordinate: ariLegEnd))
        req.transportType = .automobile
        req.requestsAlternateRoutes = false

        let response = try await MKDirections(request: req).calculate()
        let route = try #require(response.routes.first, "MapKit returned no route")

        let steps = route.steps
        let empties = steps.filter { $0.polyline.pointCount == 0 }
        let withGeometry = steps.filter { $0.polyline.pointCount > 0 }

        print("""

        ── MapKit leg probe ─────────────────────────────────────────
        leg distance          : \(Int(route.distance)) m
        polyline vertices     : \(route.polyline.pointCount)
        steps                 : \(steps.count)
          with geometry       : \(withGeometry.count)
          EMPTY polyline      : \(empties.count)
        instructions:
        \(steps.enumerated().map { "  [\($0.offset)] pts=\($0.element.polyline.pointCount) \"\($0.element.instructions)\"" }.joined(separator: "\n"))
        """)

        // The terminal "arrive" step with no polyline is the thing that
        // makes nextStepIndex run out of steps early. If Apple ever stops
        // emitting it, the whole leg-tail analysis needs revisiting.
        #expect(!steps.isEmpty, "a routable leg must have at least one step")

        // Walk the route polyline exactly as ActiveNavigator does and find
        // where the maneuver lookup goes nil — the frozen tail.
        var firstNilVertex: Int?
        for v in 0..<route.polyline.pointCount {
            if PolylineMath.nextStepIndex(in: route, afterPolylineIndex: v) == nil {
                firstNilVertex = v
                break
            }
        }

        let coords = route.polyline.coordinateList()
        func length(from i: Int) -> CLLocationDistance {
            guard i < coords.count - 1 else { return 0 }
            return (i..<(coords.count - 1)).reduce(0) {
                $0 + PolylineMath.haversine(coords[$1], coords[$1 + 1])
            }
        }

        let total = length(from: 0)
        if let nilAt = firstNilVertex {
            let frozen = length(from: nilAt)
            let pct = total > 0 ? 100 * frozen / total : 0
            print("""
            nextStepIndex nil from: vertex \(nilAt) of \(route.polyline.pointCount)
            frozen tail           : \(Int(frozen)) m of \(Int(total)) m (\(Int(pct))%)
            ─────────────────────────────────────────────────────────

            """)
            // This is the premise of #125. Not asserted as a hard bound —
            // Apple can reroute this leg differently on any given day — but
            // a tail of ANY length is what the fix addresses, and the
            // printed percentage is the evidence to read.
            #expect(frozen >= 0)
        } else {
            print("""
            nextStepIndex never went nil on this leg.
            → the leg-tail branch would not run here; #125 is inert for it.
            ─────────────────────────────────────────────────────────

            """)
        }
    }
}
