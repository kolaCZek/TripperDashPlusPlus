# TripperDashPP/

iOS app source (Swift 6 / SwiftUI, iOS 18+).

## Layout

```
App/         @main + AppStatus (shared observable state) + LocationService + VoiceNavigator (offline AVSpeechSynthesizer)
UI/          SwiftUI views (RootView, MapPickerView, MapPreviewView, StreamingView, InteractiveMapView)
  Navigation/  destination search / route preview / favorite-editor sheets, NavigationHUD, QuickAccessTiles, RouteProgressMap
Tripper/     K1G control plane — BikeLink, DashSocket (BSD UDP), K1GPacket, RsaHandshake, HeartbeatLoop,
             DeviceTelemetry (phone status), CallStateObserver (OEM call card)
Stream/      VideoToolbox H.264 encoder + RTP packetizer — FrameSource, H264Encoder, RtpStreamer, RtpPacketizer
Map/         OSM raster tile pipeline + BG-safe CGContext frame source
             (MapViewSource, OSMTileFetcher, RouteTileCache, TileDiskCache, WebMercator, SnapshotterPark, TileColorTransform, SolarClock)
Navigation/  routing + search + active-nav loop + on-route geometry (ActiveNavigator, ActiveNavLoop,
             RoutingService, LocalSearchService, NavigationStore, PolylineMath, GPXParser, SavedRoutesStore, ManeuverLog,
             VoicePhrase + VoicePromptScheduler — spoken-prompt phrasing/tiers for VoiceNavigator)
  Models/    Destination, Favorite, NavSettings, DashNavSettings, ManeuverIcon, RoundaboutInstructionParser, SavedRoute, MapStyleSettings
RideAlerts/  keyless ride enrichment — WeatherAlertService (Open-Meteo, whole-route look-ahead),
             SpeedLimitService + MaxspeedParser (OSM maxspeed → posted-limit sign), SpeedCameraService (OSM/Overpass)
RideStats/   GPS-only trip computer — RideStats (accumulator), RideStatsFormatting, RideStatsService (live session). Phone-side only
Info.plist
TripperDashPPTests/   Swift Testing unit tests (weather-along-route, ride-stats formatting, next-waypoint label)
```

Background keep-alive (CoreLocation Always updates) and the
H.264 session auto-rebuild live in `App/` (`AppStatus`, `LocationService`) and
`Stream/H264Encoder.swift` respectively — there is no separate `Background/` group.
Spoken guidance (`VoiceNavigator`) owns the shared `AVAudioSession` so prompts
play over the locked screen; the `audio` background mode is backed by that real
feature, not a silent-loop wakelock.
(An AVKit PiP anchor was a third wakelock until Phase 8d, when it was removed — the
tile-cache + CGContext path is background-safe without it.)

## Build prerequisites

None beyond Xcode 26 + a free Apple Developer account. The map uses the
OSM Carto raster basemap (one keyless tile source; the dark palette is a
runtime recolour of the same tile, no second download; no third-party
SDK, no API token, no Secrets file); routing and search use Apple MapKit,
which is built into iOS. Just open the project and Run on a real device.
