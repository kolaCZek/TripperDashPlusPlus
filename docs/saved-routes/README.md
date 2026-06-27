# Saved routes — GPX import & navigation

Import a GPX file, save it to an on-device library, and navigate it with
the existing turn-by-turn / reroute / dash-glyph engine. No parallel
navigation stack — a saved route is just a pre-seeded `PlannedRoute`.

## Rider-facing flow

1. **Map picker → toolbar** now has a *Saved routes* button (the
   route-curve glyph) to the left of the gear/Settings button.
2. Tapping it opens the **Saved routes** sheet:
   - empty state offers **Import GPX**;
   - the toolbar's down-arrow also imports.
3. **Import GPX** drives the system document picker
   (`.fileImporter`). Pick a `.gpx` file → it's parsed, reduced if
   needed, and saved. A green "Imported …" confirmation flashes.
4. Tap a saved route → **detail**:
   - a **map preview** at the top shows the route's shape (start = green
     dot, end = red dot, blue casing line) so the rider recognises it at
     a glance before starting;
   - rename it;
   - **Edit** (top-right) to prune or reorder its points (see below);
   - delete it, or **Start navigation**.
5. **Start navigation** stages a `PlannedRoute` (origin = live GPS) and
   dismisses back to the picker, which shows the normal planning UI.
   From there the existing *Connect to dash → Start* path takes over
   unchanged (auto-start, reroute, arrival, dash glyphs all apply).

## Editing a saved route

The detail screen's **Edit** button (`EditButton`) reveals per-point
editing in the *Points* section:

- **Delete a point** — swipe or the red minus. The store enforces a
  **2-point floor** (`updatePoints` refuses to drop below start+end), and
  a multi-delete that would cross the floor only removes down to it.
- **Reorder points** — drag handles, **waypoint routes only**. A recorded
  `.track`'s order *is* its shape, so reordering is disabled there (the
  `.onMove` handler is `nil`) — only deletion of a stray point is offered.
- Every edit calls `SavedRoutesStore.updatePoints`, which **recomputes
  the stored distance** from the new geometry and re-persists. The map
  preview re-renders to match.

## How a GPX file maps to a route

The importer (`GPXImporter.parse`) picks ONE geometry, by priority:

| GPX content          | `RouteKind`  | Treatment                                  |
|----------------------|--------------|--------------------------------------------|
| `<rte><rtept>`       | `.track`     | reduced to ≤24 via-points (Douglas–Peucker)|
| `<trk><trkseg><trkpt>` | `.track`   | all segments concatenated, then reduced    |
| `<wpt>` only         | `.waypoints` | every waypoint kept as a real stop         |

- If a file has **both** a track and loose waypoints, the **track wins**
  (it's the actual intended path); the stray `<wpt>`s are ignored so two
  unrelated geometries don't get mixed.
- Namespacing is tolerated (`gpx:trkpt`, default ns, etc.) — matching is
  on the element's **local name**.
- Points with missing / NaN / out-of-range `lat`/`lon` are skipped, not
  fatal.
- Named points (`<name>` inside a `<wpt>`/`<rtept>`) are **force-kept**
  through reduction — a rider-named fuel stop or viewpoint never gets
  simplified away.
- **Distance** is measured along the FULL, pre-reduction trace, so a
  simplified track still reports its true on-the-ground length.

### Why ≤24 via-points

MKDirections is called once per leg (point→point), so the cap bounds
network + recompute cost. 24 legs is already a long tour; Douglas–Peucker
keeps the most significant vertices, so the navigated line still tracks
the original GPX closely. This reuses the existing multi-waypoint engine
(`PlannedRoute` + `RoutingService`) verbatim — see
`AppStatus.beginPlanningFromSavedRoute`.

## Start mode: first vs nearest

When the rider taps Start, `RouteStartPlanner.analyze` compares the live
fix to the route:

- **From the first point** — drive to the route start, then ride the
  whole thing start→end.
- **From the nearest point** — snap onto the route at the closest point
  and ride from there (skip the leading portion already behind you).

The app only **prompts** when the nearest point isn't the first one AND
starting from first would mean a meaningful (>300 m) detour backwards.
Otherwise it silently starts from the first point. The live GPS location
is always prepended as the routing origin so MKDirections has a real
source for the first leg.

## Persistence

`SavedRoutesStore` mirrors `NavigationStore`: a single versioned
`Codable` payload (`SavedRoutesStore.v1`) in `UserDefaults`, CRUD that
persists on every mutation, tolerant decode (falls back to empty rather
than throwing). It's a **separate** store from `NavSettings` so a corrupt
route library can't take the rider's Home/Work pins down with it.

## Files

| File | Role |
|------|------|
| `Navigation/Models/SavedRoute.swift` | `SavedRoute` + `RoutePoint` + `RouteKind` (Codable) |
| `Navigation/GPXParser.swift` | `GPXImporter` (SAX) + `GPXGeometry` (haversine, RDP, validity) |
| `Navigation/SavedRoutesStore.swift` | persisted library, CRUD |
| `Navigation/RouteStartPlanner.swift` | pure first/nearest decision logic |
| `UI/Navigation/SavedRoutesListView.swift` | library list + `.fileImporter` |
| `UI/Navigation/SavedRouteDetailView.swift` | preview / rename / edit points / delete / start |
| `UI/Navigation/SavedRoutePreviewMap.swift` | static `MKMapSnapshotter` route thumbnail (polyline + start/end pins) |
| `App/AppStatus.swift` | `beginPlanningFromSavedRoute(_:mode:nearestIndex:)` |
| `UI/MapPickerView.swift` | toolbar button + sheet wiring |

## Tests

The geometry + start logic is mirrored 1:1 in Python so it's pinned
without booting Xcode (the app code imports SwiftUI/MapKit, which only
build on a Mac):

- `tools/fake_dash/tests/gpx_geometry_mirror.py` — port of `GPXGeometry`
  (incl. `bounding_span` used by the preview map) + `RouteStartPlanner` +
  the GPX extraction-priority rule.
- `tools/fake_dash/tests/test_gpx_import.py` — 48 tests: haversine,
  perpendicular distance, RDP reduce (endpoints/names kept, hard cap,
  order preserved, idempotent), extraction priority (rte>trk>wpt),
  tolerance (namespaces, bad coords, name fallback), full-trace distance,
  start-mode analyze + navigable-point truncation, and preview bounding
  span (center, padding, min-span clamp, order-independence).

```
make fake-dash-test          # in the container
# or, locally:
cd tools/fake_dash && python3 -m pytest tests/test_gpx_import.py -q
```

## Not done here / future

- **"Open in TripperDash++" from another app** — would need a
  `UTImportedTypeDeclarations`/`CFBundleDocumentTypes` GPX entry in
  Info.plist. The current button-driven `.fileImporter` needs no plist
  change. Left out of this PR deliberately.
- **Pixel-perfect GPX polyline following** — by design we route via
  MKDirections between reduced points, not by snapping to the raw GPX
  line. This keeps maneuver glyphs, reroute, and ETA working. A true
  "ride the exact line" mode would be a separate engine.
- **Build verification** — written + statically checked on Linux
  (cross-file API audit, brace balance, Python mirror suite green). A
  real `xcodebuild` pass on a Mac is still required before shipping.
