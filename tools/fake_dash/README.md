# fake_dash — Royal Enfield Tripper TFT emulator

Python test harness that mimics the Tripper dashboard so you can develop
**TripperDash++** without parking your iPhone in front of a parked
motorcycle. Speaks the K1G control plane on UDP/2002 and accepts an RTP
H.264 stream on UDP/5000 — exactly what the real dash does on the bike's
`RE_xxxx_yymmdd` Wi-Fi AP.

## Quick start (Docker)

```bash
# From this directory:
docker compose up --build
```

The container exposes:
- `udp://0.0.0.0:2002` — K1G control plane (RSA handshake, route card,
  joystick events)
- `udp://0.0.0.0:5000` — RTP video sink (H.264 baseline, payload type
  96, FU-A reassembly)

Captured H.264 streams go to `./captures/dash_capture_<timestamp>.h264`.
The bike's RSA keypair (auto-generated on first run) is persisted in
`./keys/bike_rsa.pem`.

## Inject a joystick event

```bash
# From another terminal:
docker compose exec fake_dash python -m fake_dash button left
docker compose exec fake_dash python -m fake_dash button click
```

Available buttons: `left`, `right`, `down`, `click` (matches the real
joystick's four-way layout).

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
| `08 04`     | phone → bike | request pubkey (`q3c.e`) — NOT 0x07; that family is inbound-only |
| `07 00`     | bike → phone | RSA modulus (128 B, big-endian) |
| `07 03`     | bike → phone | RSA exponent (typically `00 01 00 01`) |
| `08 00`     | phone → bike | RSA-encrypted `ssid ‖ aes_key` (`q3c.d`) |
| `07 01 01`  | bike → phone | auth OK |
| `07 01 00`  | bike → phone | auth fail |
| `09 00 0001 XX` | bike → phone | joystick (XX = 0x13/0x14/0x15/0x18) |
| `06 …`      | phone → bike | route card / heartbeat |

Reference implementation (the phone side): https://github.com/kolaCZek/better-dash

## Architecture

```
                ┌───────────────────────────────────┐
                │     fake_dash container           │
                │                                   │
   UDP/2002 ───▶│ server.py  ◀──▶  rsa_handshake.py│
                │     │                             │
                │     ▼                             │
                │  buttons.py (fan-out)             │
                │                                   │
   UDP/5000 ───▶│ rtp_sink.py ──▶ /captures/*.h264  │
                │                                   │
                └───────────────────────────────────┘
                          ▲
                          │
                  ./keys/bike_rsa.pem (persistent)
```

## Status

Phase 2 deliverable for the TripperDash++ project. See the parent repo's
`README.md` and `CLAUDE.md` for the broader context.
