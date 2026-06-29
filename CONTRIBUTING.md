# Contributing to TripperDash++

Thanks for your interest! This project is small but ambitious, and **any kind of help is welcome** — from a single tested-bike confirmation to a full feature PR.

## Quick contribution paths

### 🏍️ I have a non-Guerrilla Royal Enfield with a Tripper pod

This is the **most valuable** contribution right now. Until we know which bikes use the same K1G protocol, we can't claim broad compatibility.

1. Try [better-dash](https://github.com/kolaCZek/better-dash) (Python reference impl) against your bike.
2. If the handshake completes and you see frames on the dash, [open an issue](../../issues/new?template=tested-bike.md) with:
   - Bike model + year
   - Tripper firmware version (visible in the RE app, About section)
   - iOS version of phone used for the original RE app pairing
   - Any quirks (different SSID prefix, different default password, etc.)

### 🐛 I found a bug

[Open an issue](../../issues/new?template=bug-report.md) with:
- iPhone model + iOS version
- Bike model + Tripper firmware
- Steps to reproduce
- Expected vs actual behavior
- Logs (the maneuver/instruction log is in the app's Documents folder — pull it via the Files app or Xcode → Devices)

### 💡 I have a feature idea

[Open an issue](../../issues/new?template=feature-request.md). Please skim the open issues first so you can 👍 an existing one instead of opening a duplicate.

### 🔧 I want to write code

Awesome. Please:
1. **Open an issue first** before starting work on anything non-trivial — there might be design decisions worth discussing, or it might already be in progress.
2. Fork, branch from `main`, do the work, open a PR.
3. PR title format: imperative present, short and specific (e.g. `Add RSA session-key exchange`, `Fix initial-burst seg_count`).
4. CI must pass — the `fake_dash` pytest suite + Docker image build run on every PR. But remember: **fake_dash is a permissive plumbing harness, not a protocol authority.** Anything touching the K1G wire format must also be byte-verified against [better-dash](https://github.com/kolaCZek/better-dash).
5. New Swift code should follow Apple's [Swift API Design Guidelines](https://swift.org/documentation/api-design-guidelines/).

## Development setup

See [README.md → Building](README.md#building). TL;DR:
- macOS 15+, Xcode 26+
- Free Apple ID is enough for sideload
- No API keys, no map SDK account — OSM tiles and MapKit need none
- Real iPhone — the Simulator can't open Wi-Fi to the bike
- Optional: Docker, to run the `fake_dash` harness (`make fake-dash-up`)

## Project conventions

- **Code & file paths**: English.
- **User-facing strings in the app**: localized via `.strings`. Default is English; Czech is the second locale.
- **README, docs, PR/issue text**: English (so the global RE community can read it).
- **Internal discussion** (Discord, my own notes): whatever language is natural — but the result that ends up in the repo is English.
- **Commit messages**: imperative present (`Add K1G handshake`, not `Added` / `Adds`). Reference issue numbers when relevant.

## Code of conduct

Be excellent to each other. This is a hobby project; nobody is paid to be here, including me. Constructive criticism welcome, snark not. If something feels off, [reach out privately](https://github.com/kolaCZek) instead of escalating publicly.

## License of contributions

By submitting a PR you agree your contribution is MIT-licensed under the same terms as the rest of the project. If you contribute substantial code I may ask you to add yourself to a future `CONTRIBUTORS.md`.

## Questions?

Open a [discussion](../../discussions) (once enabled) or DM me on GitHub.
