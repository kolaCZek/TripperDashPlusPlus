# TripperDash++

> Stream live, full-color turn-by-turn navigation from your iPhone to the **Royal Enfield Tripper Dash** TFT (Himalayan 450 / Guerrilla 450) — even with your phone's screen off.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Platform: iOS 18+](https://img.shields.io/badge/platform-iOS%2018%2B-blue.svg)]()
[![Bike: Royal Enfield](https://img.shields.io/badge/bike-Royal%20Enfield-red.svg)]()
[![fake_dash CI](https://github.com/kolaCZek/TripperDashPlusPlus/actions/workflows/fake_dash.yml/badge.svg)](https://github.com/kolaCZek/TripperDashPlusPlus/actions/workflows/fake_dash.yml)

---

## What is this?

The factory **Royal Enfield Tripper Dash** — the round TFT fitted to the **Himalayan 450**, **Guerrilla 450**, and **Bear 650** — runs a full color, map-capable display. But the stock Royal Enfield app only pushes **~4 fps** of choppy map-via-RTP to it, and the moment you lock your phone the stream dies.

This project replaces that pipeline with a proper one. We render a real turn-by-turn navigation map on the iPhone, encode it as H.264 baseline @ **6 fps / 526×300** and stream it over the bike's Wi-Fi to the dash as RTP. Map tiles and route calculation flow over cellular in parallel, so the dash gets a full-color map with the route, a burned-in maneuver arrow, and a heading-up rider chevron — without the bike ever touching the internet.

**What it does today:** open app → search a destination (or pick a favorite, or import a GPX) → preview alternative routes → start nav → put the phone in your pocket → ride. The dash shows the moving map, the route polyline, the next-maneuver glyph, distance/ETA, a whole-route progress overview, plus live phone status, mirrored incoming call/message cards, a weather pill, and speed-camera marks. Native turn-by-turn (TLV maneuver stream + burned-in glyph) is implemented and **validated on a Guerrilla 450 (June 2026).** On the phone itself, a live trip panel tracks the ride (distance, moving time, average/max speed, elevation gain).

> Not to be confused with the smaller **Tripper Navigation Pod** on Meteor 350 / Classic 350 / Hunter 350 / Shotgun 650 / Super Meteor 650 — that one's a tiny arrow-only display with a different protocol. This project targets the *big*, map-capable Tripper Dash.

## Why?

Because the Tripper Dash has a hardware H.264 decoder doing 526×300, and Royal Enfield ships it 4 fps of arrow icons over an unencrypted Wi-Fi link. The hardware deserves better.

Companion proof-of-concept (Python, dash-side protocol reverse engineering): **[kolaCZek/better-dash](https://github.com/kolaCZek/better-dash)** — the byte-level source of truth for the K1G protocol.

## Highlights

- **Streams to the dash with the screen off.** A real turn-by-turn map keeps flowing to the TFT with the phone locked in a tank bag or jacket pocket — pre-rendered OSM tiles + CPU CGContext composition, kept awake by CoreLocation + a silent audio loop + an AVKit PiP anchor.
- **6 fps / 526×300 H.264** vs. the stock app's ~4 fps of arrow icons — double the bits per frame, so road labels stay readable after encoding. Streamed as RTP over the bike's Wi-Fi; the bike never touches the internet.
- **Native turn-by-turn**, validated on a Guerrilla 450: maneuver-TLV stream plus a burned-in next-turn glyph drawn from a [field-verified catalog of every dash glyph](docs/maneuver-glyphs/) (`0x00–0x59`), heading-up rider chevron, and route polyline.
- **Light / Dark / Auto map.** One OSM Carto basemap, two palettes; dark is a CPU recolour of the *same* tile (water stays blue, not orange), so both share one cache. Auto follows sunrise/sunset from your GPS fix.
- **Saved routes from GPX.** Import a `.gpx`, preview it, prune/reorder points, then navigate it through the same engine — reroute, ETA, and dash glyphs all apply.
- **Mirrors OEM ride cards.** Incoming call and message cards and live phone status (battery, charging, GPS, signal) are mirrored onto the dash, just like the factory app.
- **Ride-aware alerts.** A conservative, keyless weather pill (rain/ice/storms/gusts/fog via Open-Meteo) that samples the whole route ahead and tells you how far the next hazard sits (e.g. *Rain 15 km*), plus a best-effort speed-camera overlay (OpenStreetMap/Overpass) burned onto the map.
- **GPS trip computer.** A ride summary on the phone — distance, moving time, average and max speed, and approximate elevation gain — folded from the same GPS stream the map already uses (no extra sensor or battery draw). It shows back on the map after you arrive and accumulates across a multi-leg day, zeroing when the session ends (you disconnect, the bike powers off, or the app is killed). Phone-side only; it's never sent to the dash.
- **No keys, no SDK, no paid account.** OSM tiles + Apple MapKit only, zero third-party SPM dependencies, free Apple Developer account is enough.

Field-tested on a **Royal Enfield Guerrilla 450**. See [`docs/maneuver-glyphs/`](docs/maneuver-glyphs/) for the full glyph catalog.

## Tech stack

- **Swift 6 / SwiftUI**, **iOS 18+**, **Xcode 26**
- **OSM Carto raster basemap** for the map (keyless; no SDK, no API key), with a **Light / Dark / Auto** appearance setting — Light is the raw OSM raster; Dark is the *same* tile recoloured at composite time (CPU invert + 180° hue-rotate, so water stays blue not orange); Auto follows sunrise/sunset from GPS — plus **Apple MapKit** for routing and place search (`MKDirections`, `MKLocalSearch`)
- Apple frameworks: `Network`, `VideoToolbox`, `CryptoKit`, `CoreLocation`, `MapKit`, `AVFoundation`, `AVKit`, `CallKit`, `UIKit`
- Keyless ride-data: Open-Meteo (weather pill) + OpenStreetMap Overpass (speed cameras) — no account, fetched over cellular
- **Zero** third-party SPM dependencies
- Python 3.12+ for the `fake_dash` test harness (decode RTP, simulate the dash on a laptop)

## Architecture (one paragraph)

The iPhone joins two networks at once: the Tripper Dash's Wi-Fi AP (no internet, used only for UDP to `192.168.1.1`) and your cellular data (used for OSM map tiles and MapKit routing). During foreground the app pre-renders the OSM tiles it will need along the route and JPEG-caches them in memory; in the background it does CPU-only CGContext composition (crop the tile around the current GPS fix, rotate heading-up, draw the route polyline, draw the maneuver glyph and rider chevron, plus the weather pill and speed-camera marks) into a 526×300 pixel buffer at 6 fps, encodes it via VideoToolbox H.264 baseline @ ~450 kbps, packetizes into RTP FU-A units, and sends UDP to `192.168.1.1:5000`. The K1G control plane (RSA handshake + 1 Hz heartbeats + live phone status + incoming-call / message cards + nav kicks + button events) runs over UDP: the phone **sends to :2000** and **binds locally to :2002** for the dash's replies, over a single BSD POSIX socket. Background execution is kept alive via `CoreLocation` Always + a silent audio loop + an AVKit PiP anchor, so the stream survives the lock screen with the phone in a tank bag or jacket pocket.

## Building

```sh
git clone https://github.com/kolaCZek/TripperDashPlusPlus.git
cd TripperDashPlusPlus
open TripperDashPP/TripperDashPP.xcodeproj
# 1. Sign in with your Apple ID (Xcode Settings → Accounts)
# 2. Set Bundle ID to something unique (e.g. eu.YOURNAME.TripperDashPP)
# 3. Build & Run on a real device (Simulator can't do Wi-Fi to the bike)
```

The free Apple Developer account works fine — the app uses no paid-only capabilities. You'll need to re-install every 7 days (Xcode → Run takes ~30 s).

**No API keys, no service accounts, no SDK token plumbing.** OSM tiles are fetched anonymously and MapKit is built into iOS. Set the bike's SSID and IP in the in-app diagnostics screen (they're persisted) — the defaults match a stock dash AP.

## Testing without the bike

`tools/fake_dash/` is a Dockerized Python emulator of the dash. It speaks the K1G control plane on UDP/2000 and accepts the RTP H.264 stream on UDP/5000, so you can iterate on a laptop instead of parking the phone in front of the motorcycle.

```sh
make fake-dash-up      # start the emulator
make fake-dash-logs    # watch the handshake / heartbeats
make fake-dash-test    # run the pytest suite
make fake-dash-down    # stop
```

⚠️ **fake_dash is a plumbing harness, not a protocol authority.** It is deliberately permissive and will accept packets the real dash rejects. Byte-level protocol correctness is verified against [better-dash](https://github.com/kolaCZek/better-dash). A green fake_dash run does **not** mean the bike will accept your changes.

## Compatibility

The Tripper Dash (big round map-capable TFT) ships on:

- ✅ **Royal Enfield Guerrilla 450** (2024+) — primary dev bike (@kolaCZek), field-validated
- ❓ **Royal Enfield Himalayan 450** (2023+) — same dash hardware in theory, untested
- ❓ **Royal Enfield Bear 650** (2024+) — same Tripper Dash hardware, untested

**Not compatible:** the small arrow-only Tripper Navigation Pod on Meteor 350 / Classic 350 / Hunter 350 / Shotgun 650 / Super Meteor 650. Different display, different protocol — this app won't talk to it.

## Legal / safety

- This project **reverse engineers an unencrypted-by-design Wi-Fi protocol** between the official RE phone app and the Tripper Dash for **interoperability** — protected under [Article 6 of EU Directive 2009/24/EC](https://eur-lex.europa.eu/legal-content/EN/TXT/?uri=CELEX:32009L0024). Not affiliated with, endorsed by, or sanctioned by Royal Enfield or Eicher Motors.
- **Don't read your phone while riding.** The whole point of this app is so you don't have to — but it doesn't replace common sense. Plan your route at a stop. Glance at the dash, not the phone.
- **Use at your own risk.** The MIT license applies: no warranty, no liability. If your bike catches fire because of bad RTP packets, that's on you (and also extremely unlikely).

## Contributing

Contributions, bug reports, and tested-bike confirmations are very welcome. See [`CONTRIBUTING.md`](CONTRIBUTING.md) for the workflow.

## Support the project

If this saves your sanity on a long ride, you can throw a coffee my way:

- ☕ [GitHub Sponsors](https://github.com/sponsors/kolaCZek)
- 🇨🇿 Czech bank account / Revolut — see Sponsors page

This is and will remain MIT-licensed. Sponsorship buys me time to fix bugs and test on more models, not exclusive features.

## License

[MIT](LICENSE) © 2026 Martin Kolací

---

*"The best dash mod is the one you can revert with one tap of the lock button." — me, probably*
