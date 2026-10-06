"""
Dash-frame overlays stay on the dash's round glass, off its turn card, and
off each other.

The geometry is measured on the real dash (docs/dash-visible-area.md): the
glass shows a circle of the 526x300 frame, and while navigating the dash
draws its own turn card as a disc over the bottom-left. This ports the
layout math of the fixed overlays from `MapViewSource.swift` (constants
parsed from the source, so a retune is checked too) and asserts, for every
combination of overlays that can be on screen together and every text
width up to past the width-fit cap, that:

- every overlay is inside the visible circle with `overlayClearance` to
  spare (corners included),
- nothing reaches into the turn card (plus clearance),
- the weather pill, notice card and zoom OSD overlap nothing else,
  including the heading puck (the pill stays beside it, never above it:
  that's the route ahead; a long label switches to a short hazard name).

Text widths can't be measured here (no UIFont), so the widths are swept.
"""
from __future__ import annotations

import functools
import itertools
import math
import pathlib
import re

from tests.swift_source import decl_body, strip_comments

ROOT = pathlib.Path(__file__).resolve().parents[3]
SRC = (ROOT / "TripperDashPP" / "Map" / "MapViewSource.swift").read_text()
DOC = (ROOT / "docs" / "dash-visible-area.md").read_text()
W, H = 526, 300


def const(name: str) -> float:
    return float(re.search(rf"static let {name}(?:: CGFloat)? = ([0-9.]+)", SRC).group(1))


def point(name: str) -> tuple[float, float]:
    m = re.search(rf"static let {name} = CGPoint\(x: ([0-9.]+), y: ([0-9.]+)\)", SRC)
    return float(m.group(1)), float(m.group(2))


@functools.cache
def local(fn: str, name: str) -> float:
    body = strip_comments(decl_body(SRC, fn))
    return float(re.search(rf"(?:let|var) {name}: CGFloat = ([0-9.]+)", body).group(1))


def ivar(name: str) -> float:
    return float(re.search(rf"private let {name}: CGFloat = ([0-9.]+)", SRC).group(1))


PILL = "fileprivate func drawWeatherAlert(into ctx: CGContext)"
CARD = "fileprivate func drawNotice(into ctx: CGContext)"
BAR = "fileprivate func drawProgressBar(into ctx: CGContext)"
ZOOM = "private func drawZoomOsd(into ctx: CGContext)"

VIS_C, VIS_R = point("visibleCenter"), const("visibleRadius")
NAV_C, NAV_R = point("navCardCenter"), const("navCardRadius")
CLEAR = const("overlayClearance")
NAV_MAX_X = NAV_C[0] + NAV_R + CLEAR
SIGN_D, SIGN_M = const("speedLimitSignDiameter"), const("speedLimitSignMargin")
SEC_W, SEC_H = (float(v) for v in re.search(
    r"sectionPanelSize = CGSize\(width: ([0-9.]+), height: ([0-9.]+)\)", SRC).groups())
SEC_GAP = const("sectionPanelGap")
BAR_L, BAR_R = const("progressBarLeftInset"), const("progressBarRightInset")
BAR_H, BAR_BM = const("progressBarHeight"), const("progressBarBottomMargin")
MARK_HH = const("progressMarkerHalfHeight")
MARK_W = local(BAR, "arrowW")
BAR_ZONE = BAR_BM + BAR_H / 2 + MARK_HH + 1
PILL_H = const("weatherPillHeight")
PUCK_R = 14 * ivar("puckScale")
PUCK_C = (W / 2, H / 2 + H * ivar("forwardBiasFraction"))
PUCK = (PUCK_C[0] - PUCK_R, PUCK_C[1] - PUCK_R, PUCK_C[0] + PUCK_R, PUCK_C[1] + PUCK_R)


def visible_span(y0: float, y1: float) -> tuple[float, float]:
    dy = max(abs(y0 - VIS_C[1]), abs(y1 - VIS_C[1]))
    r = VIS_R - CLEAR
    half = math.sqrt(max(0.0, r * r - dy * dy))
    return VIS_C[0] - half, VIS_C[0] + half


def overlaps(a, b) -> bool:
    return a[0] < b[2] and b[0] < a[2] and a[1] < b[3] and b[1] < a[3]


def on_glass(r) -> bool:
    """All four corners inside the visible circle minus the clearance."""
    return all(math.hypot(x - VIS_C[0], y - VIS_C[1]) <= VIS_R - CLEAR + 1e-6
               for x in (r[0], r[2]) for y in (r[1], r[3]))


def off_nav_card(r, disc: bool = False) -> bool:
    if disc:    # the zoom OSD is a disc: centre distance, not its box corner
        cx, cy, rr = (r[0] + r[2]) / 2, (r[1] + r[3]) / 2, (r[2] - r[0]) / 2
        return math.hypot(cx - NAV_C[0], cy - NAV_C[1]) >= NAV_R + CLEAR + rr - 1e-6
    px = min(max(NAV_C[0], r[0]), r[2])
    py = min(max(NAV_C[1], r[1]), r[3])
    return math.hypot(px - NAV_C[0], py - NAV_C[1]) >= NAV_R + CLEAR - 1e-6


def pill_room(sign: bool, section: bool, bar: bool):
    """(rect without the text, text room) for the weather pill."""
    m = local(PILL, "margin")
    chrome = 2 * local(PILL, "padX") + local(PILL, "glyphSize") + local(PILL, "gap")
    sign_bump = SIGN_D + 8 if (sign or section) else 0
    bar_bump = BAR_ZONE + 4 - m if bar else 0
    y = H - m - PILL_H - max(sign_bump, bar_bump)
    max_x = min(W - m, visible_span(y, y + PILL_H)[1])
    beside = y + PILL_H > PUCK[1] - CLEAR and y < PUCK[3] + CLEAR
    min_x = PUCK[2] + CLEAR if beside else NAV_MAX_X
    return chrome, y, max_x, max_x - min_x - chrome


def pill_rect(sign: bool, section: bool, bar: bool, text_w: float):
    chrome, y, max_x, room = pill_room(sign, section, bar)
    text_w = min(text_w, room)
    return (max_x - chrome - text_w, y, max_x, y + PILL_H)


def notice_rect(text_w: float):
    pad_x, pad_y = local(CARD, "padX"), local(CARD, "padY")
    glyph, gap, font = local(CARD, "glyphSize"), local(CARD, "gap"), local(CARD, "fontSize")
    card_h = pad_y + max(glyph, font) + pad_y
    y = NAV_C[1] - NAV_R - CLEAR - card_h
    lo, hi = visible_span(y, y + card_h)
    text_w = min(text_w, hi - lo - (2 * pad_x + glyph + gap))
    w = 2 * pad_x + glyph + gap + text_w
    x = VIS_C[0] - w / 2
    return (x, y, x + w, y + card_h)


def zoom_rect():
    r = local(ZOOM, "r")
    cy = H - BAR_ZONE - CLEAR - r
    reach = NAV_R + CLEAR + r
    cx = NAV_C[0] + math.sqrt(reach * reach - (cy - NAV_C[1]) ** 2)
    return (cx - r, cy - r, cx + r, cy + r)


def rects(sign, section, bar, notice, pill_w, notice_w) -> dict:
    out = {"zoom_osd": zoom_rect(), "puck": PUCK}
    sign_top = H - SIGN_M - SIGN_D
    if sign:
        out["sign"] = (W - SIGN_M - SIGN_D, sign_top, W - SIGN_M, H - SIGN_M)
    if section:
        x = W - SIGN_M - SIGN_D - SEC_GAP - SEC_W
        out["section"] = (x, sign_top - 2, x + SEC_W, sign_top - 2 + SEC_H)
    if bar:
        cy = H - BAR_BM - BAR_H / 2
        out["bar"] = (BAR_L - MARK_W - 1, cy - MARK_HH - 1, W - BAR_R + MARK_W + 1, cy + MARK_HH + 1)
    out["pill"] = pill_rect(sign, section, bar, pill_w)
    if notice:
        out["notice"] = notice_rect(notice_w)
    return out


PILL_WIDTHS = range(20, 420, 5)      # real labels ~110-230 px at 20 pt
NOTICE_WIDTHS = range(40, 520, 20)


def test_geometry_matches_measured_doc():
    assert "centre (262, 263), radius 264" in DOC
    assert "centre (79, 228), radius 68" in DOC
    assert VIS_C == (262, 263) and VIS_R == 264
    assert NAV_C == (79, 228) and NAV_R == 68
    assert CLEAR >= 4   # doc: keep 4 px off both


def test_layout_math_matches_source():
    pill = strip_comments(decl_body(SRC, PILL))
    assert "max(signBump, barBump)" in pill
    assert "Self.progressBarZoneHeight + 4 - margin" in pill
    assert "Self.visibleSpan(minY: originY, maxY: originY + pillH).upperBound" in pill
    assert "let originY = frameSize.height - margin - pillH - max(signBump, barBump)" in pill
    assert "originY + pillH > puck.minY - Self.overlayClearance" in pill
    assert "&& originY < puck.maxY + Self.overlayClearance" in pill
    assert ("let minX = besidePuck ? puck.maxX + Self.overlayClearance"
            " : Self.navCardClearMaxX") in pill
    assert "let maxTextW = maxX - minX - chromeW" in pill
    assert "label = Self.weatherShortTitle(alert.title) + distText" in pill
    assert "fontSize *= maxTextW / textW" in pill
    # Short name first, font shrink only after it.
    assert pill.index("weatherShortTitle(") < pill.index("fontSize *= maxTextW / textW")
    assert "let pill = CGRect(x: maxX - pillW, y: originY, width: pillW, height: pillH)" in pill
    card = strip_comments(decl_body(SRC, CARD))
    assert ("let originY = Self.navCardCenter.y - Self.navCardRadius"
            " - Self.overlayClearance - cardH") in card
    assert "let span = Self.visibleSpan(minY: originY, maxY: originY + cardH)" in card
    assert ("let maxTextW = span.upperBound - span.lowerBound"
            " - (padX + glyphSize + gap + padX)") in card
    assert "fontSize *= maxTextW / textW" in card
    assert "let originX = Self.visibleCenter.x - cardW / 2" in card
    zoom = strip_comments(decl_body(SRC, ZOOM))
    assert ("let cy = frameSize.height - Self.progressBarZoneHeight"
            " - Self.overlayClearance - r") in zoom
    assert "let reach = Self.navCardRadius + Self.overlayClearance + r" in zoom
    assert "let dy = cy - Self.navCardCenter.y" in zoom
    assert "let cx = Self.navCardCenter.x + (reach * reach - dy * dy).squareRoot()" in zoom
    assert "let r = 14 * puckScale" in SRC
    assert "let cy = frameSize.height / 2 + frameSize.height * forwardBiasFraction" in SRC
    span = strip_comments(decl_body(SRC, "fileprivate static func visibleSpan("))
    assert "max(abs(minY - visibleCenter.y), abs(maxY - visibleCenter.y))" in span
    assert "let r = visibleRadius - overlayClearance" in span
    assert "progressBarBottomMargin + progressBarHeight / 2 + progressMarkerHalfHeight + 1" in SRC


def test_overlays_on_glass_off_card_and_not_overlapping():
    for combo in itertools.product([False, True], repeat=4):
        for pw in PILL_WIDTHS:
            for nw in (NOTICE_WIDTHS if combo[3] else [0]):
                r = rects(*combo, pw, nw)
                for name, rect in r.items():
                    assert on_glass(rect), (combo, pw, nw, name, rect)
                    assert off_nav_card(rect, name == "zoom_osd"), (combo, pw, nw, name, rect)
                for mover in ("pill", "notice", "zoom_osd"):
                    if mover not in r:
                        continue
                    for other, rect in r.items():
                        if other != mover:
                            assert not overlaps(r[mover], rect), (combo, pw, nw, mover, other)


TITLES = re.findall(r'WeatherAlert\(title: "([^"]+)"', (
    ROOT / "TripperDashPP" / "RideAlerts" / "WeatherAlertService.swift").read_text())


def short_title(title: str) -> str:
    body = strip_comments(decl_body(SRC, "fileprivate static func weatherShortTitle("))
    for case, short in re.findall(r'case ([^:]+): return "([^"]+)"', body):
        if title in re.findall(r'"([^"]+)"', case):
            return short
    return title


def test_every_long_title_has_a_short_name():
    assert len(set(TITLES)) >= 12
    for t in set(TITLES):
        assert short_title(t) in {"Rain", "Snow", "Wind", "Fog", "Frost", "Ice", "Storm"}, t


def test_short_weather_labels_keep_full_size():
    # The pill never sits over the route ahead: it stays beside the puck.
    # The widest short label, "Storm 100 km", is ~158 px at 20 pt in DejaVu
    # Sans Bold (a stand-in that runs wider than SF Heavy); every short
    # label must fit there at full size in every sign / section / bar combo.
    for sign, section, bar in itertools.product([False, True], repeat=3):
        _, y, _, room = pill_room(sign, section, bar)
        assert y + PILL_H > PUCK[1] - CLEAR, "pill expected beside the puck"
        assert room >= 158, (sign, section, bar, room)


def test_overlay_text_is_bigger_and_heavier():
    assert local(PILL, "fontSize") >= 20
    assert local(CARD, "fontSize") >= 24
    assert "overlayTextWeight: UIFont.Weight = .heavy" in SRC
    # Measured with the weight drawText draws, or the clip eats a glyph.
    for fn in (PILL, CARD):
        assert "weight: Self.overlayTextWeight" in decl_body(SRC, fn)
    assert "weight: overlayTextWeight" in decl_body(SRC, "private static func drawText(")
