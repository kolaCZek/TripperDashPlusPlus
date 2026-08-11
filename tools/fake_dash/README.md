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

## Sniff nav-info TLVs (capture OEM-app setting bytes)

Two phone settings currently have **no confirmed wire byte** on the
TripperDash++ side, because we've never seen how the *original* Royal
Enfield app encodes them:

- **12/24-hour ETA format** — we always send `05 54 0001 30`; the dash-side
  byte for genuine 12-hour render is unknown (`0x31` was field-confirmed to
  blank the ETA).
- **Bubble bottom row** (ETA vs distance) — no longer gated on our wire; the
  dash picks the field. The selector byte (suspected `05 0C`) is unknown.

The sniffer captures these by pointing the **original RE app** at the
emulator and diffing the wire state across a toggle flip. The active-nav
fields are plaintext (only the session-key handshake is RSA-encrypted), so
no decryption is needed.

```bash
# 1. Start the emulator with the sniffer enabled:
make fake-dash-sniff            # or: FAKE_DASH_SNIFF=1 docker compose up -d

# 2. Join the original Royal Enfield app to this "bike" (same Wi-Fi /
#    host IP as any physical-iPhone run) and start navigation. Each
#    nav-info field is logged once, then goes quiet:
make fake-dash-logs
#    SNIFF ('10.0.0.5', 51234): 05 54  etaFormat (**suspected 12/24h byte**)  30  u8=48
#    SNIFF ('10.0.0.5', 51234): 05 0C  **UNDECODED — suspected bottom-row selector**  04  u8=4

# 3. Baseline the current wire state:
make fake-dash-snap-mark        # OK baseline marked (14 fields)

# 4. Flip ONE setting in the RE app (e.g. 24h → 12h), then diff:
make fake-dash-snap-diff
#    CHANGED since baseline:
#      ~ CHANGED 05 54 etaFormat (**suspected 12/24h byte**): 30 -> 31

# 5. `make fake-dash-snap-dump` lists every nav-info field currently seen.
```

Whatever field the diff names **is** the control byte for the setting you
just flipped — feed it back into `K1GPacket.tlv*` (and update the
`FIELD_CATALOG` in `nav_sniffer.py` + this README, per the docs-in-lockstep
rule). If the diff is empty, the OEM app drives that setting dash-side with
no wire change, and the feature can't be mirrored from the phone.

> The sniffer is **off by default** — normal harness / CI runs are
> unaffected. It only decodes `0x05` fields and adds the `snap` control
> commands when `--sniff` / `FAKE_DASH_SNIFF=1` is set.

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
| `05 …`      | phone → bike | active-nav info TLVs (maneuver, distance, ETA, units, decimal sep) — decode with `--sniff` |
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
                │                                   │
   UDP/5000 ───▶│ rtp_sink.py ──▶ /captures/*.h264  │
                │                                   │
                └───────────────────────────────────┘
                          ▲
                          │
                  ./keys/bike_rsa.pem (persistent)
```

## Status

Plumbing test harness for the TripperDash++ project — runs in CI on every
PR (pytest suite + Docker image build). See the parent repo's `README.md`
and `CLAUDE.md` for the broader context.

> ⚠️ **This harness is intentionally permissive — it is not the protocol
> authority.** It will accept packets the real Tripper dash silently drops
> (looser `seg_count`, source-port, and type-byte validation). Use it for
> plumbing / regression tests, but byte-verify any wire-format change
> against [better-dash](https://github.com/kolaCZek/better-dash), which is
> the byte-level source of truth.
