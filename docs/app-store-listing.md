# App Store Connect — store listing copy

Paste-ready metadata for the public App Store release. Character limits are
Apple's; the counts in brackets are what the text below actually uses.

---

## App Name (30 chars max)

```
TripperDash++
```
[13] — matches the TestFlight/GitHub name. Keep it; a rename would orphan the
existing testers and every doc/link that points at the project.

## Subtitle (30 chars max)

```
Full-map nav for your Tripper
```
[29] — says what it does and for whom, without repeating the app name.

## Promotional Text (170 chars, editable without a new build)

```
Now with a steadier turn-by-turn bubble and a crash fix when re-planning a route. Ride, lock your phone, and let the dash do the talking.
```
[137] — this field can be changed any time without review, so use it for
"what's new right now" instead of burying it in the description.

## Keywords (100 chars max, comma-separated, NO spaces after commas)

```
motorcycle,navigation,royal enfield,himalayan,guerrilla,tft,dash,gps,turn by turn,offline,gpx,moto
```
[98]

Notes:
- Do NOT repeat the app name or subtitle words — Apple already indexes those,
  so repeating them wastes the budget.
- "royal enfield" is descriptive-use here (the hardware the app talks to), the
  same way case makers list phone models. Keep the unaffiliated disclaimer in
  the description.
- Singular/plural both match automatically; no need for "motorcycles".

## Category

- **Primary:** Navigation
- **Secondary:** Travel

## Age Rating

4+ — no objectionable content. Answer "None" to every content question.
The one to think about: the questionnaire asks about unrestricted web access
(no — the app has no browser) and user-generated content (no).

## Support URL

```
https://tripperdash.kolaczek.cz/
```

## Marketing URL (optional)

```
https://github.com/kolaCZek/TripperDashPlusPlus
```

## Privacy Policy URL

```
https://tripperdash.kolaczek.cz/privacy.html
```

## Copyright

```
2026 Martin Kolací
```

---

## Description (4000 chars max)

As live for 1.0.5 (the copy in App Store Connect is the source of truth;
update this block when it changes).

```
TripperDash++ streams a live turn-by-turn navigation map to your Royal Enfield Tripper TFT dash.

Your bike's Tripper display was built for the official app's basic arrow-and-distance navigation. TripperDash++ replaces that with a full moving map - the same view you'd get from a dedicated GPS unit - rendered on your phone and streamed to the dash over the bike's built-in Wi-Fi.

Plan a route, drop your phone in your pocket, and ride. The dash shows a heading-up map with your route, the next maneuver, distance to the turn, road names, ETA, and progress - all while your phone stays locked.

What you get on the dash:
• Full moving map, heading-up, with your route drawn in
• Next-maneuver glyph, distance-to-turn, and road names, plus a turn arrow drawn right on the route line
• Live ETA and remaining-distance progress
• Alternative routes with their time difference, shown where they split off
• Posted speed-limit sign for the road you're on
• Speed cameras on the map, plus your average speed and distance left inside average-speed sections
• Weather ahead along your route, not just overhead: rain, snow, ice, frost risk, storms, gusts, crosswind and fog, with how far away they are
• Incoming-call card and phone battery, like the factory app
• Light / Dark / Auto map themes (Auto follows local sunrise & sunset)
• Dash buttons zoom the map and skip music tracks

On your phone:
• Search and route with Apple Maps directions, or share a place straight from Google Maps or Apple Maps
• Multi-stop route planning, saved routes, and favorites - add, remove or reorder stops mid-ride without stopping
• Off the route, rerouting picks a road that carries on in your direction of travel
• Import GPX routes, and export your rides as GPX
• Ride history: every ride of the last 30 days, with its map and stats
• Optional auto-reroute when traffic makes a faster route worth it
• Spoken turn-by-turn and speed-camera alerts in 8 languages, offline, over the locked screen
• Trip computer: distance, moving time, average and top speed, elevation gained
• Next turn and ETA on your Lock Screen and in the Dynamic Island
• Quick Ride home-screen widget: one tap to ride Home, to Work, a free ride, or to the nearest fuel station
• Shortcuts and Siri: start a free ride, navigate to a favorite, a saved route or a place, check your ride status, or stop the ride - hands-free

Built to respect you and your bike:
• No account, no sign-up, no tracking, no ads
• Nothing about your rides is uploaded to us - routing is Apple Maps, maps are OpenStreetMap, and everything stays on your device
• Runs with the screen locked and the phone in your pocket, on "Always" or "While Using" location

TripperDash++ connects to your bike's Wi-Fi automatically, rides out short Wi-Fi blips, reconnects on its own after a call or a fuel stop, and gets you moving in seconds. Set up a Shortcuts automation and the free ride starts the moment your phone joins the bike. Want to try it first? Demo Mode in Settings runs the whole app without the bike.

Map tiles, routing and weather use your cellular data; the bike's Wi-Fi carries only the video. Streaming a live map uses noticeable battery on a long ride - keep the phone charging if you can.

Requires a Royal Enfield motorcycle with the round, map-capable Tripper Dash (Bear 650, Guerrilla 450 or Himalayan 450). Not compatible with the small arrow-only Tripper Navigation Pod.

TripperDash++ is an independent app, not affiliated with or endorsed by Royal Enfield. "Royal Enfield" and "Tripper" are trademarks of their respective owners.
```
[3574]

Why it is shaped this way:
- The first two lines are what shows before "more" — they carry the whole
  pitch on their own.
- Compatibility sits high, and the incompatible-pod warning is explicit,
  because that is the #1 source of 1-star "doesn't work" reviews for
  accessory apps.
- Battery and cellular use are stated plainly. Riders discovering this
  themselves after a long day write angry reviews; being told up front turns
  it into an informed choice.
- The trademark disclaimer is verbatim in the listing, not just in review
  notes, so it is visible to anyone who wonders.

---

## What's New (release notes, 4000 chars)

Version 1.0.5:

```
New in 1.0.5:

• Quick Ride widget - one tap on your Home Screen to ride Home, to Work, a free ride, or to the nearest fuel station.
• Shortcuts and Siri - start a free ride, navigate to a favorite, a saved route or a place, check your ride status, or stop the ride, hands-free. Tip: a Shortcuts automation can start the free ride the moment your phone joins the bike's Wi-Fi.
• Turn arrow on the route - the next turn is drawn right on the route line on the dash, easy to read at any zoom.
• Smarter rerouting - off the route, the new route now carries on in your direction of travel instead of sending you back the way you came.

Fixes:
• A stop removed from the dash menu disappears at once, and the route is recalculated from where you are.
• A route shared from Google Maps no longer shows a stale pin on its first stop.
• A saved route's map preview updates when you edit its points.
• Short Wi-Fi blips between the phone and the dash no longer drop the connection.
• The second turn on the dash (look-ahead) now shows reliably.
```
[1034]

First public release (1.0.4) used a short "First public release" note.
List user-visible changes only; skip fixes nobody can see.

---

## Screenshots

### Technical requirements (verified July 2026)

The project is `TARGETED_DEVICE_FAMILY = 1` (iPhone only), so **one iPhone set
is all that is needed** — no iPad shelf.

- **Size:** one iPhone set, portrait. The live listing's screenshot slot is
  the **6.5"** set, which accepts only **1242×2688** or **1284×2778** (App
  Store Connect rejected a 1320×2868 file there in November 2026 with "File
  dimensions are invalid"). A 6.9" set (1320×2868, 1290×2796 or 1260×2736)
  is a separate slot. Check which slot you are uploading to.
- **Count:** minimum 3, maximum 10 per shelf.
- **Format:** sRGB PNG or JPEG, **no transparency** (an alpha channel is
  rejected).
- **Exact pixels:** the parser is strict — 1320×2867 fails. Take them on a
  real 6.9" device or the matching simulator, do not resize by hand.
- Screenshots must show the actual app. Device frames, marketing text and
  background colour are allowed as long as real app UI is underneath.

Simplest capture path: run the app in a simulator whose screen matches the
slot (e.g. iPhone 17 Pro Max for 6.9" at 1320×2868), via Device → Screenshot
or `xcrun simctl io booted screenshot shot.png`, which saves with no alpha.
For the 6.5" slot, render or scale to exactly 1284×2778 (or 1242×2688).

### Product page header and search results art

Optional custom art (Apple's asset best practices), RGB with no alpha:
- **Product page header:** 3840×1646; keep the key content in the centred
  1646×661 art safe area.
- **Search results:** 3840×2560 (1920×1280 minimum, 3:2); keep the key content
  in the centred 2168×1030 art safe area.

### What to capture

All of these work in Demo Mode — no motorcycle needed:

1. **Active navigation, dash preview visible** — the money shot. Shows the
   phone and what the dash is getting at the same time.
2. **The dash frame itself, full-bleed** — moving map, route line, turn glyph
   and distance. This is the product.
3. **Route preview with alternatives** — ETA bubbles on each option.
4. **Destination search / favourites** — shows it is a normal, usable nav app.
5. **GPX import or saved routes** — the feature no stock app has.
6. **Trip computer after a ride** — distance, moving time, speeds, elevation.

Add a one-line caption burned into each image. Most people scroll the strip
and never read the description.

Order matters: 1 and 2 are what nearly everyone sees.

---

## App Preview video (optional, strongly recommended)

15–30 s, portrait, captured in Demo Mode. Suggested beat sheet:

1. (0–3 s) Destination search, tap Go
2. (3–8 s) Route preview with alternatives
3. (8–20 s) Navigation running, dash preview updating, a turn approaching and
   the glyph changing
4. (20–25 s) Phone screen locks — dash preview keeps going. This is the whole
   selling point and no still screenshot can convey it.
5. (25–30 s) Trip summary

Doubles as the 2.5.4 background-location evidence for App Review, so it earns
its keep twice.
