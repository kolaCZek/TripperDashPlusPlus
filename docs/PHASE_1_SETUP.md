# Phase 1 — Xcode bootstrap

**Goal:** turn the source files in `TripperDashPP/` into a buildable Xcode
project signed with your Apple ID, with the Mapbox SDK linked, deployable
to a real iPhone.

**Time:** ~60 minutes start to finish (assuming Xcode 26.5 is already
installed and your Apple ID is signed in).

**Prerequisites:**

- [x] Xcode 26.5+ installed
- [x] Apple ID added to Xcode (Settings → Accounts)
- [x] Apple Developer Team ID known (10-char alphanumeric, e.g. `ABC123XY45`)
- [x] Mapbox public access token (`pk.…`)
- [x] Mapbox secret download token (`sk.…`, scope `Downloads:Read`)
- [x] iPhone unlocked, plugged into the Mac, "Trust this computer" tapped
- [x] Repo cloned to `~/Projects/TripperDashPlusPlus` (or wherever)

---

## Step 1 — Mapbox `~/.netrc` (one-off, terminal)

The Mapbox SDK fetches binary frameworks from `api.mapbox.com` over HTTPS.
SPM authenticates against `~/.netrc`. Set it up once and forget.

```sh
cat >> ~/.netrc <<'EOF'
machine api.mapbox.com
  login mapbox
  password sk.YOUR_SECRET_DOWNLOAD_TOKEN_HERE
EOF
chmod 600 ~/.netrc
```

Replace `sk.YOUR_…` with the real `sk.` token. Verify with:

```sh
curl -n -sS -o /dev/null -w "%{http_code}\n" \
  https://api.mapbox.com/downloads/v2/mobile-maps-ios/releases/ios/
# Expected: 200
```

If you see `401`, the `sk.` token is missing the `Downloads:Read` scope —
regenerate it at https://account.mapbox.com/access-tokens/.

---

## Step 2 — Create the Xcode project

1. Open Xcode → **File → New → Project…**
2. Pick **iOS → App** → **Next**
3. Fill in:
   - **Product Name:** `TripperDashPP`
   - **Team:** your Personal Team
   - **Organization Identifier:** `eu.kolaczek`
   - **Bundle Identifier** (autofilled): `eu.kolaczek.tripperdashpp`
   - **Interface:** SwiftUI
   - **Language:** Swift
   - **Storage:** None
   - **Include Tests:** ☐ off (we'll add later if needed)
4. **Next** → save to `~/Projects/TripperDashPlusPlus/` (repo root). Xcode
   creates a subfolder `TripperDashPP/` — **important: Xcode will collide
   with the existing `TripperDashPP/` folder from the repo.**

   ### Conflict-handling (do this carefully):
   - Before saving, **move the repo's existing `TripperDashPP/` folder
     out of the way temporarily**:
     ```sh
     cd ~/Projects/TripperDashPlusPlus
     mv TripperDashPP TripperDashPP.swift_sources
     ```
   - Let Xcode create its own `TripperDashPP/` folder (with the
     auto-generated `TripperDashPPApp.swift`, `ContentView.swift`,
     `Assets.xcassets`, etc.)
   - **Quit Xcode** (Cmd+Q)
   - Merge our sources in:
     ```sh
     cd ~/Projects/TripperDashPlusPlus
     # Delete Xcode's auto-generated app + content stubs
     rm TripperDashPP/TripperDashPPApp.swift
     rm TripperDashPP/ContentView.swift
     # Move our prepared sources into place
     mv TripperDashPP.swift_sources/App TripperDashPP/
     mv TripperDashPP.swift_sources/UI TripperDashPP/
     mv TripperDashPP.swift_sources/README.md TripperDashPP/
     # Replace Xcode's Info.plist with ours
     mv TripperDashPP.swift_sources/Info.plist TripperDashPP/Info.plist
     # Cleanup
     rm -rf TripperDashPP.swift_sources
     ```
   - Reopen `TripperDashPP.xcodeproj`.

5. In the Project Navigator, **right-click on `TripperDashPP` group →
   Add Files to "TripperDashPP"…** and add the `App/` and `UI/` folders
   (choose "Create groups", target = `TripperDashPP`). Make sure both
   `TripperDashPPApp.swift` and the UI files appear in the navigator.

6. Delete the leftover Xcode-generated `ContentView.swift` reference if
   it's still in the navigator (right-click → Delete → Remove Reference).

7. **Cmd+B** to build. Expect **success** (no Mapbox import yet).

---

## Step 3 — Wire up `Secrets.xcconfig`

```sh
cd ~/Projects/TripperDashPlusPlus
cp Secrets.xcconfig.example TripperDashPP/Secrets.xcconfig
# Edit TripperDashPP/Secrets.xcconfig and fill in:
#   DEVELOPMENT_TEAM = ABC123XY45        (your real Team ID)
#   MBX_ACCESS_TOKEN = pk.eyJ1Ij...      (your real pk. token)
```

Then in Xcode:

1. Click the **TripperDashPP** project at the top of the navigator (blue icon)
2. Select the **TripperDashPP** project (not the target) in the middle pane
3. Go to the **Info** tab
4. Under **Configurations**, expand both **Debug** and **Release**
5. For each, set both the project and target "Based on Configuration File"
   to **`TripperDashPP/Secrets.xcconfig`**
6. Switch to the **TripperDashPP** target → **Signing & Capabilities**
   tab → set **Team** to your Personal Team, leave **Automatically manage
   signing** checked. The bundle ID should already be
   `eu.kolaczek.tripperdashpp`.

**Cmd+B** again — still expect success. Code signing should pick up
`DEVELOPMENT_TEAM` from the xcconfig.

---

## Step 4 — Add Mapbox SDK via SPM

1. Xcode → **File → Add Package Dependencies…**
2. Search URL field: `https://github.com/mapbox/mapbox-maps-ios`
3. **Dependency Rule:** "Up to Next Major Version" → `11.0.0`
4. Click **Add Package**
5. When prompted, add **MapboxMaps** to the **TripperDashPP** target.
6. Xcode resolves dependencies — this is when `~/.netrc` gets used.
   First resolve can take 2–5 minutes (the binary frameworks are ~150 MB).
   If it fails with `401 Unauthorized`, re-check Step 1.

**Verification:** add a temporary `import MapboxMaps` line at the top of
`TripperDashPPApp.swift`, hit **Cmd+B**. Should compile. Remove the line
afterwards (we don't use it until Phase 5).

---

## Step 5 — Configure deployment target + capabilities

Project → **TripperDashPP** target → **General** tab:

- **Minimum Deployments → iOS 18.0**
- **Supported Destinations:** keep only **iPhone** (uncheck iPad, Mac, Vision)
- **Display Name:** `TripperDash++`

**Info** tab — Xcode 26 stores Info.plist values in the project file by
default. Our `TripperDashPP/Info.plist` overrides this. Verify the file is
listed under **Build Settings → Packaging → Info.plist File**
(`TripperDashPP/Info.plist`).

**Signing & Capabilities** tab — Xcode auto-provisions, but verify that:

- ✅ Background Modes capability is present (Xcode adds it automatically
  because the Info.plist declares `UIBackgroundModes`)
- ✅ Location updates ☑️ and Audio ☑️ are both checked

If Background Modes capability is missing, click **+ Capability** →
**Background Modes** → check both **Location updates** and **Audio,
AirPlay, and Picture in Picture**.

---

## Step 6 — Build and run on the iPhone

1. Plug iPhone in, unlock it.
2. Top-left of Xcode, next to the scheme picker, select your iPhone as
   the destination.
3. **Cmd+R** (Run).
4. First-time prompts on the device:
   - **Untrusted Developer** — Settings → General → VPN & Device
     Management → tap your Apple ID → **Trust "Apple Development:
     you@example.com"**.
5. Rerun Cmd+R.

**Expected on the phone:**

- App launches with title "TripperDash++"
- Status banner: gray dot + "Not connected"
- Big "Map placeholder" gray rectangle
- "Open streaming view (dev)" button at the bottom
- Tap it — pushes a Form showing zeroed metrics

If you reach this state, **Phase 1 is done**. Push the project file:

```sh
cd ~/Projects/TripperDashPlusPlus
git add TripperDashPP.xcodeproj TripperDashPP/
git commit -m "feat: Phase 1 — Xcode project + SwiftUI shell"
git push origin main
```

---

## Common pitfalls

| Symptom | Cause | Fix |
|---|---|---|
| `401 Unauthorized` during SPM resolve | `~/.netrc` missing or `sk.` token lacks `Downloads:Read` scope | Recheck Step 1, regenerate token if needed |
| `CSSMERR_TP_NOT_TRUSTED` on a release-mode archive | Personal Team free certs aren't trusted by the App Store — cosmetic for our use case | Ignore — sideload via `Run` works fine |
| Code signing fails with "No profiles for 'eu.kolaczek.tripperdashpp'" | Bundle ID collision (someone else has it) or Apple ID not registered as developer | Append your initials to the bundle ID temporarily, e.g. `eu.kolaczek.tripperdashpp.dev`; or open developer.apple.com once to activate the account |
| Mapbox SDK build error "Cannot find type 'MapView'" | SPM didn't pull binary framework — `~/.netrc` failed silently | Settings → Packages → reset Package Caches, retry |
| App crashes on launch with "This app has crashed because it attempted to access privacy-sensitive data without a usage description" | Some background mode lacks an Info.plist key | Re-add the missing `NS…UsageDescription` key |
| Status banner shows "Error" | Nothing — we never set `.error` in Phase 1; if you see it, you have a stale build | Clean Build Folder (Cmd+Shift+K), rebuild |

---

## What's next

When Phase 1 is green, ping the assistant. Phase 3 (K1G control plane in
Swift) is the next code-writing fase and lives in
`TripperDashPP/Tripper/`. The `fake_dash` Docker harness will be the
counterparty — bring it up with `make fake-dash-up` and we'll write the
handshake from the iOS side against it.

Phase 2 (`fake_dash`) is already done and CI-green — see
`tools/fake_dash/README.md`.
