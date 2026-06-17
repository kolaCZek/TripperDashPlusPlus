# TripperDash++

> Stream live, full-color navigation from your iPhone to the **Royal Enfield Tripper Dash** TFT (Himalayan 450 / Guerrilla 450) — even with your phone's screen off.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Status: Planning](https://img.shields.io/badge/status-planning-orange.svg)]()
[![Platform: iOS 18+](https://img.shields.io/badge/platform-iOS%2018%2B-blue.svg)]()
[![Bike: Royal Enfield](https://img.shields.io/badge/bike-Royal%20Enfield-red.svg)]()
[![fake_dash CI](https://github.com/kolaCZek/TripperDashPlusPlus/actions/workflows/fake_dash.yml/badge.svg)](https://github.com/kolaCZek/TripperDashPlusPlus/actions/workflows/fake_dash.yml)

---

## What is this?

The factory **Royal Enfield Tripper Dash** — the 4" rectangular TFT fitted to the **Himalayan 450** and **Guerrilla 450** — runs a full color, map-capable display. But the stock Royal Enfield app only pushes **~4 fps** of choppy Google-Maps-via-RTP to it, and the moment you lock your phone the stream dies.

This project replaces that pipeline with a proper one. We render a real, smooth navigation map on the iPhone, encode it as H.264 baseline @ **12 fps / 526×300** and stream it over the bike's Wi-Fi to the dash as RTP. Tile data and route calculation flow over cellular in parallel, so the dash gets a buttery, full-color map without the bike ever touching the internet.

**Goal of MVP:** open app → search destination → start nav → put phone in your pocket → ride.

> Not to be confused with the smaller round **Tripper Navigation Pod** on Meteor 350 / Classic 350 / Hunter 350 / Shotgun 650 / Super Meteor 650 — that one's a tiny arrow-only display with a different protocol. This project targets the *big* Tripper Dash.

## Why?

Because the Tripper Dash has a hardware H.264 decoder doing 526×300 at hardware-supported frame rates, and Royal Enfield ships it 4 fps of arrow icons over an unencrypted Wi-Fi link. The hardware deserves better.

Companion proof-of-concept (Python, dash-side protocol reverse engineering): **[kolaCZek/better-dash](https://github.com/kolaCZek/better-dash)**

## Status

🚧 **Planning / early development.** The build is staged across 8 phases (~6–8 weeks of part-time work).

| Phase | Status |
|-------|--------|
| 0 — Prerequisites (Apple Dev, test rig) | ✅ done |
| 1 — Xcode bootstrap | ✅ app builds & runs on iPhone |
| 2 — Fake-dash test harness (Python, Docker) | ✅ MVP done — [`tools/fake_dash/`](tools/fake_dash/) |
| 3 — K1G control plane (Swift) | 🟡 sources ready, awaiting on-device test — [`docs/PHASE_3_TESTING.md`](docs/PHASE_3_TESTING.md) |
| 4 — H.264 encoder + RTP packetizer | 🟡 sources ready (526×300 @ 12 fps, ~350 kbps), awaiting on-device validation |
| 5 — Live map rendering (Apple MapKit) | 🟡 `LocationService` + `MapSnapshotSource` wired on MKMapSnapshotter, awaiting screen-off field test — [`docs/PHASE_5_TESTING.md`](docs/PHASE_5_TESTING.md) |
| 6 — Background mode | 🟡 background keep-alive (CLLocation Always + silent audio + VT session auto-rebuild) wired in, awaiting screen-off field test |
| 7 — Wi-Fi orchestration | ⬜ |
| 8 — Polish + testing | ⬜ |

## Tech stack

- **Swift 6 / SwiftUI**, **iOS 18+**, **Xcode 26**
- **Apple MapKit** (`MKMapSnapshotter` for off-screen rendering — no third-party map SDK, no tile quota, no API key)
- Apple frameworks: `Network`, `VideoToolbox`, `CryptoKit`, `CoreLocation`, `AVFoundation`
- Python 3.11+ for the test harness (decode RTP, simulate the dash on macOS)

## Architecture (one paragraph)

iPhone joins two networks at once: the Tripper Dash's Wi-Fi AP (no internet, used only for UDP to `192.168.1.1`) and your cellular data (used for map tiles and routing). The app renders an Apple Maps view via `MKMapSnapshotter` off-screen, grabs frames as `CVPixelBuffer`s @ 12 fps, encodes them via VideoToolbox H.264 baseline @ ~350 kbps, packetizes into RTP FU-A units, and sends UDP to `192.168.1.1:5000`. The K1G control plane (RSA handshake + 1 Hz heartbeats + button events) runs on UDP `:2002`. Background execution is kept alive via `CoreLocation` Always + a silent audio loop, so the stream survives the lockscreen and lives happily with the phone in a tank bag or jacket pocket.

## Building

```sh
git clone https://github.com/kolaCZek/TripperDashPlusPlus.git
cd TripperDashPlusPlus
open TripperDashPP/TripperDashPP.xcodeproj
# 1. Sign in with your Apple ID (Xcode Settings → Accounts)
# 2. Set Bundle ID to something unique (e.g. eu.YOURNAME.tripperdashpp)
# 3. Build & Run on a real device (Simulator can't do Wi-Fi to the bike)
```

The free Apple Developer account works fine — the app uses no paid-only capabilities. You'll need to re-install every 7 days (Xcode → Run takes ~30 s).

No API keys, no service accounts, no SDK token plumbing — Apple Maps is built into iOS.

## Compatibility

The Tripper Dash (big rectangular TFT) ships on:

- ✅ **Royal Enfield Guerrilla 450** (2024+) — primary dev bike (@kolaCZek)
- ❓ **Royal Enfield Himalayan 450** (2023+) — same dash hardware in theory, untested

If you have a Himalayan 450 and want to help validate, please [open an issue](../../issues/new) — we'll add a "tested bikes" section as data comes in.

**Not compatible:** the small round Tripper Navigation Pod on Meteor 350 / Classic 350 / Hunter 350 / Shotgun 650 / Super Meteor 650. Different display, different protocol — this app won't talk to it.

## Legal / safety

- This project **reverse engineers an unencrypted-by-design Wi-Fi protocol** between the official RE phone app and the Tripper Dash for **interoperability** — protected under [Article 6 of EU Directive 2009/24/EC](https://eur-lex.europa.eu/legal-content/EN/TXT/?uri=CELEX:32009L0024). Not affiliated with, endorsed by, or sanctioned by Royal Enfield or Eicher Motors.
- **Don't read your phone while riding.** The whole point of this app is so you don't have to — but it doesn't replace common sense. Plan your route at a stop. Glance at the dash, not the phone.
- **Use at your own risk.** The MIT license applies: no warranty, no liability. If your bike catches fire because of bad RTP packets, that's on you (and also extremely unlikely).

## Contributing

Contributions, bug reports, and tested-bike confirmations are very welcome. See [`CONTRIBUTING.md`](CONTRIBUTING.md) for the workflow.

The most useful things you can do right now:
1. Try [better-dash](https://github.com/kolaCZek/better-dash) on a Himalayan 450 and confirm the K1G handshake works.
2. Reverse engineer the joystick event protocol if your dash sends different button mappings.
3. Sanity-check assumptions in code reviews — spot a wrong field width, a missing edge case, open an issue.

## Support the project

If this saves your sanity on a long ride, you can throw a coffee my way:

- ☕ [GitHub Sponsors](https://github.com/sponsors/kolaCZek) (set up after first working release)
- 🇨🇿 Czech bank account / Revolut — see Sponsors page

This is and will remain MIT-licensed. Sponsorship buys me time to fix bugs and test on more models, not exclusive features.

## License

[MIT](LICENSE) © 2026 Martin Kolací

---

*"The best dash mod is the one you can revert with one tap of the lock button." — me, probably*
