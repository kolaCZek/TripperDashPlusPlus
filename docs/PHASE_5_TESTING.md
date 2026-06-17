# Phase 5 — Live Map Source Testing

The Mapbox-backed `MapSnapshotSource` replaces the Phase 4 `TestPatternSource`
as the default frame source. The dash now shows the rider's real-world
position rendered at 12 fps in the `navigation-night-v1` style instead of
a synthetic test card.

This runbook validates the end-to-end pipeline:

```
LocationService ─► MapSnapshotSource ─► H264Encoder ─► RtpPacketizer ─► UDP → bike:5000
```

## Pre-flight (one-time setup, do this BEFORE first build)

You need TWO Mapbox tokens from <https://account.mapbox.com/access-tokens/>.

### 1. Public token (`pk.*`)

Used by the app at runtime to fetch tiles. URL-restrict it to the bundle
identifier `eu.kolaczek.TripperDashPP` so it can't be abused if it leaks.

```bash
cd TripperDashPP
cp Secrets.xcconfig.example Secrets.xcconfig
# edit Secrets.xcconfig and paste your pk.eyJ... token after MBX_ACCESS_TOKEN=
```

`Secrets.xcconfig` is gitignored. The Info.plist already references it via
`$(MBX_ACCESS_TOKEN)` → `MBXAccessToken`.

### 2. Secret download token (`sk.*`)

Used by Swift Package Manager to download the closed-source Mapbox SDK
binary. Scope: `Downloads:Read` only. Lives in `~/.netrc`:

```
machine api.mapbox.com
  login mapbox
  password sk.YOUR_SECRET_DOWNLOAD_TOKEN
```

Then `chmod 600 ~/.netrc` (SPM refuses world-readable netrc files).

### 3. Resolve packages

In Xcode: **File → Packages → Resolve Package Versions**. First resolution
downloads ~150 MB; subsequent builds are cached.

If you see `failed to download. status: 401`, your `~/.netrc` token is
wrong or the file is world-readable.

---

## Test 1 — Cold start, "Acquiring GPS…" placeholder

**Goal:** confirm the source emits frames even before the first GPS fix
lands, so the dash doesn't sit on the K1G handshake screen forever.

1. Force-quit the app, toggle airplane mode on, then off.
2. Connect to the dash (`MapPickerView` → "Connect to dash").
3. `StreamingView` → Source picker = `Live map` → Start.
4. **Within ~1 s** the dash should show a dark background with the text
   `Acquiring GPS…` rendered in white monospaced.
5. As soon as iOS reports the first fix (typically 2–10 s outdoors), the
   placeholder is replaced by a real map tile.

PASS = placeholder appeared, then transitioned to a map within 15 s
outdoors. If the dash stays on the K1G splash, the source never produced
a frame — check `os_log` for `MapSource` warnings.

## Test 2 — Live map, stationary

**Goal:** baseline encoded fps with the camera not moving.

1. Outdoors, GPS fix acquired, streaming `Live map`.
2. Watch the `Encoded fps` row in `StreamingView` for 30 s.
3. Expected: **6–12 fps** sustained. The exact number depends on the
   device — iPhone 13+ should hit 10–12; older devices may sit at 6–8
   because Snapshotter re-renders the whole layer each tick rather than
   composing incremental updates.
4. `Packets dropped` should be 0. Any non-zero drop count means the UDP
   send queue is backed up — check the Wi-Fi RSSI on the bike.

PASS = ≥6 fps sustained, 0 drops.

## Test 3 — Live map, on the move (the real test)

**Goal:** validate the camera follows the bike at riding speed.

1. Mount the phone, start streaming `Live map`, ride.
2. Confirm on the dash that:
   - The map re-centres on every GPS update (~1 Hz from CoreLocation).
   - The map rotates with the bike: at zero speed the heading comes from
     the magnetic compass (`lastHeading`), once moving it falls back to
     course-over-ground if compass accuracy is bad.
   - Streets visibly scroll past, not jump.
3. Stop the bike, screen-locks the phone. Streaming should continue (the
   Phase 6 wakelock is wired through `LocationService` now — same code
   path as before, different class name).

PASS = smooth camera follow with no >5 s freezes.

## Test 4 — Source switch round-trip

**Goal:** confirm the source picker swaps cleanly without leaking the
old source.

1. Streaming `Live map`. Stop streaming.
2. Switch picker to `Test pattern`. Start.
3. Expected: dash shows the Phase 4 test card.
4. Stop. Switch back to `Live map`. Start.
5. Expected: live map back. No double GPS prompt, no stuck blue
   background-location indicator after stopping.

PASS = both sources start cleanly from either order, no second
authorization prompt.

## Test 5 — Token misconfiguration

**Goal:** confirm graceful failure when `pk.*` is missing or bad.

1. Edit `Secrets.xcconfig`, set `MBX_ACCESS_TOKEN=pk.invalid`.
2. Clean build, run.
3. Start `Live map`. Expected: `Map error` text on dash, repeated. The
   stream does NOT crash; encoder keeps emitting (the placeholder /
   error frame still produces a valid IDR + slices).
4. `StreamingView` → Stream section → `lastError` should NOT be set,
   because the error is per-tile not per-pipeline.

PASS = stream stays alive, dash shows `Map error` text.

## Test 6 — LocationService consumer reconciliation

**Goal:** confirm the single shared `CLLocationManager` correctly
escalates from `.wakelock` (50 m, hundredMeters) to `.mapping`
(no filter, best) when the map source registers, and drops back when
the source releases.

1. Start streaming `Test pattern` with background keep-alive ON.
2. In `os_log` filter for `LocationService`: should see
   `Consumer XXXXXX added (mode=0)` and the manager running at
   hundredMeters accuracy.
3. Switch source to `Live map`, start. Should see a second
   `Consumer XXXXXX added (mode=1)` and the same manager now serving
   both — no second `LocationService` instance.
4. Stop streaming. Both consumers release, manager stops cleanly:
   `LocationService stopped (no consumers)`.

PASS = exactly one CLLocationManager lifecycle, mode transitions visible
in the log.

## Test 7 — Phase 7 hook smoke test (future-proofing)

**Goal:** confirm the abstraction is ready for the nav engine.

This is a code review test, not a runtime test:

1. `MapSnapshotSource` consumes GPS via `LocationService.subscribeFixes`
   — not by owning its own `CLLocationManager`. ✅ check
   `MapSnapshotSource.start(onFrame:)`.
2. `LocationService.subscribeFixes` returns a token whose deinit
   cancels — no manual cleanup needed when the nav engine wires up.
3. `MapSnapshotSource` already takes a camera per tick (`setCamera`) —
   the nav engine can override the camera by computing its own
   `CameraOptions` (chase-cam framing, maneuver preview) and the source
   doesn't need to know it's being driven externally vs from GPS.

If any of these are no longer true, Phase 7 will require a refactor.

---

## Known limits

- **Snapshotter is not as fast as a hidden MapView.** Real-world fps on
  an iPhone 13 sits around 8–10. We chose this path over the
  hidden-UIWindow trick because Snapshotter is the supported API and
  upgrades cleanly across SDK versions; the dash's H.264 pipeline
  tolerates 8–12 fps without visible stutter so the trade-off is fine.
- **First tile fetch on a cold cache takes 200–800 ms.** Frame 1 may
  be the "Acquiring GPS…" placeholder even after the fix lands; the
  real map shows up on frame 2 or 3.
- **No offline tile fallback yet.** Riding through a Wi-Fi/LTE dead
  zone will produce blank tiles until reception returns. Phase 8 may
  add a Mapbox offline region around the planned route.
