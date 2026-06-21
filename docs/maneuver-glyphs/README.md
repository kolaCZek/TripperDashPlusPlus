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
  `0x5A..0x81` render the bubble background but **no symbol** (empty
  bubble, field-verified byte-by-byte). Bytes `0x82..0xFF` are
  **hidden bubble** — overlay fully suppressed.
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
| 📸 **user photo** | 3 | `0x00`, `0x01`, `0x04` captured directly from dash via phone photo (user-supplied, SCAN label visible) |
| ⚪ **empty bubble** | 40 | `0x5A..0x81` — dash draws the bubble shell but renders no symbol inside, field-verified byte-by-byte |
| ⚫ **hidden bubble** | 126 | `0x82..0xFF` — dash renders nothing (overlay fully suppressed), field-verified byte-by-byte |

A glyph marked **interpolated** is still a real bubble frame from the
video — the OCR just couldn't read the label cleanly in that specific
frame. The SCAN label inside the PNG is the ground truth; if it doesn't
match the row's byte, the row is misaligned and needs re-extraction.

## Quick reference (user-confirmed; rest pending re-classification)

| Byte | Glyph | Description |
|------|-------|-------------|
| `0x00` | 📍↑ | **Arrival — destination AHEAD** (pin directly above straight arrow, user-photo) |
| `0x01` | 📍↑ ← | **Arrival — destination ahead-LEFT** (pin top-left + straight arrow, user-photo) |
| `0x02` | 📍AHEAD-variant | (similar to 0x01, pin position differs) — **pending re-classify** |
| `0x03` | ⤵ | **Y-fork up — stay LEFT** (thicker left leg, user-confirmed in earlier scan) — re-verify against scan2 |
| `0x04` | T+📍 | **Arrival at T-junction — destination ahead-LEFT** (T-shape with red pin top-left, user-photo) |
| `0x05`..`0x59` | various | Captured but **not yet labelled** — see catalog below |
| `0x5A`..`0x81` | ⚪ empty | **Empty bubble** — bubble drawn but no symbol inside (field-verified) |
| `0x82`..`0xFF` | ⚫ hidden | **No bubble rendered** — overlay fully suppressed (useful as "no maneuver" signal) |

> **Important**: the earlier text descriptions for `0x05..0x81` were
> derived from a misaligned mapping and have been removed. Re-labeling
> proceeds row-by-row from the actual glyph in each PNG.

## How to send a custom maneuver

The dash will render any glyph code you send. From phone-side code:

```swift
// Send single primary maneuver:
await link.sendActiveNav(
    primaryManeuver: 0x33,                    // any byte 0x00..0x81 from catalog
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

Bytes in `0x5A..0x81` draw the bubble shell but leave it empty (no
arrow/pin/symbol inside). Bytes in `0x82..0xFF` suppress the overlay
completely. For a true "no maneuver" signal pick any byte from the
hidden range (`0xFF` is the canonical choice); for "maneuver active
but symbol unknown" the empty-bubble range may be useful as a
placeholder that still keeps the active-nav layout visible.

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
| `0x02` | ✅ | TBD — pending classification | ![0x02](glyphs/0x02.png) |
| `0x03` | ✅ | TBD — pending classification | ![0x03](glyphs/0x03.png) |
| `0x04` | 📸 user photo | **Arrival at T-junction — destination ahead-LEFT of the T** (thick vertical shaft branching left+right, red pin top-left above the split, user-confirmed) | ![0x04](glyphs/0x04.png) |
| `0x05` | 🟡 | TBD | ![0x05](glyphs/0x05.png) |
| `0x06` | ✅ | TBD | ![0x06](glyphs/0x06.png) |
| `0x07` | ✅ | TBD | ![0x07](glyphs/0x07.png) |
| `0x08` | ✅ | TBD | ![0x08](glyphs/0x08.png) |
| `0x09` | 🟡 | TBD | ![0x09](glyphs/0x09.png) |
| `0x0A` | ✅ | TBD | ![0x0A](glyphs/0x0A.png) |
| `0x0B` | ✅ | TBD | ![0x0B](glyphs/0x0B.png) |
| `0x0C` | 🟡 | TBD | ![0x0C](glyphs/0x0C.png) |
| `0x0D` | 🟡 | TBD | ![0x0D](glyphs/0x0D.png) |
| `0x0E` | ✅ | TBD | ![0x0E](glyphs/0x0E.png) |
| `0x0F` | ✅ | TBD | ![0x0F](glyphs/0x0F.png) |
| `0x10` | ✅ | TBD | ![0x10](glyphs/0x10.png) |
| `0x11` | 🟡 | TBD | ![0x11](glyphs/0x11.png) |
| `0x12` | ✅ | TBD | ![0x12](glyphs/0x12.png) |
| `0x13` | ✅ | TBD | ![0x13](glyphs/0x13.png) |
| `0x14` | ✅ | TBD | ![0x14](glyphs/0x14.png) |
| `0x15` | 🟡 | TBD | ![0x15](glyphs/0x15.png) |
| `0x16` | 🟡 | TBD | ![0x16](glyphs/0x16.png) |
| `0x17` | ✅ | TBD | ![0x17](glyphs/0x17.png) |
| `0x18` | ✅ | TBD | ![0x18](glyphs/0x18.png) |
| `0x19` | ✅ | TBD | ![0x19](glyphs/0x19.png) |
| `0x1A` | 🟡 | TBD | ![0x1A](glyphs/0x1A.png) |
| `0x1B` | ✅ | TBD | ![0x1B](glyphs/0x1B.png) |
| `0x1C` | ✅ | TBD | ![0x1C](glyphs/0x1C.png) |
| `0x1D` | 🟡 | TBD | ![0x1D](glyphs/0x1D.png) |
| `0x1E` | 🟡 | TBD | ![0x1E](glyphs/0x1E.png) |
| `0x1F` | ✅ | TBD | ![0x1F](glyphs/0x1F.png) |
| `0x20` | ✅ | TBD | ![0x20](glyphs/0x20.png) |
| `0x21` | ✅ | TBD | ![0x21](glyphs/0x21.png) |
| `0x22` | 🟡 | TBD | ![0x22](glyphs/0x22.png) |
| `0x23` | ✅ | TBD | ![0x23](glyphs/0x23.png) |
| `0x24` | ✅ | TBD | ![0x24](glyphs/0x24.png) |
| `0x25` | ✅ | TBD | ![0x25](glyphs/0x25.png) |
| `0x26` | 🟡 | TBD | ![0x26](glyphs/0x26.png) |
| `0x27` | 🟡 | TBD | ![0x27](glyphs/0x27.png) |
| `0x28` | ✅ | TBD | ![0x28](glyphs/0x28.png) |
| `0x29` | ✅ | TBD | ![0x29](glyphs/0x29.png) |
| `0x2A` | ✅ | TBD | ![0x2A](glyphs/0x2A.png) |
| `0x2B` | ✅ | TBD | ![0x2B](glyphs/0x2B.png) |
| `0x2C` | ✅ | TBD | ![0x2C](glyphs/0x2C.png) |
| `0x2D` | ✅ | TBD | ![0x2D](glyphs/0x2D.png) |
| `0x2E` | ✅ | TBD | ![0x2E](glyphs/0x2E.png) |
| `0x2F` | 🟡 | TBD | ![0x2F](glyphs/0x2F.png) |
| `0x30` | ✅ | TBD | ![0x30](glyphs/0x30.png) |
| `0x31` | ✅ | TBD | ![0x31](glyphs/0x31.png) |
| `0x32` | 🟡 | TBD | ![0x32](glyphs/0x32.png) |
| `0x33` | 🟡 | TBD | ![0x33](glyphs/0x33.png) |
| `0x34` | 🟡 | TBD | ![0x34](glyphs/0x34.png) |
| `0x35` | 🟡 | TBD | ![0x35](glyphs/0x35.png) |
| `0x36` | 🟡 | TBD | ![0x36](glyphs/0x36.png) |
| `0x37` | 🟡 | TBD | ![0x37](glyphs/0x37.png) |
| `0x38` | 🟡 | TBD | ![0x38](glyphs/0x38.png) |
| `0x39` | ✅ | TBD | ![0x39](glyphs/0x39.png) |
| `0x3A` | ✅ | TBD | ![0x3A](glyphs/0x3A.png) |
| `0x3B` | ✅ | TBD | ![0x3B](glyphs/0x3B.png) |
| `0x3C` | 🟡 | TBD | ![0x3C](glyphs/0x3C.png) |
| `0x3D` | 🟡 | TBD | ![0x3D](glyphs/0x3D.png) |
| `0x3E` | ✅ | TBD | ![0x3E](glyphs/0x3E.png) |
| `0x3F` | ✅ | TBD | ![0x3F](glyphs/0x3F.png) |
| `0x40` | ✅ | TBD | ![0x40](glyphs/0x40.png) |
| `0x41` | ✅ | TBD | ![0x41](glyphs/0x41.png) |
| `0x42` | ✅ | TBD | ![0x42](glyphs/0x42.png) |
| `0x43` | ✅ | TBD | ![0x43](glyphs/0x43.png) |
| `0x44` | ✅ | TBD | ![0x44](glyphs/0x44.png) |
| `0x45` | ✅ | TBD | ![0x45](glyphs/0x45.png) |
| `0x46` | 🟡 | TBD | ![0x46](glyphs/0x46.png) |
| `0x47` | ✅ | TBD | ![0x47](glyphs/0x47.png) |
| `0x48` | ✅ | TBD | ![0x48](glyphs/0x48.png) |
| `0x49` | ✅ | TBD | ![0x49](glyphs/0x49.png) |
| `0x4A` | ✅ | TBD | ![0x4A](glyphs/0x4A.png) |
| `0x4B` | ✅ | TBD | ![0x4B](glyphs/0x4B.png) |
| `0x4C` | ✅ | TBD | ![0x4C](glyphs/0x4C.png) |
| `0x4D` | 🟡 | TBD | ![0x4D](glyphs/0x4D.png) |
| `0x4E` | 🟡 | TBD | ![0x4E](glyphs/0x4E.png) |
| `0x4F` | ✅ | TBD | ![0x4F](glyphs/0x4F.png) |
| `0x50` | ✅ | TBD | ![0x50](glyphs/0x50.png) |
| `0x51` | ✅ | TBD | ![0x51](glyphs/0x51.png) |
| `0x52` | ✅ | TBD | ![0x52](glyphs/0x52.png) |
| `0x53` | ✅ | TBD | ![0x53](glyphs/0x53.png) |
| `0x54` | ✅ | TBD | ![0x54](glyphs/0x54.png) |
| `0x55` | ✅ | TBD | ![0x55](glyphs/0x55.png) |
| `0x56` | 🟡 | TBD | ![0x56](glyphs/0x56.png) |
| `0x57` | 🟡 | TBD | ![0x57](glyphs/0x57.png) |
| `0x58` | ✅ | TBD | ![0x58](glyphs/0x58.png) |
| `0x59` | ✅ | TBD | ![0x59](glyphs/0x59.png) |
| `0x5A`..`0x81` | ⚪ empty bubble | **Empty bubble — no glyph rendered** (bubble background drawn, no arrow/pin/symbol inside; SCAN label confirms byte) — field-verified for every byte in range | — |
| `0x82`..`0xFF` | ⚫ hidden | **Hidden bubble** — overlay fully suppressed (every byte in range, field-verified) | — |

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

- [ ] **Re-classify `0x02..0x59`**: row-by-row labelling based on the
      self-labeled glyph image; the earlier text descriptions were
      derived from misaligned timing-based mapping and have been removed
- [ ] **Re-verify `0x03`**: legacy "Y-fork stay-left" label was derived
      under the old (misaligned) mapping — verify against scan2 frame
      and against a controlled field run on a real fork (0x04 was
      already re-classified as a T-junction arrival, not a Y-fork)
- [ ] **Direction-bit hypothesis** (was raised under earlier mapping):
      whether bits 7..4 control rotation direction for roundabouts —
      drop and re-derive after re-classification
- [ ] **Non-visual side effects in `0x5A..0x81` and `0x82..0xFF`**:
      empty-bubble and hidden-bubble ranges suppress the symbol /
      overlay respectively, but does any byte in those ranges still
      trigger non-visual effects (beep, text bar, vibration)? — needs
      separate test

## See also

- [`ManeuverScannerLoop.swift`](../../TripperDashPP/Navigation/ManeuverScannerLoop.swift) — Scanner implementation (walks `0x00..0xFF`, burns `SCAN 0xNN` label into the video stream)
- [`ManeuverScanSource.swift`](../../TripperDashPP/Stream/ManeuverScanSource.swift) — Video overlay that burns the ground-truth label
- [`ManeuverIcon.swift`](../../TripperDashPP/Navigation/Models/ManeuverIcon.swift) — Asset-free glyph renderer for the phone-side burned arrow (used when the dash enum is untrusted)
- [Overview grid (90 visible glyphs captured)](all-glyphs-overview.jpg)
