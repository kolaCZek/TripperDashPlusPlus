# Phase 7 — Turn-by-turn navigation (planning doc, revised)

> Status: planning. On-bike connectivity test happens first (next
> session). After that we start implementing 7b onward.
>
> Previous version of this doc focused on *can we even keep a live
> map alive*. That's solved (mutually exclusive picker/navigation
> phases, commit f21ad22). This revision is the feature plan.

## Goal

Full in-house turn-by-turn navigation that streams the route to the
Tripper Dash via existing H.264 pipeline. No CarPlay, no third-party
SDK, no Mapbox. All Apple Maps frameworks (MapKit + MKDirections +
CoreLocation).

## Decisions (locked in 2026-06-17)

- **Alternatives:** show plain "Route 1 / 2 / 3" with ETA + km. No
  auto-labelling (Fastest/Shortest/Eco) — Apple doesn't return that
  metadata and our guesses would be wrong as often as right.
- **Voice prompts:** deferred. Phase 7 ships text-only. AVSpeechSynthesizer
  cs-CZ comes in a later micro-phase once on-bike UX is dialed.
- **Favorites:** unlimited list. Top 4 user-selected slots appear as
  highlighted "Quick Access" tiles on the picker screen (default:
  Home, Work, two empty). Rest live in an "Others" expandable section.
- **Search bias:** `MKLocalSearchCompleter.region` = ~100 km box around
  current location (covers practical day-trip range on a 450).
  Fallback when GPS unavailable: bbox of ČR (`49.8°N, 15.5°E` ±300 km).
  Soft bias only — results outside the box still appear, just ranked
  lower. `resultTypes = [.address, .pointOfInterest]`.
- **Pre-flight (no-dash) mode:** navigation works fully without the
  bike connected. Picker/navigation UI is independent of `BikeLink`.
  When `bikeLink.state == .connected` we additionally push the route
  polyline to MapSnapshotSource for the dash. When not, we just don't.
- **Route preferences:**
  - **Avoid highways** — `MKDirections.Request.highwayPreference = .avoid`
  - **Avoid tolls** — `MKDirections.Request.tollPreference = .avoid`
  - **Avoid ferries** — *not directly supported by MKDirections API.*
    Workaround: post-filter returned routes, reject any whose steps
    contain `MKRoute.advisoryNotices` mentioning ferry or whose
    polyline crosses known ferry water. Honest limitation: this is
    imperfect. Likely fine for ČR (no real ferries on common routes).
    Document the gap in Settings as "Best-effort, MKDirections has no
    native ferry exclusion."

## Architecture

```
┌─ MapPickerView (picker phase) ─────────────────────┐
│  ┌─ Search bar (sticky top) ──────────────────────┐│
│  │ "Where to?" → MKLocalSearchCompleter           ││
│  └────────────────────────────────────────────────┘│
│                                                    │
│  ┌─ Quick Access (4 tiles) ───────────────────────┐│
│  │ [Home] [Work] [+]    [+]                       ││
│  └────────────────────────────────────────────────┘│
│  ┌─ Others (collapsible) ─────────────────────────┐│
│  │ • Mountain hut Zvolenves                       ││
│  │ • Friend's garage                              ││
│  └────────────────────────────────────────────────┘│
│                                                    │
│  ┌─ Live InteractiveMapView ──────────────────────┐│
│  │  tap → drop pin → "Navigate here" sheet        ││
│  │  long-press on existing favorite → edit/delete ││
│  └────────────────────────────────────────────────┘│
└────────────────────────────────────────────────────┘

    ↓ user picks destination ↓

┌─ Route preview ────────────────────────────────────┐
│  Map shows all alternatives, selected one bold     │
│  ┌─ Route 1 ─────────┐ 45 min  •  62 km            │
│  │ via D7            │                            │
│  └───────────────────┘                            │
│  ┌─ Route 2 ─────────┐ 51 min  •  55 km            │
│  │ via 16            │                            │
│  └───────────────────┘                            │
│  [Start navigation] (red CTA)                      │
└────────────────────────────────────────────────────┘

    ↓ Start ↓

┌─ MapPickerView (navigation phase) ─────────────────┐
│  ┌─ Next maneuver card ───────────────────────────┐│
│  │  ↰ 350 m                                       ││
│  │  Turn left onto Nová ulice                     ││
│  └────────────────────────────────────────────────┘│
│  ┌─ ETA strip ────────────────────────────────────┐│
│  │  15:42  •  32 min  •  44 km remaining          ││
│  └────────────────────────────────────────────────┘│
│                                                    │
│  [Stop navigation] (red CTA)                       │
│                                                    │
│  (no live map — dash gets the route view via the   │
│   existing MapSnapshotSource pipeline if connected)│
└────────────────────────────────────────────────────┘
```

## Sub-phases (incremental, each independently testable)

| Phase | What | Est. effort | Risk |
|-------|------|-------------|------|
| **7b** | Search bar + `MKLocalSearchCompleter` (autocomplete) + `MKLocalSearch` resolve → destination | ~3 h | low |
| **7c** | Tap-to-drop pin on `InteractiveMapView` + "Navigate here" sheet | ~1 h | low |
| **7d** | Favorites model + UserDefaults persistence + Quick Access tiles + Others list + add/edit/delete UI | ~3 h | low |
| **7e** | `MKDirections` route preview screen: render alternatives, allow selection | ~3 h | low |
| **7f** | Active navigation HUD: next maneuver card, ETA strip, remaining distance, on-route detection | ~4 h | medium (geometry math) |
| **7g** | Route polyline + arrow overlay drawn into MapSnapshotSource → streamed to dash | ~3 h | medium (UIGraphicsImageRenderer compositing in tight FPS budget) |
| **7h** | Reroute logic with hysteresis (off-route ≥ 60 m AND ≥ 5 s → reroute; min 30 s between reroutes) | ~3 h | medium (needs field test to tune thresholds) |
| **7i** | Route Preferences Settings panel: avoid highways / tolls / ferries toggles, persisted | ~1 h | low |

**Total ~23 h.** Realistic over a weekend.

## Build order rationale

`7b → 7c → 7d` unlocks "pick a destination" without any routing
logic. Even at that point the app is useful for *trying* the workflow.

`7e → 7f` adds route preview and active navigation on the phone. Still
no dash overlay.

`7g` is where the dash starts showing the route. This is the
high-stakes integration with the existing MapSnapshotSource ring
buffer — we have to render the polyline into the 1052×600 supersample
*and* keep the parking ring strategy intact. Risk: compositing the
polyline at 6 FPS may push CPU above the budget. Mitigation: cache the
polyline raster between snapshots since the route doesn't change every
tick, only the user position moves.

`7h` (reroute) needs real on-bike testing — desktop simulator can't
fake the GPS jitter that comes from real-world conditions (urban
canyon, tunnel exit, etc.).

`7i` (route preferences) is genuinely 1 hour but ships last because the
others need a working baseline before toggles matter.

## API-level notes

### Search

```swift
let completer = MKLocalSearchCompleter()
completer.resultTypes = [.address, .pointOfInterest]
completer.region = MKCoordinateRegion(
    center: locationService.lastFix?.coordinate ?? czechRepublicCenter,
    latitudinalMeters: 100_000,
    longitudinalMeters: 100_000
)
completer.queryFragment = userTypedText  // triggers async updates
// delegate: completerDidUpdateResults → completer.results: [MKLocalSearchCompletion]
```

Resolve to actual coordinates on selection:

```swift
let req = MKLocalSearch.Request(completion: selected)
let response = try await MKLocalSearch(request: req).start()
let item = response.mapItems.first  // has .placemark.coordinate + address
```

### Routing

```swift
let req = MKDirections.Request()
req.source = .forCurrentLocation()
req.destination = MKMapItem(placemark: MKPlacemark(coordinate: dest))
req.transportType = .automobile
req.requestsAlternateRoutes = true
req.highwayPreference = preferences.avoidHighways ? .avoid : .any
req.tollPreference = preferences.avoidTolls ? .avoid : .any

let response = try await MKDirections(request: req).calculate()
let routes = response.routes
    .filter { preferences.avoidFerries ? !routeUsesFerry($0) : true }
    .prefix(3)
```

### Active nav — on-route detection

```swift
// Each location update:
let dist = polyline.distance(from: currentCoord)  // perpendicular distance
let onRoute = dist < 60  // meters
let progressIndex = polyline.nearestSegmentIndex(to: currentCoord)
let remaining = polyline.length(from: progressIndex)
let nextManeuver = route.steps.first { $0.polyline.startIndex > progressIndex }
```

`MKPolyline` doesn't expose `distance(from:)` natively — we'll compute
it via Haversine on each segment. Cache last `progressIndex` so we
only walk forward, not the full polyline every tick.

### Reroute hysteresis

```swift
if !onRoute {
    if offRouteSince == nil { offRouteSince = .now }
    if .now - offRouteSince! > 5 && distFromRoute > 60 {
        if .now - lastReroute > 30 {
            await reroute(from: currentCoord, to: destination)
            lastReroute = .now
        }
    }
} else {
    offRouteSince = nil
}
```

## Persistence schema

`UserDefaults` keys (single struct, JSON-encoded):

```swift
struct NavSettings: Codable {
    var favorites: [Favorite]              // ordered list
    var quickAccessSlotIds: [UUID?]        // exactly 4 slots, nil = empty
    var avoidHighways: Bool
    var avoidTolls: Bool
    var avoidFerries: Bool
}

struct Favorite: Codable, Identifiable {
    let id: UUID
    var name: String           // "Home", "Work", custom
    var icon: String?          // SF Symbol name, optional
    var coordinate: CLLocationCoordinate2D
    var addressLine: String?   // for display
    var createdAt: Date
}
```

Migration plan: none yet (greenfield). When schema changes, bump a
`schemaVersion: Int` field and write a one-shot migrator.

## Open questions for later

- Should "Start navigation" automatically `connect()` the bike if it's
  in `.idle`? Or stay manual? (Current thinking: stay manual — user
  may want to plan a route at home before riding.)
- Lock-screen Live Activity with ETA + next maneuver? `ActivityKit`
  works without CarPlay entitlement. Nice-to-have for later.
- Apple Maps' "search along route" — we could query POIs (fuel,
  coffee) within N km of current route. Phase 8 material.

## Reference

- [`MKLocalSearchCompleter`](https://developer.apple.com/documentation/mapkit/mklocalsearchcompleter)
- [`MKDirections`](https://developer.apple.com/documentation/mapkit/mkdirections)
- [`MKRoute.steps`](https://developer.apple.com/documentation/mapkit/mkroute/1452466-steps)
- [`MKDirections.Request.tollPreference`](https://developer.apple.com/documentation/mapkit/mkdirections/request/3856130-tollpreference) (iOS 16+)
- [`MKDirections.Request.highwayPreference`](https://developer.apple.com/documentation/mapkit/mkdirections/request/3856129-highwaypreference) (iOS 16+)
