"""
Dash-frame overlays stay on screen and don't overlap each other.

The weather pill and the notice card grew (bigger, heavier font) to survive
the 512 kbps stream. This ports their layout math from `MapViewSource.swift`
(constants parsed from the source, so a retune is checked too) and asserts,
for every combination of overlays that can be on screen together, that each
rect is inside the 526x300 frame and the pill / card intersect nothing.

Text widths can't be measured here (no UIFont), so both use their width-fit
MAXIMUM — the worst case. Real labels are about half of that.
"""
from __future__ import annotations

import itertools
import pathlib
import re

from tests.swift_source import decl_body, strip_comments

SRC = (pathlib.Path(__file__).resolve().parents[3]
       / "TripperDashPP" / "Map" / "MapViewSource.swift").read_text()
W, H = 526, 300


def const(name: str) -> float:
    return float(re.search(rf"static let {name}(?:: CGFloat)? = ([0-9.]+)", SRC).group(1))


def local(fn: str, name: str) -> float:
    body = strip_comments(decl_body(SRC, fn))
    return float(re.search(rf"(?:let|var) {name}: CGFloat = ([0-9.]+)", body).group(1))


PILL = "fileprivate func drawWeatherAlert(into ctx: CGContext)"
CARD = "fileprivate func drawNotice(into ctx: CGContext)"
BAR = "fileprivate func drawProgressBar(into ctx: CGContext)"

SIGN_D, SIGN_M = const("speedLimitSignDiameter"), const("speedLimitSignMargin")
BAR_L = const("progressBarLeftInset")
assert re.search(r"static let overlayLeftClearance: CGFloat = progressBarLeftInset", SRC)
LEFT_CLEAR = BAR_L
SEC_W, SEC_H = (float(v) for v in re.search(
    r"sectionPanelSize = CGSize\(width: ([0-9.]+), height: ([0-9.]+)\)", SRC).groups())
SEC_GAP = const("sectionPanelGap")
BAR_H, BAR_BM = const("progressBarHeight"), const("progressBarBottomMargin")
BAR_R = const("progressBarRightInset")
MARK_HH = const("progressMarkerHalfHeight")
MARK_W = local(BAR, "arrowW")
BAR_ZONE = BAR_BM + BAR_H / 2 + MARK_HH + 1


def overlaps(a, b) -> bool:
    return a[0] < b[2] and b[0] < a[2] and a[1] < b[3] and b[1] < a[3]


def on_screen(r) -> bool:
    return 0 <= r[0] and 0 <= r[1] and r[2] <= W and r[3] <= H


def rects(sign: bool, section: bool, bar: bool, notice: bool) -> dict:
    out = {}
    # Zoom OSD disc, bottom-left (r = 15, centre r + 10 from the edges).
    out["zoom_osd"] = (10, H - 40, 40, H - 10)
    # The dash burns its own turn card into the left third (the zone
    # `progressBarLeftInset` keeps the bar out of), full height.
    out["dash_turn_card"] = (0, 0, BAR_L, H)
    sign_top = H - SIGN_M - SIGN_D
    if sign:
        out["sign"] = (W - SIGN_M - SIGN_D, sign_top, W - SIGN_M, H - SIGN_M)
    if section:
        x = W - SIGN_M - SIGN_D - SEC_GAP - SEC_W
        out["section"] = (x, sign_top - 2, x + SEC_W, sign_top - 2 + SEC_H)
    if bar:
        cy = H - BAR_BM - BAR_H / 2
        out["bar"] = (BAR_L - MARK_W - 1, cy - MARK_HH - 1, W - BAR_R + MARK_W + 1, cy + MARK_HH + 1)

    # Weather pill at its width-fit maximum.
    m, pill_h = local(PILL, "margin"), local(PILL, "pillH")
    sign_bump = SIGN_D + 8 if (sign or section) else 0
    bar_bump = BAR_ZONE + 4 - m if bar else 0
    y = H - m - pill_h - max(sign_bump, bar_bump)
    out["pill"] = (LEFT_CLEAR, y, W - m, y + pill_h)

    if notice:
        pad_y, glyph = local(CARD, "padY"), local(CARD, "glyphSize")
        font, cm = local(CARD, "fontSize"), local(CARD, "margin")
        card_h = pad_y + max(glyph, font) + pad_y
        cy0 = (H - card_h) / 2 - 4
        out["notice"] = (LEFT_CLEAR, cy0, W - cm, cy0 + card_h)
    return out


def test_layout_math_matches_source():
    pill = strip_comments(decl_body(SRC, PILL))
    assert "max(signBump, barBump)" in pill
    assert "Self.progressBarZoneHeight + 4 - margin" in pill
    assert "frameSize.width - margin - Self.overlayLeftClearance" in pill
    card = strip_comments(decl_body(SRC, CARD))
    assert "(frameSize.height - cardH) / 2 - 4" in card
    assert "let freeMinX = Self.overlayLeftClearance" in card
    assert "let freeW = frameSize.width - margin - freeMinX" in card
    assert "let maxTextW = freeW - (padX + glyphSize + gap + padX)" in card
    assert "let originX = freeMinX + (freeW - cardW) / 2" in card
    assert "progressBarBottomMargin + progressBarHeight / 2 + progressMarkerHalfHeight + 1" in SRC


def test_overlays_on_screen_and_not_overlapping():
    for combo in itertools.product([False, True], repeat=4):
        r = rects(*combo)
        for name, rect in r.items():
            assert on_screen(rect), (combo, name, rect)
        # Fixed overlays that never move must not overlap each other either.
        assert not overlaps(r["zoom_osd"], r.get("bar", (0, 0, 0, 0)))
        for mover in ("pill", "notice"):
            if mover not in r:
                continue
            for other, rect in r.items():
                if other != mover:
                    assert not overlaps(r[mover], rect), (combo, mover, other, r[mover], rect)


def test_overlay_text_is_bigger_and_heavier():
    assert local(PILL, "fontSize") >= 20
    assert local(CARD, "fontSize") >= 24
    assert "overlayTextWeight: UIFont.Weight = .heavy" in SRC
    # Measured with the weight drawText draws, or the clip eats a glyph.
    for fn in (PILL, CARD):
        assert "weight: Self.overlayTextWeight" in decl_body(SRC, fn)
    assert "weight: overlayTextWeight" in decl_body(SRC, "private static func drawText(")
