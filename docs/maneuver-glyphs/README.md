# Tripper Dash — Maneuver Glyph Catalog

Empirical glyph rendering for every byte value `0x00..0x81` of the
**maneuver TLV** sent to the Royal Enfield Tripper Dash (model "K1G",
bike: Guerrilla 450 / Himalayan 450).

The dashboard receives a single-byte maneuver code in the K1G TLV:

```
05 02 00 01 <maneuver_byte>           # primary form
05 03 00 02 <maneuver_byte> <unused>  # secondary form (observed)
```

This document is the ground truth for what each byte renders as in the
**active-nav bubble** (the round overlay shown over the map view when
turn-by-turn is active).

## Capture context

- **Date**: 2026-06-21
- **Source video**: `IMG_4587_2.mov` (1080p HEVC, 30 fps, 400 s, rotated +22° CW)
- **Capture method**: [`ManeuverScannerLoop`](../../TripperDashPP/Navigation/ManeuverScannerLoop.swift)
  walks `0x00..0xFF` with `holdSeconds=5`. The phone sends
  `primaryManeuver: byte` together with `roadName: "SCAN 0xNN"` for the
  **same** byte — see [`ManeuverScannerLoop.swift#sendNavPacket`](../../TripperDashPP/Navigation/ManeuverScannerLoop.swift#L183). The dash renders both: the active-nav bubble on
  the left, and the burned "SCAN 0xNN" label at the bottom. **The
  burned label is the authoritative ground truth.**
- **Coverage**: `0x00..0xFF` (full 8-bit range). Bytes `0x00..0x59` produce
  visible bubble glyphs (90 distinct entries captured). Bytes
  `0x5A..0xFF` are **hidden bubble** — overlay fully suppressed for
  every byte in range, field-verified byte-by-byte.
- **Extraction**: each glyph crop is **self-labeled** — the SCAN text under the
  bubble appears in every PNG so you can verify the byte → glyph mapping
  by eye without trusting any external mapping.

## Glyph index status

The catalog re-build on 2026-06-21 replaced the earlier timing-based
mapping (which was misaligned) with **OCR-anchored** mapping that reads
the burned SCAN label directly:

| Status | Count | Meaning |
|--------|-------|---------|
| ✅ **anchor** | ~55 | OCR of the SCAN label parsed cleanly — image and label match |
| 🟡 **interpolated** | ~32 | OCR missed in that frame, image picked by linear interp between neighbouring anchors — verify against the SCAN label visible inside the PNG |
| 📸 **user photo** | 4 | `0x00`, `0x01`, `0x03`, `0x04` captured directly from dash via phone photo (user-supplied, SCAN label visible) |
| ⚫ **hidden bubble** | 166 | `0x5A..0xFF` — dash renders nothing (overlay fully suppressed), field-verified byte-by-byte |

A glyph marked **interpolated** is still a real bubble frame from the
video — the OCR just couldn't read the label cleanly in that specific
frame. The SCAN label inside the PNG is the ground truth; if it doesn't
match the row's byte, the row is misaligned and needs re-extraction.

## Quick reference (user-confirmed; rest pending re-classification)

| Byte | Glyph | Description |
|------|-------|-------------|
| `0x00` | 📍↑ | **Arrival** — destination AHEAD (user-photo) |
| `0x01` | 📍↖ | **Arrival** — destination ahead-LEFT (user-photo) |
| `0x02` | 📍↗ | **Arrival** — destination ahead-RIGHT |
| `0x03` | ↗Y↑ | **Y-merge — joining from LEFT** (your road merges in from the left, user-confirmed) |
| `0x04` | ↖Y↑ | **Y-merge — joining from RIGHT** (your road merges in from the right, user-confirmed) |
| `0x05`..`0x06` | ↱Y / ↰Y | **Y-fork — stay RIGHT (0x05) / stay LEFT (0x06)** |
| `0x07`..`0x08` | ↑→ / ↑← | **Side-road branches off RIGHT (0x07) / LEFT (0x08)** (parallel road peels off) |
| `0x09` | ↑ | **Continue straight** |
| `0x0A`..`0x13` | ⟳0..⟳9 | **Roundabout CW** — exit numbers 0..9 (small style, field-confirmed) |
| `0x14`..`0x15` | ↰ / ↱ | **Turn LEFT / RIGHT** (90°) |
| `0x16`..`0x17` | ⤴ / ⤵ | **Sharp LEFT / RIGHT** (>90° hairpin) |
| `0x18`..`0x19` | ↖ / ↗ | **Slight LEFT / RIGHT** |
| `0x1A` / `0x3D` | ↻ / ↺ | **U-turn RIGHT (0x1A) / LEFT (0x3D)** (180°, user-confirmed pair) |
| `0x1B`, `0x1D`..`0x20` | Y↑ | **Y-fork — continue straight** (5 visual variants, no functional difference — user-confirmed) |
| `0x1C` | 🧭 | **Recalculating route** (spinning compass, user-confirmed) |
| `0x21`..`0x22` | ↗Y / ↖Y | **Y-merge** — joining from LEFT (0x21) / RIGHT (0x22), **visual duplicates of 0x03/0x04** (same maneuver, user-confirmed) |
| `0x23`..`0x24` | ┝↑ / ┥↑ | **Side-road joining from LEFT (0x23) / RIGHT (0x24)** — shallow angle, parallel road merges in |
| `0x25`..`0x26` | ┝↑ / ┥↑ | **Side-road joining from LEFT (0x25) / RIGHT (0x26)** — steeper angle than 0x23/0x24 |
| `0x27`..`0x28` | ↑↩exit / ↑↪exit | **Exit RIGHT (0x27) / LEFT (0x28)** — gentle ramp / smooth-curve sjezd off the main road |
| `0x29`..`0x2A` | ↑↘turn / ↑↙turn | **Turn-off RIGHT (0x29) / LEFT (0x2A)** — sharper, angular odbočka off the main road |
| `0x2D`..`0x2E` | ↑↗exit / ↑↖exit | **Slight exit RIGHT (0x2D) / LEFT (0x2E)** — gentle ramp |
| `0x2F`..`0x30` | ↑↘exit / ↑↙exit | **Exit RIGHT (0x2F) / LEFT (0x30)** — sharper, more angled break-off |
| `0x31`..`0x3A` | ⟳0..⟳9 | **Roundabout CW** — exit numbers 0..9 (large style, field-confirmed) |
| `0x3B` | ↑ | **Continue straight (long-distance)** |
| `0x3C` | 📍 | **Arrival pin** — destination marker only |
| `0x3E` | ⛴ | **Ferry crossing** |
| `0x3F` | 🚆 | **Train / level crossing** |
| `0x40` | 📍… | **Arrival approaching** (pin with dotted trail) |
| `0x42` | 📶 | **Signal / Wi-Fi indicator** (purpose unclear — info icon?) |
| `0x46`..`0x4F` | ⟳10..⟳19 | **Roundabout CW** — exit numbers 10..19 (field-confirmed) |
| `0x50`..`0x59` | ⟲10..⟲19 | **Roundabout CCW** — exit numbers 10..19 (left-hand-traffic style, field-confirmed) |
| `0x2B`, `0x2C`, `0x41`, `0x43`..`0x45` | ⚪ | **Empty bubble** — no glyph rendered (placeholders inside visible range) |
| `0x5A`..`0xFF` | ⚫ hidden | **Hidden bubble** — overlay fully suppressed (useful as "no maneuver" signal) |

> **Note**: descriptions for `0x05..0x59` were derived from visual
> inspection of the bubble glyph in each PNG (no SDK / firmware
> docs). Treat them as best-guess from the bubble shape — verify
> by sending the byte to the dash before relying on it in a route.

## How to send a custom maneuver

The dash will render any glyph code you send. From phone-side code:

```swift
// Send single primary maneuver:
await link.sendActiveNav(
    primaryManeuver: 0x33,                    // any byte 0x00..0x59 from catalog
    primaryDistanceMeters: 200,
    primaryUnit: 0x30,                         // 0x30 = metres
    totalDistanceMeters: 1200,
    totalDistanceUnit: 0x30,
    useCommaDecimal: false,
    decimalFmtOn: false,
    roadName: "Main St",
    eta: Date(timeIntervalSinceNow: 600),
    is24Hour: true,
    remainingSeconds: nil
)
```

Bytes in `0x5A..0xFF` suppress the active-nav overlay completely.
Use `0xFF` (or any byte in that range) as the canonical "no maneuver"
signal that hides the bubble without tearing down the route.

## Catalog (byte → glyph)

Each entry shows the bubble captured from the dash. The `100m` distance
under the symbol comes from a separate TLV (the K1G `05 02 / 05 03`
maneuver block) and is unrelated to the maneuver byte. Every captured
PNG includes the burned `SCAN 0xNN` label at the bottom for
self-verification.

Legend: ✅ = anchor (OCR-confirmed), 🟡 = interpolated, 🔄 = legacy.

| Byte | Source | Description | Image |
|------|--------|-------------|-------|
| `0x00` | 📸 user photo | **Arrival — destination AHEAD** (pin directly above straight arrow, end of route, user-confirmed) | ![0x00](glyphs/0x00.png) |
| `0x01` | 📸 user photo | **Arrival — destination ahead, slightly LEFT of route** (pin top-left + straight arrow, user-confirmed) | ![0x01](glyphs/0x01.png) |
| `0x02` | ✅ 📍↑→ | **Arrival — destination ahead-RIGHT** (mirror of 0x01: pin top-right + straight arrow) | ![0x02](glyphs/0x02.png) |
| `0x03` | 📸 user photo | **Y-merge — joining from LEFT** (your road comes in from the left, merges into the continuing road; user-confirmed) | ![0x03](glyphs/0x03.png) |
| `0x04` | 📸 user photo | **Y-merge — joining from RIGHT** (your road comes in from the right, merges into the continuing road; user-confirmed) | ![0x04](glyphs/0x04.png) |
| `0x05` | ✅ ↱Y | **Y-fork — stay RIGHT** (right leg highlighted; user-confirmed) | ![0x05](glyphs/0x05.png) |
| `0x06` | ✅ ↰Y | **Y-fork — stay LEFT** (variant; left leg highlighted) | ![0x06](glyphs/0x06.png) |
| `0x07` | ✅ ↑→ | **Side-road branches off RIGHT** (parallel road peels off to the right; user-confirmed) | ![0x07](glyphs/0x07.png) |
| `0x08` | ✅ ↑← | **Side-road branches off LEFT** (parallel road peels off to the left; user-confirmed) | ![0x08](glyphs/0x08.png) |
| `0x09` | 🟡 ↑ | **Continue straight** (straight arrow, no junction) | ![0x09](glyphs/0x09.png) |
| `0x0A` | ✅ ⟳0 | **Roundabout CW — exit 0** (entry indicator / no specific exit) | ![0x0A](glyphs/0x0A.png) |
| `0x0B` | ✅ ⟳1 | **Roundabout CW — take exit 1** | ![0x0B](glyphs/0x0B.png) |
| `0x0C` | 🟡 ⟳2 | **Roundabout CW — take exit 2** | ![0x0C](glyphs/0x0C.png) |
| `0x0D` | 🟡 ⟳3 | **Roundabout CW — take exit 3** | ![0x0D](glyphs/0x0D.png) |
| `0x0E` | ✅ ⟳4 | **Roundabout CW — take exit 4** | ![0x0E](glyphs/0x0E.png) |
| `0x0F` | ✅ ⟳5 | **Roundabout CW — take exit 5** | ![0x0F](glyphs/0x0F.png) |
| `0x10` | ✅ ⟳6 | **Roundabout CW — take exit 6** | ![0x10](glyphs/0x10.png) |
| `0x11` | 🟡 ⟳7 | **Roundabout CW — take exit 7** | ![0x11](glyphs/0x11.png) |
| `0x12` | ✅ ⟳8 | **Roundabout CW — take exit 8** | ![0x12](glyphs/0x12.png) |
| `0x13` | ✅ ⟳9 | **Roundabout CW — take exit 9** | ![0x13](glyphs/0x13.png) |
| `0x14` | ✅ ↰ | **Turn LEFT** (90° left, L-shape) | ![0x14](glyphs/0x14.png) |
| `0x15` | 🟡 ↱ | **Turn RIGHT** (90° right, L-shape, mirror of 0x14) | ![0x15](glyphs/0x15.png) |
| `0x16` | 🟡 ⤴ | **Sharp LEFT** (>90° hairpin to the left) | ![0x16](glyphs/0x16.png) |
| `0x17` | ✅ ⤵ | **Sharp RIGHT** (>90° hairpin to the right, mirror of 0x16) | ![0x17](glyphs/0x17.png) |
| `0x18` | ✅ ↖ | **Slight LEFT** (shallow left curve) | ![0x18](glyphs/0x18.png) |
| `0x19` | ✅ ↗ | **Slight RIGHT** (shallow right curve, mirror of 0x18) | ![0x19](glyphs/0x19.png) |
| `0x1A` | ✅ ↻ | **U-turn RIGHT** (180° via right side; user-confirmed) | ![0x1A](glyphs/0x1A.png) |
| `0x1B` | ✅ Y↑ | **Y-fork — continue straight** (centre arrow between legs; user-confirmed) | ![0x1B](glyphs/0x1B.png) |
| `0x1C` | ✅ 🧭 | **Recalculating** (spinning compass — shown while the route is being re-computed; user-confirmed) | ![0x1C](glyphs/0x1C.png) |
| `0x1D` | ✅ Y↑ | **Y-fork — continue straight** (visual variant; user says no functional difference vs 0x1B) | ![0x1D](glyphs/0x1D.png) |
| `0x1E` | ✅ Y↑ | **Y-fork — continue straight** (visual variant; user says no functional difference vs 0x1B) | ![0x1E](glyphs/0x1E.png) |
| `0x1F` | ✅ Y↑ | **Y-fork — continue straight** (visual variant; user says no functional difference vs 0x1B) | ![0x1F](glyphs/0x1F.png) |
| `0x20` | ✅ Y↑ | **Y-fork — continue straight** (visual variant; user says no functional difference vs 0x1B) | ![0x20](glyphs/0x20.png) |
| `0x21` | ✅ ↗Y↑ | **Y-merge — joining from LEFT** (visual duplicate of 0x03; same maneuver, user-confirmed) | ![0x21](glyphs/0x21.png) |
| `0x22` | ✅ ↖Y↑ | **Y-merge — joining from RIGHT** (visual duplicate of 0x04; same maneuver, user-confirmed) | ![0x22](glyphs/0x22.png) |
| `0x23` | ✅ ┝↑ | **Side-road joining from LEFT** (parallel road merges in from the left at a shallow angle; user-confirmed) | ![0x23](glyphs/0x23.png) |
| `0x24` | ✅ ┥↑ | **Side-road joining from RIGHT** (parallel road merges in from the right at a shallow angle; user-confirmed) | ![0x24](glyphs/0x24.png) |
| `0x25` | ✅ ┝↑ | **Side-road joining from LEFT** (steeper angle than 0x23; user-confirmed) | ![0x25](glyphs/0x25.png) |
| `0x26` | ✅ ┥↑ | **Side-road joining from RIGHT** (steeper angle than 0x24; user-confirmed) | ![0x26](glyphs/0x26.png) |
| `0x27` | ✅ ↑↩exit | **Exit RIGHT (gentle ramp)** — smooth curving sjezd off the main road to the right; user-confirmed | ![0x27](glyphs/0x27.png) |
| `0x28` | ✅ ↑↪exit | **Exit LEFT (gentle ramp)** — smooth curving sjezd off the main road to the left; user-confirmed | ![0x28](glyphs/0x28.png) |
| `0x29` | ✅ ↑↘turn | **Turn-off RIGHT (sharper)** — angular odbočka off the main road to the right; user-confirmed | ![0x29](glyphs/0x29.png) |
| `0x2A` | ✅ ↑↙turn | **Turn-off LEFT (sharper)** — angular odbočka off the main road to the left; user-confirmed | ![0x2A](glyphs/0x2A.png) |
| `0x2B` | ✅ ⚪ | **Empty bubble (no glyph rendered)** — likely placeholder/unused code | ![0x2B](glyphs/0x2B.png) |
| `0x2C` | ✅ ⚪ | **Empty bubble (no glyph rendered)** — likely placeholder/unused code | ![0x2C](glyphs/0x2C.png) |
| `0x2D` | ✅ ↑↗exit | **Slight exit RIGHT** (gentle ramp off the main road to the right; user-confirmed) | ![0x2D](glyphs/0x2D.png) |
| `0x2E` | ✅ ↑↖exit | **Slight exit LEFT** (gentle ramp off the main road to the left; user-confirmed) | ![0x2E](glyphs/0x2E.png) |
| `0x2F` | ✅ ↑↘exit | **Exit RIGHT (sharper)** (same idea as 0x2D but steeper, more angled break-off; user-confirmed) | ![0x2F](glyphs/0x2F.png) |
| `0x30` | ✅ ↑↙exit | **Exit LEFT (sharper)** (same idea as 0x2E but steeper, more angled break-off; user-confirmed) | ![0x30](glyphs/0x30.png) |
| `0x31` | ✅ ⟳0 | **Roundabout CW — exit 0** (large style; entry indicator) | ![0x31](glyphs/0x31.png) |
| `0x32` | 🟡 ⟳1 | **Roundabout CW — take exit 1** (large style) | ![0x32](glyphs/0x32.png) |
| `0x33` | 🟡 ⟳2 | **Roundabout CW — take exit 2** (large style) | ![0x33](glyphs/0x33.png) |
| `0x34` | 🟡 ⟳3 | **Roundabout CW — take exit 3** (large style) | ![0x34](glyphs/0x34.png) |
| `0x35` | 🟡 ⟳4 | **Roundabout CW — take exit 4** (large style) | ![0x35](glyphs/0x35.png) |
| `0x36` | 🟡 ⟳5 | **Roundabout CW — take exit 5** (large style) | ![0x36](glyphs/0x36.png) |
| `0x37` | 🟡 ⟳6 | **Roundabout CW — take exit 6** (large style) | ![0x37](glyphs/0x37.png) |
| `0x38` | 🟡 ⟳7 | **Roundabout CW — take exit 7** (large style) | ![0x38](glyphs/0x38.png) |
| `0x39` | ✅ ⟳8 | **Roundabout CW — take exit 8** (large style) | ![0x39](glyphs/0x39.png) |
| `0x3A` | ✅ ⟳9 | **Roundabout CW — take exit 9** (large style) | ![0x3A](glyphs/0x3A.png) |
| `0x3B` | ✅ ↑ | **Continue straight (long-distance)** (tall straight arrow) | ![0x3B](glyphs/0x3B.png) |
| `0x3C` | 🟡 📍 | **Arrival pin (destination marker only)** — no arrow | ![0x3C](glyphs/0x3C.png) |
| `0x3D` | ✅ ↺ | **U-turn LEFT** (180° via left side; user-confirmed — pairs with 0x1A=RIGHT) | ![0x3D](glyphs/0x3D.png) |
| `0x3E` | ✅ ⛴ | **Ferry crossing** — board ferry / waterway | ![0x3E](glyphs/0x3E.png) |
| `0x3F` | ✅ 🚆 | **Train / level crossing** — railway | ![0x3F](glyphs/0x3F.png) |
| `0x40` | ✅ 📍… | **Arrival approaching** (pin with dotted trail — destination near) | ![0x40](glyphs/0x40.png) |
| `0x41` | ✅ ⚪ | **Empty bubble (no glyph rendered)** — likely placeholder/unused code | ![0x41](glyphs/0x41.png) |
| `0x42` | ✅ 📶 | **Signal / Wi-Fi-style indicator** — purpose unclear (info icon? GPS-signal state?) | ![0x42](glyphs/0x42.png) |
| `0x43` | ✅ ⚪ | **Empty bubble (no glyph rendered)** — likely placeholder/unused code | ![0x43](glyphs/0x43.png) |
| `0x44` | ✅ ⚪ | **Empty bubble (no glyph rendered)** — likely placeholder/unused code | ![0x44](glyphs/0x44.png) |
| `0x45` | ✅ ⚪ | **Empty bubble (no glyph rendered)** — likely placeholder/unused code | ![0x45](glyphs/0x45.png) |
| `0x46` | 🟡 ⟳10 | **Roundabout CW — take exit 10** | ![0x46](glyphs/0x46.png) |
| `0x47` | ✅ ⟳11 | **Roundabout CW — take exit 11** | ![0x47](glyphs/0x47.png) |
| `0x48` | ✅ ⟳12 | **Roundabout CW — take exit 12** | ![0x48](glyphs/0x48.png) |
| `0x49` | ✅ ⟳13 | **Roundabout CW — take exit 13** | ![0x49](glyphs/0x49.png) |
| `0x4A` | ✅ ⟳14 | **Roundabout CW — take exit 14** | ![0x4A](glyphs/0x4A.png) |
| `0x4B` | ✅ ⟳15 | **Roundabout CW — take exit 15** | ![0x4B](glyphs/0x4B.png) |
| `0x4C` | ✅ ⟳16 | **Roundabout CW — take exit 16** | ![0x4C](glyphs/0x4C.png) |
| `0x4D` | 🟡 ⟳17 | **Roundabout CW — take exit 17** | ![0x4D](glyphs/0x4D.png) |
| `0x4E` | 🟡 ⟳18 | **Roundabout CW — take exit 18** | ![0x4E](glyphs/0x4E.png) |
| `0x4F` | ✅ ⟳19 | **Roundabout CW — take exit 19** | ![0x4F](glyphs/0x4F.png) |
| `0x50` | ✅ ⟲10 | **Roundabout CCW — take exit 10** (counter-clockwise / left-hand-traffic style) | ![0x50](glyphs/0x50.png) |
| `0x51` | ✅ ⟲11 | **Roundabout CCW — take exit 11** | ![0x51](glyphs/0x51.png) |
| `0x52` | ✅ ⟲12 | **Roundabout CCW — take exit 12** | ![0x52](glyphs/0x52.png) |
| `0x53` | ✅ ⟲13 | **Roundabout CCW — take exit 13** | ![0x53](glyphs/0x53.png) |
| `0x54` | ✅ ⟲14 | **Roundabout CCW — take exit 14** | ![0x54](glyphs/0x54.png) |
| `0x55` | ✅ ⟲15 | **Roundabout CCW — take exit 15** | ![0x55](glyphs/0x55.png) |
| `0x56` | 🟡 ⟲16 | **Roundabout CCW — take exit 16** | ![0x56](glyphs/0x56.png) |
| `0x57` | 🟡 ⟲17 | **Roundabout CCW — take exit 17** | ![0x57](glyphs/0x57.png) |
| `0x58` | ✅ ⟲18 | **Roundabout CCW — take exit 18** | ![0x58](glyphs/0x58.png) |
| `0x59` | ✅ ⟲19 | **Roundabout CCW — take exit 19** | ![0x59](glyphs/0x59.png) |
| `0x5A`..`0xFF` | ⚫ hidden | **Hidden bubble** — overlay fully suppressed (every byte in range, field-verified) | — |

## How to regenerate

```bash
# 1. Run scanner mode on phone via ManeuverScannerLoop with holdSeconds=5.
# 2. Mount Tripper, ride briefly, switch to "Active Nav (Scan)" mode.
# 3. Record video of the dash (selfie stick + 1080p phone camera works
#    better than the in-app UDP recorder for visual clarity).
# 4. Crop video to dash + rotate so the SCAN text is horizontal:

ffmpeg -i SCAN_VIDEO.mov \
  -vf "rotate=22*PI/180:ow=rotw(22*PI/180):oh=roth(22*PI/180):c=black,fps=0.5" \
  -q:v 3 frames/f_%03d.jpg

# 5. Extract bubble + SCAN label region for each frame (self-labeling):
#    crop = (100, 460, 470, 830)  →  370×370 px
#    bubble visible at top, "100 m" beneath, "SCAN 0xNN" along the bottom.

# 6. OCR the SCAN label to get the ground-truth byte for each frame,
#    then map first-occurrence frame → byte for the catalog file name.

# 7. For bytes without an OCR anchor, linearly interpolate between
#    neighbouring anchors and flag the entry as 🟡 interpolated.

# 8. Verify each glyph by reading the SCAN label inside the PNG itself.
```

## Open questions / pending work

- [ ] **Re-verify roundabout-exit numbering**: ~~catalog assigns CW
      exits 0..9 to `0x0A..0x13` (small style) and `0x31..0x3A`
      (large style), CW exits 10..19 to `0x46..0x4F`, CCW exits 10..19
      to `0x50..0x59`.~~ **User-confirmed in field 6/2026** — all
      roundabout ranges render the correct exit number.
- [ ] **CCW exits 0..9** are not present in `0x00..0x59` (only CCW
      10..19 at `0x50..0x59`). The dash likely re-uses CW glyphs
      for low-numbered CCW exits, but this is unconfirmed.
- [ ] **Confirm `0x3E` (ferry) and `0x3F` (train)**: visually distinct
      from the turn/roundabout family but unconfirmed by field use.
- [ ] **Identify `0x42`**: looks like a signal-strength / Wi-Fi icon,
      not a navigation maneuver — may be a status indicator that
      leaked into the maneuver enum, or a "no GPS" warning glyph.
- [ ] **Direction-bit hypothesis** (was raised under earlier mapping):
      whether bits 7..4 control rotation direction for roundabouts —
      drop and re-derive after re-classification
- [ ] **Non-visual side effects in `0x5A..0xFF`**: bubble is suppressed,
      but does any byte in that range still trigger non-visual effects
      (beep, text bar, vibration)? — needs separate test

## See also

- [`ManeuverScannerLoop.swift`](../../TripperDashPP/Navigation/ManeuverScannerLoop.swift) — Scanner implementation (walks `0x00..0xFF`, burns `SCAN 0xNN` label into the video stream)
- [`ManeuverScanSource.swift`](../../TripperDashPP/Stream/ManeuverScanSource.swift) — Video overlay that burns the ground-truth label
- [`ManeuverIcon.swift`](../../TripperDashPP/Navigation/Models/ManeuverIcon.swift) — Asset-free glyph renderer for the phone-side burned arrow (used when the dash enum is untrusted)
- [Overview grid (90 visible glyphs captured)](all-glyphs-overview.jpg)
