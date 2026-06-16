# TripperDashPP/

iOS app source. Created in Phase 1; built up over Phases 3–8.

## Layout (target — most of this is empty in Phase 1)

```
App/         @main + AppStatus (shared observable state)
UI/          SwiftUI views (RootView, MapPickerView, StreamingView, …)
Tripper/     K1G control plane (BikeLink, DashSocket, packet builders)   — Phase 3
Video/       VideoToolbox encoder + RTP packetizer                       — Phase 4
Map/         Mapbox off-screen renderer + frame capture                  — Phase 5
Network/     NWPathMonitor, dual-interface routing, WiFiMonitor          — Phase 6
Nav/         Route state machine, GPS handling, search                   — Phase 6
Background/  Location + audio keep-alive coordinator                     — Phase 6
Diagnostics/ os.Logger, log export, telemetry overlay                    — Phase 8
Resources/   Assets, silence.m4a (audio keep-alive), .strings            — Phase 6+
Info.plist
```

## Phase 1 status

- ✅ `TripperDashPPApp.swift` — `@main`, injects `AppStatus`
- ✅ `AppStatus.swift` — `@Observable` shared state, placeholder metrics
- ✅ `RootView.swift` — `NavigationStack` container
- ✅ `MapPickerView.swift` — status banner + map placeholder
- ✅ `StreamingView.swift` — telemetry surface (zeroed)
- ✅ `Info.plist` — capabilities, privacy strings, MBXAccessToken
- ⬜ Xcode project — to be created on the Mac (see `docs/PHASE_1_SETUP.md`)

## Secrets

`Secrets.xcconfig` is gitignored. Copy `Secrets.xcconfig.example` from the
repo root to `TripperDashPP/Secrets.xcconfig` and fill in:

- `DEVELOPMENT_TEAM` — your 10-char Apple Team ID
- `MBX_ACCESS_TOKEN` — Mapbox `pk.…` token (URL-restricted to the bundle ID)

Mapbox `sk.…` (Downloads:Read) goes in `~/.netrc`, never in the repo.
