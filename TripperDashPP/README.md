# TripperDashPP/

iOS app source (Swift 6 toolchain in Swift 5 language mode, SwiftUI, iOS 18.6+).

## Layout

```
App/         @main + AppStatus (shared observable state) + LocationService + VoiceNavigator (offline AVSpeechSynthesizer) + RideIntents (Shortcuts / Siri) + DemoDashModel
UI/          SwiftUI views (RootView, MapPickerView, StreamingView, InteractiveMapView, RideStatsPanel, RideHistoryView,
             DashPreviewPanel, AddBikeSheet, PermissionsView)
  Navigation/  destination search / route preview / favorite-editor / saved-routes sheets, NavigationHUD, FreeRideHUD,
             PlanningMapView, WaypointListView, EditRouteSheet (mid-ride stop editing), RoutePreferencesView, QuickAccessTiles,
             RouteProgressMap, PrerenderProgressView
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
             persisted), RideHistoryStore (last 30 days of rides), GPXExporter. Phone-side only
LiveActivity/        LiveActivityController + RideActivityAttributes (Lock Screen / Dynamic Island ride card)
TripperDashShare/    Share Extension target ("Share to TripperDash++" from Google / Apple Maps)
TripperDashWidgets/  Widget extension target: the Live Activity UI + the Quick Ride home-screen widget (Home / Work / Free Ride / Fuel)
Assets.xcassets, TripperDashPP-Info.plist, TripperDashPP.entitlements (Hotspot Configuration + Access Wi-Fi Information), PrivacyInfo.xcprivacy
TripperDashPPTests/   Swift Testing unit tests (weather-along-route, ride stats + formatting + persistence + history, next-waypoint label,
             ETA TLV, voice phrase/scheduler, speed-camera announcer + speed-limit warner, sunset pill, route projection, saved bikes,
             recent destinations, save-route-from-planner, link-error mapping, reconnect budget, Shortcuts start/redirect policy,
             turn-distance text, MapKit leg-tail probe)
```

Background keep-alive (background CoreLocation updates) and the
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
