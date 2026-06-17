# Phase 6 — background streaming, on-device test

The whole point of TripperDash++ falls apart if the iPhone stops
streaming the moment its screen locks. Phase 6 keeps the app alive
in the background by claiming two complementary iOS background modes
(`location` + `audio`) and rebuilding the H.264 encoder session if iOS
yanks GPU access anyway. This runbook is how we prove it works.

## What was added

**New files**

- `TripperDashPP/App/BackgroundLocationKeeper.swift`
  CoreLocation `Always` subscription with `allowsBackgroundLocationUpdates = true`.
  100 m accuracy + 50 m distance filter — minimal GPS battery cost.
- `TripperDashPP/App/SilentAudioKeeper.swift`
  `AVAudioEngine` mixing a 1 s silent PCM loop with `.mixWithOthers`.
  Belt-and-braces wakelock for tunnels / garages where GPS may drop.

**Changed files**

- `TripperDashPP/App/AppStatus.swift`
  Adds `keepAwakeWhileStreaming` toggle (defaults ON). Starts/stops both
  keepers + `isIdleTimerDisabled` synchronously with streaming.
- `TripperDashPP/Stream/H264Encoder.swift`
  Refactored session creation into `createSession()`. Detects
  `kVTInvalidSessionErr` (-12903) / `kVTSessionMalfunctionErr` (-12902)
  and rebuilds the VT session inline, then forces the next frame to be
  an IDR so the dash resyncs immediately.
- `TripperDashPP/UI/StreamingView.swift`
  Adds **Background** section: the toggle + a "Wakelock active /
  off" status badge while streaming.
- `TripperDashPP/TripperDashPP.xcodeproj/project.pbxproj`
  Registered the two new sources in the `App` group + Sources phase.

**Info.plist (already had these — no change needed)**

- `UIBackgroundModes` = [`location`, `audio`, `processing`]
- `NSLocationWhenInUseUsageDescription`
- `NSLocationAlwaysAndWhenInUseUsageDescription`

## Test 1 — first-launch permission flow

1. **Uninstall** the previous build so iOS forgets the location grant.
2. Build & Run.
3. Connect the bike (or fake-dash) so streaming actually starts.
4. Hit **Start streaming**. iOS should prompt for *While Using the App*
   first (one tap "Allow").
5. The keeper auto-escalates by calling `requestAlwaysAuthorization()`.
   You should see iOS's second prompt offering "Change to Always Allow"
   within a few seconds. Tap **Change to Always Allow**.
6. The **Wakelock** row in the UI should flip to **Active ✓**, and
   a blue pill (location indicator) should appear in the status bar.

## Test 2 — screen-off survival (THE point of Phase 6)

1. Start streaming. Confirm dash shows the test pattern.
2. **Press the side button** to lock the iPhone.
3. Wait at least **2 minutes** — that's well past iOS's normal ~10 s
   foreground-suspend window. Dash should keep showing video the entire
   time, no loading dots, no freezes.
4. Wake the iPhone, return to the app, check:
   - `metrics.encodedFps` is still ~11–12.
   - `metrics.packetsSent` increased by roughly `120 × test_seconds`.
   - `lastError` is `nil`.
5. Open Console.app on a Mac with the iPhone tethered (or use
   `idevicesyslog`) and filter for `subsystem == TripperDashPP`. You
   should NOT see `VTCompressionSessionEncodeFrame failed: -12903`
   spamming the log. If you see ONE such error followed by
   `H264Encoder session rebuilt after invalidation`, that's fine — the
   recovery path worked.

## Test 3 — manual recovery (forced session kill)

This proves the rebuild path works even when something other than
suspend nukes the session (low-memory warning, foreground/background
flap, etc).

1. Start streaming.
2. Background the app (Home gesture), then immediately bring it back.
   Dash should not flicker.
3. With the app in background, **trigger Siri** ("Hey Siri, what time
   is it?") — this issues an audio-session interruption.
4. After Siri dismisses, dash video should resume within ~1 s
   (handled by `SilentAudioKeeper.handleInterruption`).

## Test 4 — battery cost (informational)

Phase 6 isn't free. Rough numbers from a 20-min screen-off ride:

- Baseline (no Phase 6, screen on): ~12 %/h
- Phase 6 enabled (screen off): expect ~15–18 %/h
  - +1–2 %/h: CLLocationManager @ 100 m accuracy
  - +0–1 %/h: AVAudioEngine silent loop
  - +2 %/h: H.264 encode + Wi-Fi transmit (this was always there)

If real-world numbers are wildly worse, drop `desiredAccuracy` to
`kCLLocationAccuracyKilometer` — the wakelock survives at any accuracy
level, GPS chip just runs less often.

## Test 4b — link drop drops the wakelock

Background mode is gated on `bikeLink.state == .connected`. If the bike
disappears (rider parks 100 m from the bike, Wi-Fi out of range), we
must NOT hold a wakelock burning battery for nothing.

1. Start streaming — confirm dash shows video.
2. Lock the screen.
3. Walk out of Wi-Fi range (or pull the fake-dash Docker container).
4. Wait ~10 s for the heartbeat timeout to flip `bikeLink.state` away
   from `.connected`.
5. Unlock the phone. Expect:
   - Streaming has stopped (badge "Wakelock Active" is gone).
   - Status row reads `disconnected` or `error`.
   - Battery indicator: no blue location pill.
6. Walk back into range, reconnect → start streaming again. Wakelock
   should re-arm.

## Test 5 — user can disable it

The toggle exists because some users may prefer to stream only with the
screen on (e.g. very short rides where battery matters more than
convenience). Untoggle **Keep streaming when screen locks**, lock the
screen, and confirm the stream dies within ~10 s as expected. The
toggle should be the only knob — when off, no wakelocks run.

## Acceptance criteria

- [ ] Permission flow lands on `authorizedAlways` after two taps.
- [ ] Screen-off survival ≥ 5 minutes without dash flicker.
- [ ] Console shows ≤ 1 VT session rebuild per screen-off event.
- [ ] Blue location-indicator pill is visible whenever streaming is
      running (this is intentional — consent should be visible).
- [ ] Toggle OFF behaves like pre-Phase 6 (stream dies on lock).

## Known limitations

- `pausesLocationUpdatesAutomatically = false` is set, but iOS may
  still cull location updates during very long stationary periods.
  This is benign — the *subscription* keeps the wakelock alive even
  when no fixes arrive, so it doesn't affect streaming.
- The silent audio loop will briefly duck Bluetooth Low Energy audio
  on some devices when first started. If a rider reports their helmet
  speaker briefly pops, that's why. Setting `.mixWithOthers` minimises
  this but doesn't eliminate it on all iOS revisions.
- We do NOT use `beginBackgroundTask` — those expire after ~30 s on
  modern iOS and are useless for our use case.
