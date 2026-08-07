"""
Mirror + drift guards for `String.dashSafe` (String+DashSafe.swift).

The Tripper dash font is ASCII-only: Czech place names with diacritics
either render as mojibake ("Nižbor") or make the firmware drop the whole
text field ("Okoř", "Křivoklát", "Zvoleněves"). `dashSafe` folds every
on-dash string to plain 7-bit ASCII. This test pins the fold table with a
Python mirror and asserts the Swift source still applies it at both dash
output points (the road-name TLV and the video overlay's drawText).

Rider field report (Martin, 8/2026): on a
Zvoleněves→Okoř→Nižbor→Křivoklát→Zvoleněves loop only "Nižbor" showed a
next-waypoint ETA, and with broken diacritics. Folding fixes both: the
name is dropped-field's root cause AND the mojibake.
"""

from __future__ import annotations

import unicodedata
from pathlib import Path


# --------------------------------------------------------------------------
# Mirror of String.dashSafe
# --------------------------------------------------------------------------

_PUNCT = {
    "…": "...",
    "–": "-", "—": "-", "―": "-",
    "’": "'", "‘": "'", "‚": "'",
    "“": '"', "”": '"', "„": '"',
    "•": "*", "·": "-", "×": "x",
    "ß": "ss", "æ": "ae", "Æ": "AE", "ø": "o", "Ø": "O", "œ": "oe", "Œ": "OE",
    "°": " deg", "€": "EUR", "£": "GBP", "©": "(c)",
    "\u00a0": " ",
}


def dash_safe(s: str) -> str:
    # 1. Punctuation map.
    mapped = "".join(_PUNCT.get(ch, ch) for ch in s)
    # 2. Diacritic fold (NFD then drop combining marks == folding
    #    diacriticInsensitive for Latin scripts).
    decomposed = unicodedata.normalize("NFD", mapped)
    folded = "".join(ch for ch in decomposed if not unicodedata.combining(ch))
    # 3. Drop non-printable-ASCII; tabs/newlines → space.
    out_chars = []
    for ch in folded:
        o = ord(ch)
        if o in (0x09, 0x0A, 0x0D):
            out_chars.append(" ")
        elif 0x20 <= o <= 0x7E:
            out_chars.append(ch)
        else:
            out_chars.append(" ")
    # 4. Collapse whitespace runs and trim.
    return " ".join("".join(out_chars).split())


class TestDashSafeFold:
    def test_light_diacritic_nizbor(self):
        assert dash_safe("Nižbor") == "Nizbor"

    def test_heavy_diacritics_dropped_field_names(self):
        # The names that vanished on the real dash — all fold cleanly.
        assert dash_safe("Okoř") == "Okor"
        assert dash_safe("Křivoklát") == "Krivoklat"
        assert dash_safe("Zvoleněves") == "Zvoleneves"

    def test_ascii_passthrough(self):
        # Distances/times/labels already ASCII must be untouched.
        for s in ("15 min to Slany", "1h 23m", "0 min", "N of M", "12.3 km"):
            assert dash_safe(s) == s

    def test_full_label_with_diacritic_name(self):
        # The whole "<time> to <name>" template stays intact, name folded.
        assert dash_safe("15 min to Křivoklát") == "15 min to Krivoklat"

    def test_typographic_punctuation_mapped(self):
        assert dash_safe("A…B") == "A...B"
        assert dash_safe("l’Est") == "l'Est"
        assert dash_safe("A–B") == "A-B"

    def test_degree_and_symbols(self):
        assert dash_safe("20°C") == "20 degC"

    def test_whitespace_collapsed_after_drops(self):
        # A dropped emoji between words shouldn't leave a double space.
        assert dash_safe("A 🚧 B") == "A B"

    def test_german_and_other_latin(self):
        assert dash_safe("Grüße") == "Grusse"
        assert dash_safe("Málaga") == "Malaga"


# --------------------------------------------------------------------------
# Drift guards — the fold must be applied at BOTH dash output points
# --------------------------------------------------------------------------


def _repo_root() -> Path:
    return Path(__file__).resolve().parents[3]


def _read(rel: str) -> str:
    return (_repo_root() / rel).read_text(encoding="utf-8")


class TestSwiftDriftGuard:
    def test_helper_exists(self):
        src = _read("TripperDashPP/Tripper/String+DashSafe.swift")
        assert "var dashSafe: String" in src
        assert "diacriticInsensitive" in src

    def test_road_name_tlv_folds(self):
        src = _read("TripperDashPP/Tripper/K1GPacket.swift")
        assert "name.dashSafe.utf8" in src, (
            "tlvRoadName must fold to ASCII before the 60-byte wire cut"
        )

    def test_overlay_draw_text_folds(self):
        src = _read("TripperDashPP/Map/MapViewSource.swift")
        assert "text.dashSafe" in src, (
            "drawText must fold to ASCII before Core Text lays out the glyphs"
        )
