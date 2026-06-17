# TripperDashPP/

iOS app source. Created in Phase 1; built up over Phases 3–8.

## Layout

```
App/         @main + AppStatus (shared observable state) + LocationService
UI/          SwiftUI views (RootView, MapPickerView, StreamingView, …)
Tripper/     K1G control plane (BikeLink, DashSocket, packet builders)   — Phase 3
Stream/      VideoToolbox encoder + RTP packetizer                       — Phase 4
Map/         Apple MapKit off-screen renderer + frame capture            — Phase 5
Network/     NWPathMonitor, dual-interface routing, WiFiMonitor          — Phase 7
Nav/         Route state machine, GPS handling, search                   — Phase 6+
Background/  Location + audio keep-alive coordinator                     — Phase 6
Diagnostics/ os.Logger, log export, telemetry overlay                    — Phase 8
Resources/   Assets, silence.m4a (audio keep-alive), .strings            — Phase 6+
Info.plist
```

## Build prerequisites

None beyond Xcode 26 + a free Apple Developer account. The map renderer
uses Apple MapKit (`MKMapSnapshotter`) — no third-party SDK, no API
token, no Secrets file. Just open the project and Run on a real device.
