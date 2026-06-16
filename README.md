# TripperDash++

> Stream live Google-Maps-quality navigation from your iPhone to the **Royal Enfield Tripper** TFT display — even with your phone's screen off.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Status: Planning](https://img.shields.io/badge/status-planning-orange.svg)]()
[![Platform: iOS 26+](https://img.shields.io/badge/platform-iOS%2026%2B-blue.svg)]()
[![Bike: Royal Enfield](https://img.shields.io/badge/bike-Royal%20Enfield-red.svg)]()

---

## What is this?

The factory **Royal Enfield Tripper Navigation** pod (the small round TFT on Meteor / Classic / Hunter / Himalayan / Shotgun / Guerrilla) only does turn-by-turn arrows from the official RE app. No map. No POI search. No live re-route.

This project turns that screen into a **real, live, online map navigation** display — rendered on your iPhone, streamed over Wi-Fi to the dash as an H.264 video. Tile data and route calculation flow over cellular in parallel, so the dash gets a buttery, full-color map without the bike ever touching the internet.

**Goal of MVP:** open app → search destination → start nav → put phone in your pocket → ride.

## Why?

Because the Tripper screen has been sitting there with a 526×300 H.264 decoder doing nothing more than three arrow icons. The hardware deserves better.

Companion proof-of-concept (Python, dash-side protocol reverse engineering): **[kolaCZek/better-dash](https://github.com/kolaCZek/better-dash)**

## Status

🚧 **Planning / early development.** Nothing runs yet. The build is staged across 8 phases (~6–8 weeks of part-time work).

| Phase | Status |
|-------|--------|
| 0 — Prerequisites (Mapbox, Apple Dev, test rig) | ⬜ |
| 1 — Xcode bootstrap | ⬜ |
| 2 — Fake-dash test harness (Python) | ⬜ |
| 3 — K1G control plane (Swift port) | ⬜ |
| 4 — H.264 encoder + RTP packetizer | ⬜ |
| 5 — Mapbox off-screen renderer | ⬜ |
| 6 — Navigation + background mode | ⬜ |
| 7 — Wi-Fi orchestration | ⬜ |
| 8 — Polish + testing | ⬜ |

## Tech stack

- **Swift 6 / SwiftUI**, **iOS 26+**, **Xcode 26**
- **Mapbox Maps SDK iOS v11** (off-screen rendering)
- Apple frameworks: `Network`, `VideoToolbox`, `CryptoKit`, `CoreLocation`, `AVFoundation`
- Python 3.11+ for the test harness (decode RTP, simulate the dash on macOS)

## Architecture (one paragraph)

iPhone joins two networks at once: the Tripper's Wi-Fi AP (no internet, used only for UDP to `192.168.1.1`) and your cellular data (used for Mapbox tiles, geocoding, and Directions API). The app renders a Mapbox map into a hidden `UIWindow`, grabs frames as `CVPixelBuffer`s @ 12 fps, encodes them via VideoToolbox H.264 baseline @ ~300 kbps, packetizes into RTP FU-A units, and sends UDP to `192.168.1.1:5000`. The K1G control plane (RSA handshake + 1 Hz heartbeats + button events) runs on UDP `:2002`. Background execution is kept alive via `CoreLocation` Always + a silent audio loop.

## Building

> **Not buildable yet.** Once Phase 1 is done:

```sh
git clone https://github.com/kolaCZek/TripperDashPlusPlus.git
cd TripperDashPlusPlus
open TripperDashPP.xcodeproj
# 1. Sign in with your Apple ID (Xcode Settings → Accounts)
# 2. Set Bundle ID to something unique (e.g. eu.YOURNAME.tripperdashpp)
# 3. Drop your Mapbox secret token into ~/.netrc (see docs/setup.md)
# 4. Drop your Mapbox public token into TripperDashPP/Secrets.xcconfig
# 5. Build & Run on a real device (Simulator can't do Wi-Fi to the bike)
```

The free Apple Developer account works fine — the app uses no paid-only capabilities. You'll need to re-install every 7 days (Xcode → Run takes ~30 s).

## Compatibility

Tested with (will be tested with, more accurately):

- ✅ **Royal Enfield Guerrilla 450** (2025) — primary dev bike (@kolaCZek)
- ❓ Meteor 350, Classic 350, Hunter 350, Himalayan 450, Shotgun 650, Super Meteor 650 — same Tripper hardware in theory, untested

If you have one of the untested models and want to help, please [open an issue](../../issues/new) — we'll add a "tested bikes" section as data comes in.

## Legal / safety

- This project **reverse engineers an unencrypted-by-design Wi-Fi protocol** between the official RE phone app and the Tripper dash for **interoperability** — protected under [Article 6 of EU Directive 2009/24/EC](https://eur-lex.europa.eu/legal-content/EN/TXT/?uri=CELEX:32009L0024). Not affiliated with, endorsed by, or sanctioned by Royal Enfield, Eicher Motors, or Mapbox.
- **Don't read your phone while riding.** The whole point of this app is so you don't have to — but it doesn't replace common sense. Plan your route at a stop. Glance at the dash, not the phone.
- **Use at your own risk.** The MIT license applies: no warranty, no liability. If your bike catches fire because of bad RTP packets, that's on you (and also extremely unlikely).

## Contributing

Contributions, bug reports, and tested-bike confirmations are very welcome. See [`CONTRIBUTING.md`](CONTRIBUTING.md) for the workflow.

The most useful things you can do right now:
1. Try [better-dash](https://github.com/kolaCZek/better-dash) on a non-Guerrilla model and confirm the K1G handshake works.
2. Reverse engineer the joystick event protocol if your dash has different button mappings.
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
