# App Store Review Notes — TripperDash++

Paste the section below into **App Store Connect → App Review Information → Notes**.
Keep it tight; reviewers skim. The demo path is what lets them test without the
motorcycle, and the background-location justification is what clears Guideline 2.5.4.

---

## REVIEW NOTES (paste this), as of 1.0.5 build 2

```
TripperDash++ streams a live turn-by-turn navigation map to the round TFT dash (Tripper) of Royal Enfield Himalayan 450, Guerrilla 450 and Bear 650 motorcycles, over the bike's own Wi-Fi.

Short video of the app connecting to the bike: https://youtu.be/wqzyT9107rk

NEW IN 1.0.5 (what to look at)
- Optional tips: Settings > Support (4 consumable in-app purchases). They are a pure thank-you: they unlock no content or features, the app keeps no record of them, and every feature stays free.
- Shortcuts and Siri actions: start a free ride, navigate to a favorite, a saved route or a place, ride status, stop the ride.
- Quick Ride home-screen widget: Home, Work, Free Ride, Fuel.
- Turn arrow on the route line, smarter rerouting, Wi-Fi drop tolerance.

HOW TO TEST WITHOUT THE MOTORCYCLE (Demo mode)
1. Tap the gear icon (top right) to open Settings. In "Bikes", turn on "Demo mode".
2. The bottom button now reads "Connect (demo)". Tap it: the app simulates a connected dash and shows, in the app, the same 526x300 map frame it would stream to the bike.
3. Search a destination (or tap the map) and start navigation, or use "Start free ride". Route line, turn arrow, ETA, speed limit and voice guidance all run.
Shortcuts and the widget use the same connect path, so they work in Demo mode too.
There is no demo account: the app has no accounts and no login.

LOCATION AND BACKGROUND MODES (Guideline 2.5.4)
The app first asks for While Using, and While Using is enough for every feature. Location updates start in the foreground when the rider connects or starts a ride; with the "location" background mode they keep the dash map live after the phone is locked, with the blue location indicator shown. The app then offers the Always upgrade once. It is optional: it only lets iOS keep or relaunch the app in the background more reliably, and declining it blocks nothing. Settings > About > Check permissions shows the current state.
Location is used only to place the bike on the map, advance the route and render the dash frame. It is not used for ads, analytics, tracking or profiling, and there is no backend or account of ours. It leaves the device only as the rendered map sent to the bike's dash over local Wi-Fi, and as the area and route requests the features need: map tiles (OpenStreetMap), routing and search (Apple MapKit), weather (Open-Meteo), speed cameras and speed limits (OpenStreetMap Overpass), as listed in the privacy policy.
Background modes: "location" (keeps the dash live with the screen off) and "audio" (spoken turn-by-turn guidance with AVSpeechSynthesizer).

WI-FI (Hotspot Configuration and Wi-Fi Info entitlements)
In real use the app joins the bike's Wi-Fi with NEHotspotConfiguration, so the rider doesn't need Settings with gloves on, and reads the current SSID to confirm it is on the bike's network. Not needed in Demo mode. The bike's Wi-Fi has no internet; maps (OpenStreetMap), routing (Apple MapKit), weather (Open-Meteo) and speed cameras (OpenStreetMap) use cellular. Both networks at once are by design.

TESTFLIGHT / REVIEW BUILDS ONLY: Settings > Diagnostics > Export log
Shares the app's own log through the share sheet, only when the user taps it. Hidden in App Store downloads (StoreKit app-transaction environment check).

Privacy policy: https://tripperdash.kolaczek.cz/privacy.html
"Royal Enfield" and "Tripper" are trademarks of their owners. TripperDash++ is an independent app, not affiliated with Royal Enfield.
```
[3472 chars, field max 4000]

---

## Internal checklist (do NOT paste — for us)

- [ ] Confirm Settings actually has a visible "Demo mode" toggle with that exact label
- [ ] Confirm the CTA reads "Connect (demo)" in demo mode (PR #105 — merged)
- [ ] Screenshots taken in demo mode (no bike needed): home, map/search, active nav, settings
- [ ] Demo video (optional but strongly recommended for 2.5.4): 20–30s screen recording
      of demo-mode navigation, uploaded as review attachment or linked
- [ ] "Always" location purpose string reads clearly (Info.plist
      NSLocationAlwaysAndWhenInUseUsageDescription — verified present)
- [ ] Privacy nutrition label in ASC: Location → App Functionality, NOT linked to
      identity, NOT used for tracking (matches PrivacyInfo.xcprivacy)
