# App Store Review Notes — TripperDash++

Paste the section below into **App Store Connect → App Review Information → Notes**.
Keep it tight; reviewers skim. The demo path is what lets them test without the
motorcycle, and the background-location justification is what clears Guideline 2.5.4.

---

## REVIEW NOTES (paste this)

TripperDash++ streams a live turn-by-turn navigation map to the TFT display of a
Royal Enfield motorcycle over the bike's Wi-Fi. Because reviewers won't have the
motorcycle, the app ships with a built-in DEMO MODE that exercises every screen and
the full navigation pipeline with no hardware required.

### How to test without the motorcycle (Demo Mode)

1. Launch the app. On the home screen, tap the gear icon (top-right) to open
   Settings. In the "Bikes" section, enable the "Demo mode" toggle.
2. The bottom button now reads "Connect (demo)". Tap it — the app simulates a
   connected dash (no real Wi-Fi/socket needed) and shows the streamed map preview
   in-app.
3. Pick any destination (search or tap the map) and start navigation, or use
   "Free ride (map only)". You will see the same 526×300 map that would be sent to
   the dash, with route line, heading, ETA, speed limits and voice guidance.
4. Everything works on a plain iPhone with no accessory. No pairing, no account,
   no login.

There is no demo account because the app has NO accounts and NO login of any kind.

### Why the app requests "Always" location (Guideline 2.5.4)

The core function is to keep the navigation map updating ON THE MOTORCYCLE DASH
while the phone is locked and in a pocket or tank bag during the ride. To keep the
map/route current with the screen off, the app needs background location.

- Background location is used ONLY to render and stream the navigation map (place
  the bike on the map, advance the route, update the dash frame).
- It is NOT used for advertising, analytics, profiling, or any secondary purpose.
- Nothing is uploaded to a server we operate — there is no backend. Location stays
  on the device and is sent only to the bike's local dash over Wi-Fi.
- The "Always" prompt copy and the in-app onboarding both explain this to the user.

The app declares the `location` and `audio` background modes:
- `location` — the wakelock that keeps the map/dash live with the screen off.
- `audio` — real spoken turn-by-turn voice guidance (AVSpeechSynthesizer). This is
  a genuine audio feature, not a keep-alive trick.

### Wi-Fi auto-join (Hotspot Configuration entitlement)

In real use the app offers to join the motorcycle's Wi-Fi access point
(NEHotspotConfiguration) so the rider doesn't fumble with Settings with gloves on.
This needs no interaction in Demo Mode. The entitlement is
`com.apple.developer.networking.HotspotConfiguration`.

### Networking / keyless design

Map tiles come from OpenStreetMap, routing/search from Apple MapKit, weather from
Open-Meteo, speed cameras from OpenStreetMap Overpass — all keyless, over cellular.
The Wi-Fi link to the bike (192.168.1.1) carries only the rendered video; it has no
internet. Two simultaneous networks (cellular + bike Wi-Fi) are by design.

### Privacy policy

https://privacy.kolaczek.cz/tripperdash/

### Trademark note

"Royal Enfield" and "Tripper" are trademarks of their owners. TripperDash++ is an
independent, unaffiliated third-party app. This is stated in the app and on the
privacy page.

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
