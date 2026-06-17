# Phase 5 — Live map rendering (on-device test plan)

## What we're validating

`MapSnapshotSource` renders Apple Maps via `MKMapSnapshotter` at 12 fps,
centered on the rider's current GPS, with the camera rotated to match
the bike's heading. Frames go straight into the H.264 encoder.

No third-party SDK, no API key — Apple Maps is bundled with iOS.

## Pre-flight

- iPhone with iOS 18+ paired with Xcode 26.
- Location permission **Always** (not just While Using) — otherwise the
  stream dies on lockscreen.
- The fake_dash receiver running on your Mac (`tools/fake_dash/`) so you
  can watch what the bike would see.

## Tests

### 1. Foreground stream

1. Run app on device, connect to fake_dash, hit Start Streaming.
2. Walk around outside (or open Simulator with a custom location route).
3. Expect on the fake_dash capture: 12 fps, smooth map, road names
   legible, current position centered, camera rotating with phone
   heading.

### 2. Screen-off (the critical one)

1. Start streaming as in test 1.
2. Lock the phone.
3. Keep walking ~30 s.
4. Unlock and check Console.app for `MapSnapshotter` errors.

**Pass criteria:** no
`kIOGPUCommandBufferCallbackErrorBackgroundExecutionNotPermitted`,
fake_dash capture continues to update with new positions, no frozen
frame for more than ~1 s.

**Fail signal:** repeated `MKMapSnapshotter failed [#N]` lines in the
log. Code automatically re-emits the last good frame so the dash
decoder stays fed, but the map will freeze on screen.

### 3. Long-haul drift

Stream for 20 minutes. Watch:
- Battery drain (target: under 20%/h with screen off).
- Memory (Xcode Debug Navigator) — should be flat, no leaks from the
  pixel buffer pool.
- VideoToolbox session — should not auto-rebuild more than once or
  twice (any kIOSurfaceErr / kVTInvalidSessionErr triggers rebuild).

## Logs to grep

- `MapSource:` — our own diagnostics (start, stop, BG/FG transitions).
- `LocationService` — fix mode + heading state.
- `MKMapSnapshotter failed` — the only Apple Maps error that matters.
- Ignore: `PerfPowerTelemetry`, `PPSClientDonation`,
  `default.csv`, `CAMetalLayer ignoring invalid setDrawableSize` —
  internal Apple Maps noise, sandbox-blocked telemetry, harmless.

## Next steps after Phase 5 passes

- Phase 6: VT session auto-rebuild after backgrounding (validated in
  parallel).
- Phase 7: turn-by-turn route overlay (we already kept the hook for it
  in `MapSnapshotSource`).
