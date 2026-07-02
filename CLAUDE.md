# CLAUDE.md — context for AI coding assistants

> This file is read by AI coding assistants (Claude Code, Cursor, Hermes, Copilot CLI, etc.) when opening this repo. Keep it short and load-bearing. Humans should read [README.md](README.md) and [CONTRIBUTING.md](CONTRIBUTING.md) instead.

## Project in one paragraph

**TripperDash++** is a native iOS app (Swift 6, iOS 18+) that streams a live turn-by-turn navigation map to the Royal Enfield Tripper TFT dash display over Wi-Fi. Map tiles (OpenStreetMap raster) and routing/search (Apple MapKit) flow over cellular; the rendered map is H.264-encoded and pushed to the dash over the bike's Wi-Fi AP. The phone can be locked / in a pocket during the ride. It is the Swift / iOS port of the proven Python proof-of-concept at [`kolaCZek/better-dash`](https://github.com/kolaCZek/better-dash), which contains the full reverse-engineered K1G protocol and the RTP packetizer — always treat that Python code as the byte-level source of truth.

## Authoritative references

When the user asks about the Tripper protocol, the RTP wire format, or any byte-level detail, the truth is in **`kolaCZek/better-dash`** (Python, public). Specifically:

- `tripper_app_like_nav.py` — full session orchestration: handshake → projection on → render loop → projection off
- `dash_ui/bike_link.py` — K1G control plane (UDP): RSA handshake, heartbeats, TLV packets, button event listener
- `dash_ui/rtp.py` — RTP FU-A packetizer for H.264 NAL units (UDP 5000)
- `dash_ui/stream.py` — `DashUIStream` wiring everything together
- `dash_ui/encoder.py` — H.264 encoder wrapper (the Python version uses x264 / PyAV; the Swift port uses VideoToolbox)

The detailed phased build plan lives **outside this repo** in the author's private notes — don't try to fetch it from GitHub. When unsure about scope, ask the user before guessing.

## Tech stack & versions (locked)

- **Language**: Swift 6 (strict concurrency on), SwiftUI for UI
- **Target**: iOS 18.0 minimum, iPhone 13 and newer (HW H.264 encoder + dual-band Wi-Fi required). iOS 18 covers ~92% of devices in service as of mid-2026; Swift 6 strict concurrency works without backwards-compat shims.
- **Toolchain**: **Xcode 26.5+, macOS 15+** (lower may build but is untested; CI pins to the latest stable Xcode on macOS 15 runners)
- **Bundle ID**: `eu.kolaczek.TripperDashPP`
- **Distribution**: Free Apple Developer account (Personal Team, 7-day cert renewal via Xcode). No paid-only entitlements are used in MVP.
- **Maps**: **OSM Carto raster basemap** (keyless XYZ, `tile.openstreetmap.org/{z}/{x}/{y}.png` — note: no `{s}` subdomain shard, so `subdomains` is empty and URL-building must not substitute `{s}`), fetched over cellular and cached on disk. One basemap, two palettes via a user **Light / Dark / Auto** setting: **Light** is the raw OSM raster; **Dark** is the *same* tile recoloured at composite time — a CPU-side `invert ∘ hue-rotate(180°)` colour matrix (`TileColorTransform.swift`, vImage/Accelerate so it survives the screen locking), which keeps OSM's semantics (water blue, parks green) instead of the orange/magenta a plain invert gives. Attribution is `© OpenStreetMap contributors`. Auto follows local sunrise/sunset from the GPS fix (see `SolarClock` / `MapStyleResolver`). Because dark is a recolour of the light raster, both palettes share **one** disk cache namespace (`RouteTiles/osm/…`) — one fetch, one cached PNG serves both (half the traffic, half the disk; the raw tile is kept so the filter can be retuned without re-fetching). The provider is a one-line table swap in `MapStyle.swift`; **no third-party map SDK, no API key.** Routing and place search use Apple MapKit (`MKDirections`, `MKLocalSearch`, `MKLocalSearchCompleter`).
- **Apple frameworks in use**: `Network`, `VideoToolbox`, `CryptoKit`, `Security`, `CoreLocation`, `MapKit`, `AVFoundation`, `AVKit` (PiP keep-alive), `BackgroundTasks`, `UIKit` (CGContext frame composition + battery state), `CallKit` (incoming-call mirror), `SwiftUI`
- **Keyless ride-data services (cellular, no account)**: Open-Meteo (weather pill — samples the route ahead every 10 km out to 100 km in one multi-point request, reports the nearest hazard's along-route distance) and OpenStreetMap Overpass (speed-camera overlay) — both keyless, consistent with the free-account stance.

## Architecture summary (one screen)

```
iPhone ──(Cellular)──► tile.openstreetmap.org   OSM Carto raster tiles (one cache; dark = runtime recolour)
iPhone ──(Cellular)──► Apple MapKit             MKDirections routes + MKLocalSearch
iPhone ──(Wi-Fi)─────► 192.168.1.1:2000         K1G control TX (RSA, heartbeat, nav kicks)
iPhone ◄─(Wi-Fi)────── 192.168.1.1 → :2002      K1G control RX (auth, acks, button events)
iPhone ──(Wi-Fi)─────► 192.168.1.1:5000         RTP H.264 video stream (6 fps, 526×300)
```

**Two simultaneous networks** are essential: cellular for internet (tiles, routing, search), Wi-Fi for the Tripper AP which has no internet. The UDP socket to the dash is pinned to the Wi-Fi interface; `URLSession` tile/route fetches go via cellular.

**UDP transport (see `references/network-transport.md` in the `royal-enfield-tripper-dash` skill before touching this):** the dash **listens on 2000** and **replies to 2002**, regardless of the phone's source port. The phone must therefore send to `:2000` AND bind its local socket to `:2002`, or the dash's replies hit an unbound port and the firmware state machine stalls (`rx=0`). `DashSocket` uses a single BSD POSIX socket (not `NWConnection` — Apple's connected-UDP semantics drop datagrams arriving from a different source port than we sent to).

**Background execution**: the app is designed to run with the screen locked / phone in a pocket. The map frame source pre-renders OSM tiles while the app is foregrounded (GPU awake), then in the background does **CPU-only CGContext composition** (crop tile around current GPS fix, rotate heading-up, draw polyline + heading chevron) — CGContext is background-safe where MapKit's Metal renderer and `MKMapSnapshotter` are not. The render loop is kept alive via `CoreLocation` Always updates + a silent audio loop + an AVKit PiP anchor as belt-and-braces wakelocks.

## fake_dash test harness

`tools/fake_dash/` is a Dockerized Python emulator of the Tripper TFT. It speaks the K1G control plane on UDP/2000 (RSA handshake, ACKs, joystick events) and accepts RTP H.264 on UDP/5000 (FU-A reassembly, Annex-B dump). Run it on any laptop instead of going outside to the bike for every iteration.

**Daily use:**

```sh
make fake-dash-up         # docker compose up -d  (listens on :2000, :5000)
make fake-dash-logs       # tail container output
make fake-dash-btn-click  # send a joystick CLICK to the iPhone
make fake-dash-down       # stop
```

**Captured H.264 streams** land in `tools/fake_dash/captures/dash_capture_<ts>.h264` (gitignored). Open them with `ffplay`, `vlc`, or `mpv` to verify the encoder output. The RSA keypair the harness uses is persisted in `tools/fake_dash/keys/bike_rsa.pem` so the dash identity stays stable across restarts.

**The harness is the plumbing regression net for everything in `TripperDashPP/Tripper/` and `TripperDashPP/Stream/`.** It is intentionally permissive — it will accept packets the real dash rejects. **It is NOT authority on the wire format.** Byte-level protocol correctness is verified against `better-dash` (see the `scripts/verify_initial_burst.py` workflow). When adding Swift code that touches the wire format, add a matching Python test that drives `fake_dash`, but also byte-compare against the better-dash reference.

**CI runs the Python tests + a Docker image build on every PR.** See `.github/workflows/fake_dash.yml`.

## K1G control plane (`TripperDashPP/Tripper/`)

Ports the wire format to Swift. The files mirror `tools/fake_dash/fake_dash/`:

| Swift | Python equivalent | Role |
|-------|-------------------|------|
| `K1GConstants.swift` | `protocol.py` (constants) | magic, ports (txPort 2000 / rxPort 2002), segment types |
| `K1GPacket.swift` | `protocol.py` (encode/decode) | TLV envelope, RollingSeq, initial-burst + status builders |
| `RsaHandshake.swift` | `rsa_handshake.py` (inverse) | PKCS1v1.5 encrypt session key via SecKey |
| `DashSocket.swift` | (transport — n/a in Python) | single BSD POSIX UDP socket, sends to :2000, bound to :2002 |
| `BikeLink.swift` | `server.py` (mirror direction) | state machine: idle→connecting→handshaking→connected, initial burst, nav kicks |
| `HeartbeatLoop.swift` | (n/a — bike is passive) | 1 Hz `0044` + `0030` status pair once connected |
| `DeviceTelemetry.swift` | (status payload source) | live phone status for heartbeat (battery/charge/GPS/signal) — see `06 04`/`06 0F`/`06 03`/`06 01`/`06 08` TLVs |
| `CallStateObserver.swift` | (n/a — phone-side only) | CallKit `CXCallObserver` → OEM incoming-call card on the dash |
| `MessageNotification.swift` | (status payload source) | mirror OEM incoming-message cards to the TFT |

**Drift policy:** when `tools/fake_dash/fake_dash/protocol.py` changes its wire format, the matching `K1G*.swift` constant **must** change in the same commit, and the integration test should pin the new shape. **But the integration test is not the protocol authority** — `better-dash` is. The real dash validates `outer_len`, `seg_count` (hardcoded for status templates, `count+1` for Q3C envelopes), the outbound type-byte family (`{0x02, 0x05, 0x06, 0x08}` — never `0x07`, which is inbound-only), and the rolling sequence byte. fake_dash checks none of these; both can pass and the bike still drops the packet. See the `royal-enfield-tripper-dash` skill (`references/k1g-wire-protocol.md`) before editing any `Tripper/` file.

## Repo conventions

- **All code, file paths, identifiers, code comments are in English.** Always. No exceptions.
- **All user-facing strings** are localized via `.strings` files. Default locale is English; Czech is the second locale (author's first language).
- **README, CONTRIBUTING, issue templates, PR descriptions** are in English.
- **Internal author notes / Czech-specific docs** stay out of the repo.
- **Commit messages**: imperative present (`Add K1G handshake`, not `Added` / `Adds`). Reference issue numbers when relevant. Conventional Commits are nice-to-have, not enforced.
- **Branch-first workflow.** `main` is a working, on-bike-validated build and must stay always-shippable. Do **not** develop features or non-trivial fixes directly on `main` — cut a dedicated branch (`feat/…`, `fix/…`, `chore/…`, `docs/…`), do the work and field-test there, and only merge back into `main` once it's debugged. Prefer a PR (the `fake_dash` CI runs on it); `--no-ff` or `--squash` the merge so a feature is one revertable unit. Trivial one-liners may still go straight on `main`. Don't force-push `main`.

## Folder layout

```
TripperDashPP/TripperDashPP.xcodeproj/   # Xcode project (committed; xcuserdata gitignored)
TripperDashPP/                           # App source
├── App/          # @main, AppStatus (shared observable state), LocationService, SilentAudioKeeper
├── UI/           # SwiftUI views (RootView, MapPickerView, MapPreviewView, StreamingView, InteractiveMapView)
│   └── Navigation/   # search / preview / favorites / saved-routes sheets, NavigationHUD, RouteProgressMap, QuickAccessTiles, PrerenderProgressView
├── Tripper/      # K1G control plane (BikeLink, DashSocket, K1GPacket, RsaHandshake, HeartbeatLoop, K1GConstants),
│   #              plus DeviceTelemetry (phone status), CallStateObserver, MessageNotification (OEM call/message mirror)
├── Stream/       # VideoToolbox H.264 encoder + RTP packetizer (FrameSource, H264Encoder, RtpStreamer, RtpPacketizer)
├── Map/          # OSM raster tile pipeline + BG-safe CGContext frame source
│   #              (MapViewSource, OSMTileFetcher, RouteTileCache, TileDiskCache, WebMercator, SnapshotterPark, TileColorTransform, SolarClock)
├── RideAlerts/   # keyless ride enrichment — WeatherAlertService (Open-Meteo), SpeedCameraService (OSM/Overpass)
└── Navigation/   # routing, search, active-nav loop, on-route geometry, GPX import, saved routes, ManeuverLog
    └── Models/   # Destination, Favorite, NavSettings, DashNavSettings, ManeuverIcon, RoundaboutInstructionParser, SavedRoute, MapStyleSettings
tools/
└── fake_dash/    # Python harness — simulates the Tripper for development on a laptop
docs/             # maneuver-glyph catalog + field-test reference material
```

## Secrets

The app needs **no secrets and no API keys**. OSM raster tiles are fetched anonymously with a project User-Agent string; routing and search use the built-in MapKit framework. There is no `Secrets.xcconfig`, no `~/.netrc`, no SDK download token.

If you point the tile fetcher at a self-hosted endpoint that requires auth, keep that config out of git.

GitHub token, iCloud password, Home Assistant token, etc. — **never put these in this repo**. They live in the author's Hermes secrets store.

## Coding guidelines for AI assistants

1. **Read the corresponding Python first.** Before writing Swift for any K1G or RTP feature, fetch the matching `.py` from `kolaCZek/better-dash` via raw.githubusercontent.com and treat it as the spec. The wire format is byte-exact; guessing leads to days lost.

2. **Verify wire bytes against better-dash, not against fake_dash.** The `tools/fake_dash/` emulator is a permissive plumbing test — it accepts packets the real dash rejects. For any protocol change, byte-compare against the better-dash reference (`scripts/verify_initial_burst.py` is the pattern). The build server has no Swift compiler / iOS SDK, so port the Swift builder to Python and assert hex equality.

3. **No paid-only capabilities.** If you find yourself reaching for `NEHotspotConfiguration`, Apple Watch targets, push notifications, App Groups across devices, associated domains, or TestFlight — stop. We're on a free Developer account. Use the manual Wi-Fi switch flow + `NWPathMonitor` monitoring instead.

4. **No third-party map SDK.** Mapbox and Google Maps iOS SDKs are both pure-Metal renderers that fail instantly in the background (`IOGPUMetalError` on the lock screen) — the whole "phone in pocket" use case rules them out. We render OSM Carto raster tiles ourselves via CPU CGContext composition, and the dark palette is likewise a CPU (vImage) recolour of that composite — all background-safe, no GPU. Don't reintroduce a map SDK, and don't move the dark recolour to CoreImage/Metal (it dies on the lock screen).

5. **No internet on the Wi-Fi interface.** The Tripper AP has no internet. Always verify that `URLSession` tile/route traffic goes via cellular. If a tile request goes via Wi-Fi it will time out, the user gets blank tiles, and they'll think the app is broken.

6. **Background execution: location + audio + PiP.** Not one alone. Location gets culled on stationary periods (red lights); audio alone is fragile; the AVKit PiP anchor backstops both. Together they survive the lock screen.

7. **Frame rate is 6 fps, not 12 or 30.** For static map/nav content, 6 fps at 450 kbps spends double the bits per frame vs 12 fps — noticeably sharper road labels after H.264. The dash decoder blinks above ~12 fps anyway. Don't bump it.

8. **Resolution is exactly 526×300.** This is the dash's native panel resolution. Other resolutions get scaled internally and blur the text.

9. **H.264 baseline profile only.** No B-frames (`AllowFrameReordering=false`), no High profile. The Tripper decoder breaks on both.

10. **When you're unsure, ask the user.** This is a hobby project, not a sprint; clarification is cheap, refactoring three days of misdirected work is not.

## Build & run

```sh
git clone https://github.com/kolaCZek/TripperDashPlusPlus.git
cd TripperDashPlusPlus
open TripperDashPP/TripperDashPP.xcodeproj
# 1. Signing & Capabilities → Team = your Apple ID, Bundle ID = unique (e.g. eu.YOURNAME.TripperDashPP)
# 2. Plug in iPhone, hit Run
```

No API keys, no service accounts, no SDK token plumbing — OSM tiles and MapKit need none.

**Simulator is mostly useless** for this app — no real Wi-Fi to the bike, no HW H.264 encoder behavior, no real CoreLocation behavior. Most testing happens on a real iPhone against either the fake-dash harness (`tools/fake_dash/`, runs on a laptop) or against the actual Tripper.

## Tests

- **fake_dash Python suite** (`tools/fake_dash/tests/`): K1G packet builders, RTP FU-A reassembly, RSA handshake, ETA pipeline, rolling-window tile prefetch, reroute lifecycle, maneuver catalog, roundabout parser. Run `make fake-dash-test` or `cd tools/fake_dash && pytest -v`.
- **Byte-verification scripts** (`scripts/` in the `royal-enfield-tripper-dash` skill): assert the Swift wire builders match `better-dash` byte-for-byte.
- **Manual on-bike tests**: the real regression net for anything touching background rendering, the projection lifecycle, or maneuver glyphs. fake_dash is blind to sequencing and rendering bugs.

When asked to add tests, **also add a fake-dash test** that exercises the same code path end-to-end — unit tests on Swift logic alone don't catch protocol mismatches.

## What to do when stuck

- **K1G byte-level question** → re-read the Python in `better-dash`, then capture a real packet with the harness and diff. Load the `royal-enfield-tripper-dash` skill's `references/k1g-wire-protocol.md`.
- **Background / lock-screen rendering question** → the answer is almost certainly already in the skill's "Sustained background nav" section. `MKMapSnapshotter`, `MKMapView`, Metal, and `CADisplayLink` are all known BG dead-ends — don't re-derive them. The working path is `Task + Task.sleep + CGContext on pre-rendered raster`.
- **iOS API question** → Apple's WWDC sessions on Network framework, VideoToolbox, MapKit, and CoreLocation Background.
- **Anything else** → ask the user via an issue or PR comment.

## Don't

- Don't commit `*.ipa`, `*.xcarchive`, captured `.h264` files, or xcuserdata.
- Don't add a new dependency (SPM package) without flagging it in a PR description with justification. Each dep is a 7-day-cert-renewal liability and a future migration burden. The app currently has **zero** third-party SPM dependencies — keep it that way unless there's a strong reason.
- Don't reintroduce a third-party map SDK (Mapbox / Google) — see guideline 4.
- Don't replace the manual Wi-Fi switch UX with auto-join "as an improvement". That requires a paid Developer entitlement we explicitly opted out of.
- Don't propose `MKMapSnapshotter` / `MKMapView` / Metal as a background render path. They're documented dead-ends.
