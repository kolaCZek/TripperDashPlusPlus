# CLAUDE.md — context for AI coding assistants

> This file is read by AI coding assistants (Claude Code, Cursor, Hermes, Copilot CLI, etc.) when opening this repo. Keep it short and load-bearing. Humans should read [README.md](README.md) and [CONTRIBUTING.md](CONTRIBUTING.md) instead.

## Project in one paragraph

**TripperDash++** is a native iOS app (Swift 6, iOS 18+) that streams a live online Mapbox map to the Royal Enfield Tripper TFT dash display over Wi-Fi, while map tiles and routing API requests flow over cellular. The phone can be locked / in pocket during the ride. It is the Swift / iOS port of the proven Python proof-of-concept at [`kolaCZek/better-dash`](https://github.com/kolaCZek/better-dash), which contains the full reverse-engineered K1G protocol and the RTP packetizer — always treat that Python code as the byte-level source of truth.

## Authoritative references

When the user asks about the Tripper protocol, the RTP wire format, or any byte-level detail, the truth is in **`kolaCZek/better-dash`** (Python, public). Specifically:

- `tripper_app_like_nav.py` — full session orchestration: handshake → projection on → render loop → projection off
- `dash_ui/bike_link.py` — K1G control plane (UDP 2002): RSA handshake, heartbeats, TLV packets, button event listener
- `dash_ui/rtp.py` — RTP FU-A packetizer for H.264 NAL units (UDP 5000)
- `dash_ui/stream.py` — `DashUIStream` wiring everything together
- `dash_ui/encoder.py` — H.264 encoder wrapper (the Python version uses x264 / PyAV; the Swift port uses VideoToolbox)

The detailed phased build plan lives **outside this repo** in the author's private notes — don't try to fetch it from GitHub. When unsure about scope, ask the user before guessing.

## Tech stack & versions (locked)

- **Language**: Swift 6 (strict concurrency on), SwiftUI for UI
- **Target**: iOS 18.0 minimum, iPhone 13 and newer (HW H.264 encoder + dual-band Wi-Fi required). iOS 18 covers ~92% of devices in service as of mid-2026; Swift 6 strict concurrency works without backwards-compat shims.
- **Toolchain**: **Xcode 26.5+, macOS 15+** (lower may build but is untested; CI pins to the latest stable Xcode on macOS 15 runners)
- **Bundle ID**: `eu.kolaczek.tripperdashpp`
- **Distribution**: Free Apple Developer account (Personal Team, 7-day cert renewal via Xcode). No paid-only entitlements are used in MVP.
- **Maps**: Mapbox Maps SDK iOS v11.x (off-screen rendering is a first-class use case for them)
- **Apple frameworks in use**: `Network`, `VideoToolbox`, `CryptoKit`, `Security`, `CoreLocation`, `AVFoundation`, `BackgroundTasks`, `UIKit` (for the off-screen `UIWindow`), `SwiftUI`

## Architecture summary (one screen)

```
iPhone ──(Cellular)──► api.mapbox.com           tiles + Directions API
iPhone ──(Wi-Fi)──────► 192.168.1.1:2002         K1G control (RSA, heartbeat, buttons)
iPhone ──(Wi-Fi)──────► 192.168.1.1:5000         RTP H.264 video stream (12 fps, 526×300)
```

**Two simultaneous networks** are essential: cellular for internet (tiles, routing, search), Wi-Fi for the Tripper AP which has no internet. Use `NWParameters.requiredInterfaceType = .wifi` for the UDP socket to the dash and `.cellular` (or implicit default-after-captive-portal-fail) for `URLSession` calls to Mapbox.

**Background execution** is kept alive via `CoreLocation` Always-authorized location updates (`activityType = .otherNavigation`, `kCLLocationAccuracyBest`) plus a silent audio loop as a safety net.

## fake_dash test harness (Phase 2 — MVP done)

`tools/fake_dash/` is a Dockerized Python emulator of the Tripper TFT. It speaks K1G control plane on UDP/2002 (RSA handshake, ACKs, joystick events) and accepts RTP H.264 on UDP/5000 (FU-A reassembly, Annex-B dump). Run it on any laptop instead of going outside to the bike for every iteration.

**Daily use:**

```sh
make fake-dash-up         # docker compose up -d  (listens on :2002, :5000)
make fake-dash-logs       # tail container output
make fake-dash-btn-click  # send a joystick CLICK to the iPhone
make fake-dash-down       # stop
```

**Captured H.264 streams** land in `tools/fake_dash/captures/dash_capture_<ts>.h264` (gitignored). Open them with `ffplay`, `vlc`, or `mpv` to verify the encoder output. The RSA keypair the harness uses is persisted in `tools/fake_dash/keys/bike_rsa.pem` so the dash identity stays stable across restarts.

**The harness is the regression net for everything in `TripperDashPP/Tripper/` and `TripperDashPP/Video/`.** When adding Swift code that touches the wire format, you must add a matching test that drives `fake_dash` from outside. See `tools/fake_dash/README.md` for the full CLI and `tools/fake_dash/tests/test_integration.py` for the canonical handshake exchange.

**CI runs the Python tests + a Docker image build on every PR.** See `.github/workflows/fake_dash.yml`.

## K1G control plane (Phase 3 — Swift)

`TripperDashPP/Tripper/` ports the wire format to Swift. The files are
deliberately a 1:1 mirror of `tools/fake_dash/fake_dash/`:

| Swift | Python equivalent | Role |
|-------|-------------------|------|
| `K1GConstants.swift` | `protocol.py` (constants) | magic, ports, segment types |
| `K1GPacket.swift` | `protocol.py` (encode/decode) | TLV envelope, RollingSeq, patch_seq |
| `RsaHandshake.swift` | `rsa_handshake.py` (inverse) | PKCS1v1.5 encrypt session key via SecKey |
| `DashSocket.swift` | (transport — n/a in Python) | NWConnection bound to Wi-Fi interface |
| `BikeLink.swift` | `server.py` (mirror direction) | state machine: idle→connecting→handshaking→connected |
| `HeartbeatLoop.swift` | (n/a — bike is passive) | 1Hz keep-alive once connected |

**Drift policy:** when `tools/fake_dash/fake_dash/protocol.py` changes
its wire format, the matching `K1G*.swift` constant **must** change in
the same commit, and `tests/test_integration.py` should pin the new
shape. The integration test is the contract.

**Testing flow** is documented in `docs/PHASE_3_TESTING.md` — phone tap
"Connect" against `make fake-dash-up` running on a Mac; verify in logs
that handshake completes and heartbeats flow.

## Repo conventions

- **All code, file paths, identifiers, code comments are in English.** Always. No exceptions.
- **All user-facing strings** are localized via `.strings` files. Default locale is English; Czech is the second locale (author's first language).
- **README, CONTRIBUTING, issue templates, PR descriptions** are in English.
- **Internal author notes / Czech-specific docs** stay out of the repo.
- **Commit messages**: imperative present (`Add K1G handshake`, not `Added` / `Adds`). Reference issue numbers when relevant. Conventional Commits are nice-to-have, not enforced.
- **Branch from `main`**. PR titles: `[Phase N] short description` where Phase N matches the build phase being worked on.

## Folder layout (target — most of these don't exist yet)

```
TripperDashPP.xcodeproj/        # Xcode project (committed; .xcuserstate / xcuserdata gitignored)
TripperDashPP/                  # App source
├── App/                        # @main, scene, root view
├── UI/                         # SwiftUI views
├── Tripper/                    # K1G control plane (BikeLink, packet builders, joystick)
├── Video/                      # VideoToolbox encoder + RTP packetizer
├── Map/                        # Mapbox off-screen renderer + frame capture
├── Network/                    # NWPathMonitor, dual-interface routing, WiFiMonitor
├── Nav/                        # Route state machine, GPS handling, search
├── Background/                 # Location + audio keep-alive coordinator
├── Adaptive/                   # Thermal / battery downscaler
├── Diagnostics/                # os.Logger, log export, telemetry overlay
├── Resources/                  # Assets, silence.m4a (audio keep-alive loop), .strings
└── Secrets.xcconfig            # Mapbox public token (gitignored — provide your own)
TripperDashPPTests/             # Unit tests
TripperDashPPUITests/           # UI tests
tools/
├── fake_dash/                  # Python harness — simulates the Tripper for development on Mac
└── pcap/                       # Captured handshake / RTP samples for regression tests
```

## Secrets

Two Mapbox tokens are needed during development; **neither belongs in git**:

1. **Secret download token** (`sk.…` scope `Downloads:Read`) → goes in `~/.netrc`. Required only at SDK fetch time.
   ```
   machine api.mapbox.com
     login mapbox
     password sk.YOUR_SECRET_DOWNLOAD_TOKEN
   ```
2. **Public access token** (`pk.…` URL-restricted to your bundle ID) → goes in `TripperDashPP/Secrets.xcconfig`, referenced from `Info.plist` as `MBXAccessToken`. The file is in `.gitignore`. Provide a template `Secrets.xcconfig.example` in the repo so new contributors know what to fill in.

GitHub token, iCloud password, Home Assistant token, etc. — **never put these in this repo**. They live in the author's Hermes secrets store.

## Coding guidelines for AI assistants

1. **Read the corresponding Python first.** Before writing Swift for any K1G or RTP feature, fetch the matching `.py` from `kolaCZek/better-dash` via raw.githubusercontent.com and treat it as the spec. The wire format is byte-exact; guessing leads to days lost.

2. **Test against fake-dash harness, not the real bike, until the harness passes.** The `tools/fake_dash/` Python emulator (Phase 2 deliverable) accepts our K1G handshake and decodes our RTP stream into a Mac window. Real-bike tests are expensive (need to be outside, on the bike, with the engine running) and slow to iterate on.

3. **No paid-only capabilities.** If you find yourself reaching for `NEHotspotConfiguration`, Apple Watch targets, push notifications, App Groups across devices, associated domains, or TestFlight — stop. We're on a free Developer account. Use the manual Wi-Fi switch flow + `NWPathMonitor` monitoring instead.

4. **No Google Maps SDK.** It's explicitly forbidden for this use case by their TOS section 3.2.4 (off-screen rendering for third-party display = derivative work). Mapbox only.

5. **No internet on the Wi-Fi interface.** The Tripper AP has no internet. Always verify that `URLSession` / Mapbox SDK traffic goes via cellular. If a tile request goes via Wi-Fi it will time out, the user will get blank tiles, and they'll think the app is broken.

6. **Background execution: location + audio, both.** Not one or the other. Location alone gets suspended on stationary periods (red lights); audio alone is fragile. Together they're the pattern used by Strava / Komoot / Waze.

7. **Frame rate is 12 fps, not 30.** Tripper hardware can't decode faster than that and bandwidth is a single 2.4 GHz channel shared with the dash's other duties. Don't be tempted to bump it.

8. **Resolution is exactly 526×300.** This is the dash's native panel resolution and what the H.264 decoder is configured for. Other resolutions cause garbage frames or no display at all.

9. **H.264 baseline profile only.** No B-frames, no CABAC. Tripper decoder doesn't support them.

10. **When you're unsure, ask the user.** This is a hobby project, not a sprint; clarification is cheap, refactoring three days of misdirected work is not.

## Build & run

```sh
git clone https://github.com/kolaCZek/TripperDashPlusPlus.git
cd TripperDashPlusPlus

# 1. Mapbox secret token in ~/.netrc (see Secrets above)
# 2. Copy Secrets.xcconfig.example → Secrets.xcconfig, fill in your public pk.* token
# 3. Open project
open TripperDashPP.xcodeproj
# 4. Signing & Capabilities → Team = your Apple ID, Bundle ID = unique (e.g. eu.YOURNAME.tripperdashpp)
# 5. Plug in iPhone, hit Run
```

**Simulator is mostly useless** for this app — no real Wi-Fi to the bike, no HW H.264 encoder behavior, no real CoreLocation behavior. Most testing happens on a real iPhone against either the fake-dash harness (`tools/fake_dash/`, runs on macOS) or against the actual Tripper.

## Tests

- **Unit tests** (`TripperDashPPTests/`): K1G packet builders, RTP packetizer edge cases (FU-A boundary, sequence wrap), route state machine transitions.
- **Integration tests** against fake-dash: full handshake → projection on → 10 s stream → projection off → clean disconnect.
- **Manual on-bike tests** are documented in `docs/` (TBD) as a checklist per phase.

When asked to add tests, **also add a fake-dash test** that exercises the same code path end-to-end — unit tests on Swift logic alone don't catch protocol mismatches.

## What to do when stuck

- **K1G byte-level question** → re-read the Python in `better-dash`, then capture a real packet with the harness and diff.
- **iOS API question** → Apple's WWDC sessions on Network framework, VideoToolbox, and CoreLocation Background are the best reference.
- **Mapbox question** → [docs.mapbox.com/ios/maps](https://docs.mapbox.com/ios/maps/), specifically the off-screen rendering section.
- **Anything else** → ask the user via an issue or PR comment.

## Don't

- Don't commit `Secrets.xcconfig`, `.netrc`, `*.ipa`, `*.xcarchive`, captured `.pcap` / `.h264` files (unless explicitly added under `tools/fake_dash/fixtures/` with redactions).
- Don't add a new dependency (SPM package) without flagging it in a PR description with justification. Each dep is a 7-day-cert-renewal liability and a future migration burden.
- Don't refactor across phase boundaries without asking. Each phase has a verification checkpoint; cross-cutting changes break the staged delivery.
- Don't replace the manual Wi-Fi switch UX with auto-join "as an improvement". That requires a paid Developer entitlement we explicitly opted out of.
