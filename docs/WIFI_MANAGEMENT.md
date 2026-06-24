# Wi-Fi Management

TripperDash++ keeps a list of saved dash Wi-Fi networks and can — on a
**paid** Apple Developer account — read the currently-connected SSID and
join the dash AP from inside the app. This document explains how the
feature behaves on a free vs paid account, and the exact one-time steps to
activate the paid capabilities.

## TL;DR

| Capability                                   | Free account | Paid account |
|----------------------------------------------|:------------:|:------------:|
| Save / edit / delete known networks          | ✅           | ✅           |
| Manual "Connect to dash" (UDP handshake)     | ✅           | ✅           |
| Auto-reconnect after a mid-ride drop         | ✅           | ✅           |
| Read currently-connected SSID (green dot)    | ❌           | ✅           |
| Join dash Wi-Fi from the app                 | ❌           | ✅           |
| SSID-aware auto-connect (hands-free)         | ❌           | ✅           |

The app **compiles and runs on a free account** — the paid-only paths
degrade gracefully (no crash). The entitlements file ships empty so the
free build signs; activation is uncommenting four lines + a checkbox.

## Why two entitlements

Two distinct NetworkExtension capabilities are involved, and **both are
paid-only** (confirmed against Apple's own docs — see
[Supported capabilities (iOS)](https://developer.apple.com/help/account/reference/supported-capabilities-ios/)
which lists "Access WiFi Information → Requires membership: Yes" and
"Hotspot Configuration → Requires membership: Yes"):

1. **Access WiFi Information** — `com.apple.developer.networking.wifi-info`
   Lets `NEHotspotNetwork.fetchCurrent()` read the connected SSID.
   Used for: the green "connected" dot, and SSID-aware auto-connect.

2. **Hotspot Configuration** — `com.apple.developer.networking.HotspotConfiguration`
   Lets `NEHotspotConfigurationManager.apply()` join a network.
   Used for: the per-row "Connect" button and the 1/N connect flow's join.

> On a free Personal Team, Apple's provisioning service **refuses to issue
> a profile** containing either entitlement, so a build that *declares*
> them fails to **sign** — it never even reaches the device. That's why
> the committed `TripperDashPP.entitlements` is intentionally empty.

## Graceful degradation (how the code stays free-safe)

- `WiFiManager.currentSSID()` → `NEHotspotNetwork.fetchCurrent` calls back
  with `nil` when the entitlement is absent ⇒ no SSID, no green dots, and
  `WiFiAutoConnector`'s gate never fires. Inert, not broken.
- `WiFiManager.join(_:)` → `apply()` calls back with an error ⇒ returns
  `.failed`, surfaced as a friendly link error. No crash.
- `BikeLink`'s UDP "connect to dash" handshake needs **neither**
  entitlement and works on any account, as long as the phone is already on
  the dash Wi-Fi (join it manually via iOS Settings on a free account).

So on a free build the rider workflow is:
1. Join `RE_xxxxxx` once in **iOS Settings → Wi-Fi** (iOS remembers it).
2. Open TripperDash++, tap **Connect to dash**. The UDP handshake runs.

On a paid build, steps collapse into a single in-app **Connect** that also
joins the Wi-Fi, plus hands-free auto-connect when you're already on it.

## Activation steps (one-time, after buying the $99/yr membership)

1. **Enrol** the Apple ID in the Apple Developer Program ($99/yr) and let
   the membership go active (can take a few hours).

2. In Xcode, select the **TripperDashPP** target → **Signing &
   Capabilities**. With the paid team selected, click **+ Capability** and
   add **both**:
   - *Access WiFi Information*
   - *Hotspot Configuration*

   Xcode writes the two entitlement keys into `TripperDashPP.entitlements`
   automatically. If you prefer to do it by hand, uncomment the four lines
   in that file (the two `<key>…</key><true/>` pairs).

3. Confirm `TripperDashPP.entitlements` now contains:
   ```xml
   <key>com.apple.developer.networking.wifi-info</key>
   <true/>
   <key>com.apple.developer.networking.HotspotConfiguration</key>
   <true/>
   ```
   (The `CODE_SIGN_ENTITLEMENTS = TripperDashPP.entitlements;` build
   setting is already wired in `project.pbxproj` for Debug + Release, so
   there's nothing to change there.)

4. **Location permission** — SSID reads are gated behind Location Services
   by iOS privacy rules. The app already requests "When In Use"; make sure
   it's granted, or `currentSSID()` returns `nil` even on a paid build.

5. Clean build folder (⇧⌘K), rebuild to a device, and verify:
   - Settings → *Dash Wi-Fi networks* shows a **green dot** on the network
     you're currently joined to.
   - The per-row **Connect** triggers the iOS "Join Wi-Fi Network?" prompt
     the first time.
   - Walking into range with the app foregrounded auto-starts the link.

## Behavioural notes

- **Fixed dash IP.** Every Tripper dash is `192.168.1.1`
  (`K1G.bikeIPv4`), so there is no per-network IP field — only the SSID
  (and an optional passphrase) is stored. The old free-form "Dash IP"
  setting was removed.

- **Passphrase.** New networks pre-fill the Royal Enfield factory default
  (a published value, not a secret). Override it per-network only if you
  changed your dash's Wi-Fi password. Stored device-local in
  `UserDefaults`, never in the repo.

- **Suppress-after-disconnect.** Tapping **Disconnect** suppresses
  auto-connect for the SSID you're on until the SSID changes (you rode
  away) or Wi-Fi cycles off→on. Without this, Disconnect would be useless
  while parked next to the bike — the app would instantly reconnect.

- **Association ≠ working link.** A successful Wi-Fi join only means the
  radio associated; the dash AP has no internet. The real proof of a
  usable connection is BikeLink's UDP handshake to `192.168.1.1`, which
  runs right after every join.

- **iOS can't scan Wi-Fi.** There's no public API to list nearby SSIDs, so
  the known-networks list is purely manual (typed once, remembered). This
  is an iOS platform limitation, not a design choice.
