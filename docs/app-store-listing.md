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

```
Your Royal Enfield's Tripper Dash has a real colour screen and a hardware video
decoder. TripperDash++ finally puts a proper moving map on it.

Plan a route on your phone, drop it in your pocket, and ride. The dash shows a
full-colour map that follows you, the route line, the next turn and how far it
is — and it keeps updating with your phone locked and the screen off.

WHAT YOU GET ON THE DASH

• A real moving map, heading-up, in full colour — not a lone arrow
• The next-turn glyph and distance, drawn from a field-verified catalogue of
  every symbol the dash can render
• Your whole route at a glance, with progress along it
• A posted speed-limit sign for the road you're actually on
• A weather heads-up that looks down the route ahead, not just overhead —
  "Rain 15 km" is worth knowing before you're in it
• Speed-camera marks where the map data has them
• Incoming-call cards and live phone status, mirrored like the factory app
• Day and night map palettes, switching automatically at sunset

ON THE PHONE

• Search a destination, pick from favourites, or drop a pin on the map
• Compare alternative routes before you commit
• Import a GPX and ride it — prune and reorder points first if you like
• Save routes you ride often
• Optional spoken turn-by-turn in 8 languages, fully offline, ducking your
  music instead of cutting it
• A trip computer that runs off the GPS the map is already using: distance,
  moving time, average and top speed, elevation gained

BUILT FOR ACTUALLY RIDING

The dash buttons zoom the map and skip music tracks, so your hands stay where
they belong. Reconnects are handled quietly — take a call, stop for fuel, and
the stream comes back on its own. There are no accounts, no logins and no
subscriptions, and nothing about your ride is uploaded to a server: the map is
rendered on your phone and sent straight to the bike over its own Wi-Fi.

WORKS WITH

The large, map-capable Tripper Dash fitted to the Royal Enfield Himalayan 450,
Guerrilla 450 and Bear 650. Developed and field-tested on a Guerrilla 450.

It does NOT work with the small arrow-only Tripper Navigation Pod on the
Meteor 350, Classic 350, Hunter 350, Shotgun 650 or Super Meteor 650 — that is
different hardware speaking a different protocol.

TRYING IT WITHOUT THE BIKE

Turn on Demo Mode in Settings and the whole app runs on the phone alone, dash
preview included. Handy before your first ride.

A NOTE ON BATTERY AND DATA

Streaming a live map is real work: expect meaningful battery use on a long
ride, and keep the phone charging if you can. Map tiles and routing come over
cellular; the bike's Wi-Fi carries only the video and has no internet of its
own.

TripperDash++ is an independent app. It is not affiliated with, endorsed by, or
sponsored by Royal Enfield or Eicher Motors. "Royal Enfield" and "Tripper" are
the trademarks of their respective owners and are used here only to say which
hardware this app works with.

Ride safe. Look at the dash, not the phone.
```
[2988]

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

For the first public release:

```
First public release.

Stream a full-colour turn-by-turn map from your phone to the Royal Enfield
Tripper Dash, with the phone locked in your pocket. Route search, GPX import,
saved routes, offline voice guidance, weather along the route, posted speed
limits and a GPS trip computer.

Field-tested on a Guerrilla 450.
```

---

## Screenshots

Required: 6.9" (iPhone 17 Pro Max or similar). Everything else can be
auto-scaled by App Store Connect from that one size.

Capture all of these in Demo Mode — no motorcycle needed:

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
