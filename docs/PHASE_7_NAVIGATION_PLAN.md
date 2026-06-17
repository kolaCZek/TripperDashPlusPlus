# Phase 7 — Turn-by-turn navigation (planning doc)

> Status: not started. This doc captures the goal, the known
> obstacles, and the candidate approaches so we don't lose context
> between sessions.

## Goal

Add destination selection + turn-by-turn navigation to TripperDash++:

1. **Pick destination from a real interactive map** — tap-to-drop pin,
   search bar, "Use my current location", recent destinations.
2. **Calculate route** via `MKDirections.calculate()`.
3. **Stream the route line + next turn instruction overlay** to the
   dash on top of the existing `MapSnapshotSource` pipeline.
4. **Voice prompts** for upcoming turns via `AVSpeechSynthesizer`.
5. **Camera follow** rider's heading + zoom-to-next-maneuver framing.

## The hard problem we already paid for

We tried using SwiftUI `Map(position:)` in `MapPickerView` as a step
toward interactive map UI. It crashed on `NavigationStack` pop with
the classic `MTLDebugDevice` assertion:

```
-[MTLDebugDevice notifyExternalReferencesNonZeroOnDealloc:] failed assertion
'The following Metal object is being destroyed while still required to be alive
by the command buffer …'
```

Root cause: SwiftUI's `Map` wraps `MKMapView`, which has its own
CAMetalLayer command buffer. When SwiftUI dealloc's the wrapped view
during navigation teardown, the Metal CB is still draining on the GPU
and Apple's debug layer asserts. Tell-tale log line right before the
crash: `CAMetalLayer ignoring invalid setDrawableSize width=0 height=0`
(= MKMapView going to zero size mid-teardown).

The workaround we shipped (commit `65b7575`): rip out the live map
entirely and render `MKMapSnapshotter → UIImage` at 1 Hz instead.
Works, but no pan/zoom/tap interactivity. Fine for a preview, useless
for picking a destination.

## Candidate approaches for Phase 7

Listed in order of "cheapest to try" → "most invasive":

### A. UIViewRepresentable wrapper around MKMapView with hardened teardown

Write our own `MapKitMapView: UIViewRepresentable` instead of using
SwiftUI's `Map`. In `dismantleUIView(_:coordinator:)`:

1. Set `mapView.delegate = nil` (cuts off callbacks immediately).
2. Set `mapView.isHidden = true` and `removeFromSuperview()` — gets
   the view out of the render tree before SwiftUI dealloc's it.
3. Park the `MKMapView` in a `SnapshotterPark`-style ring buffer so
   it stays alive past its Metal CB drain window.

This is the cheapest fix in theory. The pitfall is that we have less
control over MKMapView's Metal lifecycle than over MKMapSnapshotter's
— Apple doesn't expose its command queue.

Estimated effort: 1 hour to try, may or may not work.

### B. Host the MKMapView outside the NavigationStack

Keep one persistent `MKMapView` in the root `RootView`, and use SwiftUI
`overlay`/`zIndex` to show/hide it on top of navigation children
instead of pushing/popping it. The view never gets deallocated → no
teardown race.

Downside: more architectural rework. The MKMapView has to coexist with
unrelated screens (settings, diagnostics) without leaking state.

Estimated effort: half a day.

### C. Present destination picker as a `.sheet` / `.fullScreenCover`

Modal presentations have different lifecycle semantics than
NavigationStack push/pop. Apple's own Maps app uses this pattern. If
SwiftUI Map survives modal dismiss reliably, this is the simplest
architectural fix.

Estimated effort: ~2 hours, plus rework of the Connect/Disconnect
button flow.

### D. CarPlay / external display rendering

Apple's official path for nav apps is to render the actual map UI
on a CarPlay screen or via the new Live Activities / accessory APIs.
Doesn't help us here (dash is over Wi-Fi, not CarPlay), but the API
surfaces are interesting — `CPMapTemplate`, `CPRouteInformation` etc.
have lifecycle Apple actually supports for nav.

Doesn't solve the picker problem on the phone side. Skip for now.

### E. Roll our own picker with a static map + tap recognition

Use `MapPreviewView` (the 1 Hz UIImage we already have) and overlay a
`TapGesture` that converts screen-space tap → map coordinate via the
`MKMapSnapshotter.SnapshotPoint(for:)` inverse. Add a search bar that
calls `MKLocalSearch`. No live map view at all → no crash possible.

Downside: no pinch zoom, no pan; user has to type address or zoom by
buttons. UX is meh but it would 100% not crash.

Estimated effort: half a day.

## Recommended approach (subject to revisit)

**Start with A.** It's the cheapest reality check on whether we can
keep a live map at all. If A still crashes after `dismantleUIView`
hardening, jump to **C** (sheet presentation) since that's the next
most idiomatic SwiftUI pattern. If both fail, fall back to **E**
(static picker with tap → coordinate). **B** is overkill unless we end
up wanting one map view across many screens.

**Do NOT bring Mapbox back.** The background GPU restriction is the
real blocker, not the renderer. Mapbox would re-introduce the SDK +
token plumbing for zero gain.

## Implementation notes for whenever we get there

### Routing
- `MKDirections.Request().source/destination = MKMapItem(...)`
- `request.transportType = .automobile` — Apple Maps has motorcycle?
  Last I checked no, `.automobile` is closest.
- `request.requestsAlternateRoutes = false` — we only want the
  primary route.

### Turn-by-turn data
- `MKRoute.steps: [MKRouteStep]`
  - `.instructions: String` — "In 200 meters, turn right onto Foo St."
  - `.distance: CLLocationDistance` — meters to this step's start
  - `.polyline: MKPolyline` — geometry for highlighting
  - `.transportType` etc.
- Track active step via geofencing on the rider's GPS fix; when within
  N meters of next maneuver, fire voice prompt + dash overlay.

### Voice prompts
- `AVSpeechSynthesizer` with a `cs-CZ` voice (Martin rides in CZ).
- Pre-announce at 500 m, 100 m, "now".
- Play through the wakelock audio session — already plumbed for
  background keep-alive, just switch from silent buffer to TTS audio
  on prompt.

### Dash overlay
- Add a `RouteOverlay` layer to `MapSnapshotSource` that draws the
  active `MKPolyline` step in a high-contrast color on top of the
  snapshot before encoding.
- Top-left corner gets "↰ 200 m" (next maneuver direction arrow +
  distance) as a `UIGraphicsImageRenderer` overlay.

### Forward compat already in place

`AppStatus.sourceKind: SourceKind` enum was added in Phase 5 with
`.liveMap` default and a placeholder `.navigation` case reserved.
When we add Phase 7, `MapSnapshotSource` switches on `sourceKind` to
decide whether to draw the route overlay. Already wired.

## What NOT to forget

- The whole reason for `MKMapSnapshotter` over `MKMapView` for the
  streaming path is the iOS 16+ background GPU restriction. Phase 7
  navigation rendering on the **dash side** still goes through
  `MapSnapshotSource` (which uses MKMapSnapshotter and survives
  background). Only the **picker UI** in the foreground needs a live
  interactive map.
- `SnapshotterPark` ring buffer pattern in `MapSnapshotSource.swift`
  is reusable for any `MKMapView` parking we end up needing in A.
