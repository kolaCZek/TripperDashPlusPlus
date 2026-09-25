# TripperDashPP/

iOS app source (Swift 6 / SwiftUI, iOS 18.6+).

## Layout

```
App/         @main + AppStatus (shared observable state) + LocationService + VoiceNavigator (offline AVSpeechSynthesizer) + DemoDashModel
UI/          SwiftUI views (RootView, MapPickerView, MapPreviewView, StreamingView, InteractiveMapView, RideStatsPanel,
             DashPreviewPanel, AddBikeSheet, PermissionsView)
  Navigation/  destination search / route preview / favorite-editor / saved-routes sheets, NavigationHUD, FreeRideHUD,
             PlanningMapView, WaypointListView, QuickAccessTiles, RouteProgressMap, PrerenderProgressView
Tripper/     K1G control plane — BikeLink, DashSocket (BSD UDP), K1GPacket, K1GConstants, RsaHandshake, HeartbeatLoop,
             DeviceTelemetry (phone status), CallStateObserver (OEM call card), DashMediaControl (track skip),
             WiFiJoiner (NEHotspotConfiguration AP join), SavedBikesStore (bike garage), String+DashSafe
Stream/      VideoToolbox H.264 encoder + RTP packetizer — FrameSource, H264Encoder, RtpStreamer, RtpPacketizer
Map/         OSM raster tile pipeline + BG-safe CGContext frame source
             (MapViewSource, OSMTileFetcher, RouteTileCache, TileDiskCache, WebMercator, SnapshotterPark, TileColorTransform, SolarClock,
             MapStyle, MapStyleResolver, DashNotice)
Navigation/  routing + search + active-nav loop + on-route geometry (ActiveNavigator, ActiveNavLoop,
             RoutingService, LocalSearchService, NavigationStore, PolylineMath, GPXParser, SavedRoutesStore,
             RecentDestinationsStore, RouteStartPlanner, SharedDeepLink + SharedDestinationResolver (share-extension handoff),
             VoicePhrase + VoicePromptScheduler — spoken-prompt phrasing/tiers for VoiceNavigator)
  Models/    Destination, Favorite, NavSettings, DashNavSettings, ManeuverIcon, RoundaboutInstructionParser, SavedRoute, MapStyleSettings,
             PlannedRoute, Waypoint, DrivingSide, ManeuverGeometry, ManeuverKeywords
RideAlerts/  keyless ride enrichment — WeatherAlertService (Open-Meteo, whole-route look-ahead),
             SpeedLimitService + MaxspeedParser (OSM maxspeed → posted-limit sign), SpeedCameraService (OSM/Overpass cameras +
             average-speed sections), SpeedCameraAnnouncer (spoken camera alerts), RouteProjection
RideStats/   GPS-only trip computer — RideStats (accumulator), RideStatsFormatting, RideStatsService (live session, last ride
             persisted), GPXExporter. Phone-side only
LiveActivity/        LiveActivityController + RideActivityAttributes (Lock Screen / Dynamic Island ride card)
TripperDashShare/    Share Extension target ("Share to TripperDash++" from Google / Apple Maps)
TripperDashWidgets/  Widget extension target rendering the Live Activity
TripperDashPP-Info.plist, TripperDashPP.entitlements (Hotspot Configuration), PrivacyInfo.xcprivacy
TripperDashPPTests/   Swift Testing unit tests (weather-along-route, ride stats + formatting + persistence, next-waypoint label,
             ETA TLV, voice phrase/scheduler, speed-camera announcer, route projection, saved bikes, recent destinations)
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

None beyond Xcode 26 + a paid Apple Developer Program membership (the Hotspot Configuration entitlement for the in-app Wi-Fi auto-join can't be signed by a free Personal Team). The map uses the
OSM Carto raster basemap (one keyless tile source; the dark palette is a
runtime recolour of the same tile, no second download; no third-party
SDK, no API token, no Secrets file); routing and search use Apple MapKit,
which is built into iOS. Just open the project and Run on a real device.
