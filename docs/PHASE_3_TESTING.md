# Phase 3 — Testing the K1G control plane

**Goal:** verify the iPhone client can complete the full RSA handshake
against `fake_dash` and hold a steady heartbeat.

**Prerequisites:** Phase 1 complete (app builds & runs on device),
`fake_dash` Docker container available somewhere reachable from the
phone over Wi-Fi.

---

## Step 0 — Add the Tripper module to the Xcode project

The Phase 3 sources land in `TripperDashPP/Tripper/` on disk, but the
Xcode project file (`TripperDashPP.xcodeproj/project.pbxproj`) doesn't
know about them yet — Xcode only auto-discovers folders that already
existed when you created the project.

In Xcode:

1. Open `TripperDashPP/TripperDashPP.xcodeproj`.
2. In the Project Navigator, right-click the `TripperDashPP` group
   (yellow folder icon) and pick **"Add Files to TripperDashPP…"**.
3. Navigate to `TripperDashPP/Tripper/`, select the **folder itself**
   (not the individual files), and:
   - ✅ "Copy items if needed" — **OFF** (the files are already in place)
   - ✅ "Create groups" (default)
   - ✅ Targets: TripperDashPP — **ON**
4. Click **Add**.

The 6 Swift files should now appear in the Project Navigator under a
new `Tripper` group, all with the build target checked.

`Cmd+B` should compile cleanly. If it doesn't, the most common issue is
a missing target membership — select each file in the navigator and in
the Inspector (right pane) make sure **TripperDashPP** is checked under
"Target Membership".

---

## Step 1 — Pick a network topology

The real Tripper bike runs an open AP on `192.168.1.0/24`. For Phase 3
we just need the phone and `fake_dash` on the **same Wi-Fi LAN**, with
no NAT in between.

Two ways:

### (a) `fake_dash` on a Mac/Linux on your home Wi-Fi (easy)

```sh
# On the host running fake_dash
make fake-dash-up
ip addr show | grep -A 1 "wlan\|en0"   # note the LAN IP, e.g. 192.168.1.42
```

The phone must be on the **same Wi-Fi** (e.g. `kolaczek-home`).
You'll point the iPhone app at the host's LAN IP, not `192.168.1.1`.

### (b) `fake_dash` on a real Wi-Fi AP that mimics the bike (closest to production)

Set up a temporary AP that hands out `192.168.1.0/24`, run `fake_dash`
on the gateway box (e.g. a Raspberry Pi at `192.168.1.1`), join with the
phone, and use the default `192.168.1.1` host. This is what you'll
actually use for end-to-end tests in later phases.

For now, **(a) is fine** — handshake is identical either way.

---

## Step 2 — Override `bikeHost` for the test session

The default in `BikeLink.swift` is the real bike address `192.168.1.1`.
When pointing at `fake_dash` on a different LAN, override it.

Easiest path: temporarily edit `BikeLink.swift` line:

```swift
var bikeHost: String = K1G.bikeIPv4
```

to your `fake_dash` host:

```swift
var bikeHost: String = "192.168.1.42"  // Mac running fake_dash
```

(Phase 7 adds a proper settings UI for this.)

Build & run on the phone (`Cmd+R`).

---

## Step 3 — Start `fake_dash` with logs visible

```sh
# In one terminal
make fake-dash-up
make fake-dash-logs
```

You should see:

```
fake_dash | INFO  fake_dash.server  Listening on UDP 0.0.0.0:2002 (control)
fake_dash | INFO  fake_dash.server  Listening on UDP 0.0.0.0:5000 (RTP)
fake_dash | INFO  fake_dash.rsa     Loaded existing bike RSA key from /data/keys/bike_rsa.pem
```

Keep this terminal visible — the handshake leaves a clear paper trail.

---

## Step 4 — Tap "Connect to dash" on the phone

The button on the home screen kicks off the connect flow. Expect:

| Time | UI banner color | Bike-side log |
|------|-----------------|---------------|
| t=0    | gray → yellow | — |
| t<1s   | orange | `RX 22B from <phone_ip>: q3c.e (07 04)` |
| t<1s   | orange | `TX 138B to <phone_ip>: 07 00 (modulus, 128B) + 07 03 (exponent, 4B)` |
| t<2s   | orange | `RX 149B from <phone_ip>: q3c.d (08 00, 128B ciphertext)` |
| t<2s   | orange | `INFO Decrypted SSID=RE_FAKE_260616, AES key=…` |
| t<2s   | blue ✅ | `TX 22B to <phone_ip>: 07 01 01 (auth OK)` |
| t≥2s   | blue, every 1s | `RX 17B from <phone_ip>: empty K1G envelope (heartbeat)` |

The button text on the phone changes from "Connect to dash" → "Connecting…"
→ "Open streaming view" + "Disconnect".

---

## Step 5 — Failure modes & what they mean

| Symptom | Likely cause |
|---------|--------------|
| Banner stays yellow >5s | UDP socket can't bind to Wi-Fi. Check `prohibitExpensivePaths` isn't routing to LTE — usually means the phone has no Wi-Fi at all. |
| Bike logs `RX … but K1G magic missing` | Endianness or magic constant drift — `K1GConstants.swift` and `fake_dash/protocol.py` disagree. |
| Bike logs `RSA decrypt failed: invalid padding` | `RsaHandshake.swift` is producing OAEP instead of PKCS1v1.5, **or** the SecKey wasn't built from the wire bytes correctly. Re-check `encodePKCS1RSAPublicKey`. |
| Auth-OK comes back but UI never reaches `.connected` | Inbound stream consumed the OK packet inside `runHandshake` but the loop loops forever. Verify the `for await` exits on success. |
| Phone goes through handshake fine, then no heartbeats | `HeartbeatLoop.run()` task got cancelled — usually because `disconnect()` was called or the socket failed silently. Check Console.app under `eu.kolaczek.tripperdashpp`. |

---

## Step 6 — Confirm via fake_dash test fixture

Outside the phone, you can reproduce the same exchange purely in Python
to confirm `fake_dash` itself isn't drifting:

```sh
cd tools/fake_dash
pytest tests/test_integration.py -v
```

All 19 tests should still pass. If they do but the phone fails, the bug
is in the Swift code; if they fail too, the bug is in `fake_dash`.

---

## Step 7 — Diagnostic logs on the phone

Open Console.app on the Mac, attach to the phone, filter by subsystem:

```
eu.kolaczek.tripperdashpp
```

You'll see:
- `BikeLink` — state transitions, ssid
- `DashSocket` — `.ready`, `.waiting`, `.failed`
- `RsaHandshake` (none today, but Phase 4 adds frame logs)

---

## Done condition

✅ "Connect to dash" → blue banner + "Disconnect" button visible
✅ `fake_dash` logs show heartbeats arriving once a second
✅ Tapping "Disconnect" returns the banner to gray, heartbeats stop

When you hit those three, Phase 3 is green. Tell the agent and we'll
move to **Phase 4 — VideoToolbox encoder + RTP packetizer**.
