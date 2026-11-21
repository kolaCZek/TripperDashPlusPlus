# fake_dash — Royal Enfield Tripper TFT emulator

Python test harness that mimics the Tripper dashboard so you can develop
**TripperDash++** without parking your iPhone in front of a parked
motorcycle. Speaks the K1G control plane on UDP/2000 and accepts an RTP
H.264 stream on UDP/5000 — exactly what the real dash does on the bike's
`RE_xxxx_yymmdd` Wi-Fi AP.

## Quick start (Docker)

```bash
# From this directory:
docker compose up --build
```

The container exposes:
- `udp://0.0.0.0:2000` — K1G control plane (RSA handshake, route card,
  joystick events). The real dash replies to the phone's `:2002`; the
  harness replies to whatever source port the packet came from.
- `udp://0.0.0.0:5000` — RTP video sink (H.264 baseline, payload type
  96, FU-A reassembly)

Captured H.264 streams go to `./captures/dash_capture_<timestamp>.h264`.
The bike's RSA keypair (auto-generated on first run) is persisted in
`./keys/bike_rsa.pem`.

## Configuration

Environment variables (all optional; `docker-compose.yml` sets the first
three): `FAKE_DASH_BIND` (`0.0.0.0`), `FAKE_DASH_CAPTURES_DIR` (`/captures`),
`FAKE_DASH_KEYS_DIR` (`/keys`), `FAKE_DASH_K1G_PORT` (`2000`),
`FAKE_DASH_RTP_PORT` (`5000`), `FAKE_DASH_SSID` (`RE_FAKE_260616`, the
SSID the handshake expects), `FAKE_DASH_LOG_LEVEL` (`INFO`),
`FAKE_DASH_NO_BEACON` (set to disable the 1 Hz UDP broadcast beacon),
`FAKE_DASH_CONTROL_SOCKET` (`/run/fake_dash.sock`, how `button` reaches the
running server). `python -m fake_dash --help` lists the flags.

## Run the tests

```bash
pip install -e ".[dev]"   # from this directory; Python 3.11+
pytest
```

or `make fake-dash-test` from the repo root. The iOS app reaches the
container because `BikeLink.bikeHost` can be overridden (UserDefaults key
`BikeLink.bikeHost`; default `192.168.1.1`).

## Inject a joystick event

```bash
# From another terminal:
docker compose exec fake_dash python -m fake_dash button left
docker compose exec fake_dash python -m fake_dash button click
```

Available buttons: `left`, `right`, `down`, `click` (map-screen stick
codes), plus the context-dependent codes `next_track`, `prev_track`,
`remove_waypoint`, `exit_nav` (see `fake_dash/buttons.py`).

## Inspect a captured stream

```bash
# Convert to MP4 for playback:
docker compose exec fake_dash ffmpeg -i /captures/dash_capture_*.h264 \
    -c:v copy -movflags +faststart /captures/playback.mp4

# Or pipe straight into VLC / IINA on the host:
open captures/dash_capture_*.h264
```

## Protocol crib sheet

| K1G segment | Direction | Meaning |
|-------------|-----------|---------|
| `08 04`     | phone → bike | request pubkey (`REQUEST_PUBKEY`) — NOT 0x07; that family is inbound-only |
| `07 00`     | bike → phone | RSA modulus (128 B, big-endian) |
| `07 03`     | bike → phone | RSA exponent (typically `00 01 00 01`) |
| `08 00`     | phone → bike | RSA-encrypted `ssid ‖ aes_key` (`SESSION_KEY`) |
| `07 01 01`  | bike → phone | auth OK |
| `07 01 00`  | bike → phone | auth fail |
| `01 01`     | bike → phone | heartbeat ACK (`K1G\0` + counter), sent in reply to the phone's `06 04` battery TLV |
| `09 00 0001 XX` | bike → phone | joystick (map screen XX = 0x13/0x14/0x15/0x18; now-playing 0x09/0x0A; in-menu 0x20/0x12) |
| `06 …`      | phone → bike | route card / heartbeat |

Reference implementation (the phone side): https://github.com/kolaCZek/better-dash

## Architecture

```
                ┌───────────────────────────────────┐
                │     fake_dash container           │
                │                                   │
   UDP/2000 ───▶│ server.py  ◀──▶  rsa_handshake.py│
                │     │                             │
                │     ▼                             │
                │  buttons.py (fan-out)             │
                │  control_socket.py (CLI → server) │
                │                                   │
   UDP/5000 ───▶│ rtp_sink.py ──▶ /captures/*.h264  │
                │                                   │
                └───────────────────────────────────┘
                          ▲
                          │
                  ./keys/bike_rsa.pem (persistent)
```

## Status

Plumbing test harness for the TripperDash++ project — runs in CI on PRs
and `main` pushes that touch `tools/` or `TripperDashPP/` (pytest suite + Docker
image build). The suite also holds Python mirrors of pure Swift logic and
Swift-source drift guards. See the parent repo's `README.md`
and `CLAUDE.md` for the broader context.

> ⚠️ **This harness is intentionally permissive — it is not the protocol
> authority.** It will accept packets the real Tripper dash silently drops
> (looser `seg_count`, source-port, and type-byte validation). Use it for
> plumbing / regression tests, but byte-verify any wire-format change
> against [better-dash](https://github.com/kolaCZek/better-dash), which is
> the byte-level source of truth.
