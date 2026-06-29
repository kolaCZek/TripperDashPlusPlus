# TripperDashPP/

iOS app source (Swift 6 / SwiftUI, iOS 18+).

## Layout

```
App/         @main + AppStatus (shared observable state) + LocationService + SilentAudioKeeper
UI/          SwiftUI views (RootView, MapPickerView, MapPreviewView, StreamingView, InteractiveMapView)
  Navigation/  destination search / route preview / favorite-editor sheets, NavigationHUD, QuickAccessTiles, RouteProgressMap
Tripper/     K1G control plane — BikeLink, DashSocket (BSD UDP), K1GPacket, RsaHandshake, HeartbeatLoop,
             DeviceTelemetry (phone status), CallStateObserver, MessageNotification (OEM call/message cards)
Stream/      VideoToolbox H.264 encoder + RTP packetizer — FrameSource, H264Encoder, RtpStreamer, RtpPacketizer
Map/         OSM raster tile pipeline + BG-safe CGContext frame source
             (MapViewSource, OSMTileFetcher, RouteTileCache, TileDiskCache, WebMercator, SnapshotterPark, TileColorTransform, SolarClock)
Navigation/  routing + search + active-nav loop + on-route geometry (ActiveNavigator, ActiveNavLoop,
             RoutingService, LocalSearchService, NavigationStore, PolylineMath, GPXParser, SavedRoutesStore, ManeuverLog)
  Models/    Destination, Favorite, NavSettings, DashNavSettings, ManeuverIcon, RoundaboutInstructionParser, SavedRoute, MapStyleSettings
RideAlerts/  keyless ride enrichment — WeatherAlertService (Open-Meteo), SpeedCameraService (OSM/Overpass)
Info.plist
```

Background keep-alive (CoreLocation Always + silent audio + AVKit PiP anchor) and the
H.264 session auto-rebuild live in `App/` (`AppStatus`, `SilentAudioKeeper`) and
`Stream/H264Encoder.swift` respectively — there is no separate `Background/` group.

## Build prerequisites

None beyond Xcode 26 + a free Apple Developer account. The map uses the
OSM Carto raster basemap (one keyless tile source; the dark palette is a
runtime recolour of the same tile, no second download; no third-party
SDK, no API token, no Secrets file); routing and search use Apple MapKit,
which is built into iOS. Just open the project and Run on a real device.
