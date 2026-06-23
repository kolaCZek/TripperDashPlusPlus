"""
Python mirror of `TripperDashPP/Navigation/Models/RoundaboutInstructionParser.swift`.

Same exit-noun-anchored strategy + word-ordinal table as the Swift
parser. Used by `tests/test_roundabout_parser.py` to drive a shared
fixture set through both parsers and assert they agree, so the iOS and
tooling sides can't drift apart silently.

If you change either side, mirror the change here (and vice versa).

History: the original parser grabbed the FIRST digit anywhere in the
string, so "Na 3. kruhovém objezdu vyjeďte 1. výjezdem" (3rd roundabout,
take 1st exit) parsed as exit 3 → byte 0x0D → dash showed "3" in the
circle when the rider needed exit 1 (0x0B). The fix anchors the digit to
the exit noun, which always sits right after the ordinal in every Apple
Maps locale.
"""

from __future__ import annotations

import re

# Spelled-out ordinals (lowercased) per exit number. One entry per
# number; each value lists every CZ/EN/SK/DE/PL form we recognise.
# Keep this in sync with `wordOrdinals` in the Swift parser.
WORD_ORDINALS: dict[int, list[str]] = {
    1: ["first", "1st",
        "první", "prvním",
        "prvý", "prvým",
        "erste", "ersten",
        "pierwszy", "pierwszym"],
    2: ["second", "2nd",
        "druhý", "druhým",
        "zweite", "zweiten",
        "drugi", "drugim"],
    3: ["third", "3rd",
        "třetí", "třetím",
        "tretí", "tretím",
        "dritte", "dritten",
        "trzeci", "trzecim"],
    4: ["fourth", "4th",
        "čtvrtý", "čtvrtým",
        "štvrtý", "štvrtým",
        "vierte", "vierten",
        "czwarty", "czwartym"],
    5: ["fifth", "5th",
        "pátý", "pátým",
        "piaty", "piatym",
        "fünfte", "fünften",
        "piąty", "piątym"],
    6: ["sixth", "6th",
        "šestý", "šestým",
        "siedme",
        "sechste", "sechsten",
        "szósty", "szóstym"],
    7: ["seventh", "7th",
        "sedmý", "sedmým",
        "siedmy", "siedmym",
        "siebte", "siebten",
        "siódmy", "siódmym"],
    8: ["eighth", "8th",
        "osmý", "osmým",
        "ôsmy", "ôsmym",
        "achte", "achten",
        "ósmy", "ósmym"],
    9: ["ninth", "9th",
        "devátý", "devátým",
        "deviaty", "deviatym",
        "neunte", "neunten",
        "dziewiąty", "dziewiątym"],
    10: ["tenth", "10th",
         "desátý", "desátým",
         "desiaty", "desiatym",
         "zehnte", "zehnten",
         "dziesiąty", "dziesiątym"],
}

# Exit-noun alternation, per locale. Must match the Swift `exitNoun`
# literal byte-for-byte (the sync test asserts it). The ordinal that
# names the exit ALWAYS sits immediately before this noun.
EXIT_NOUN = r"(?:exits?|v[ýy]jezd\w*|v[ýy]jazd\w*|ausfahrt\w*|zjazd\w*|sortie\w*|uscita\w*)"

# Digit immediately before the exit noun. Must match the Swift
# `digitBeforeExitRegex` pattern byte-for-byte.
_DIGIT_BEFORE_EXIT = re.compile(
    r"(\d{1,2})(?:-?(?:st|nd|rd|th))?\.?\s*" + EXIT_NOUN + r"\b",
    flags=re.IGNORECASE | re.UNICODE,
)
_HAS_EXIT_NOUN = re.compile(EXIT_NOUN + r"\b", flags=re.IGNORECASE | re.UNICODE)
_BARE_NUMBER = re.compile(r"^\s*(\d{1,2})\s*$")


def parse_exit_number(instructions: str) -> int | None:
    """
    Extract exit number from an instructions string.

    Strategy (order matters):
      1. Digit anchored to the exit noun — covers ~every real Apple Maps
         emission, immune to road numbers / "Nth roundabout" prefixes.
      2. Spelled-out ordinal within a couple words of the exit noun.
      3. Bare number, ONLY when there is no exit noun at all.

    Returns int in [1, 20] if a recognisable ordinal is present, else
    None (caller falls back to exit 0 = generic glyph).
    """
    lowered = instructions.lower()

    # 1. Digit anchored to the exit noun.
    m = _DIGIT_BEFORE_EXIT.search(lowered)
    if m:
        n = int(m.group(1))
        if 1 <= n <= 20:
            return n

    has_exit_noun = _HAS_EXIT_NOUN.search(lowered) is not None

    # 2. Spelled-out ordinal near the exit noun.
    if has_exit_noun:
        for n in sorted(WORD_ORDINALS.keys()):
            for form in WORD_ORDINALS[n]:
                pattern = (
                    r"\b" + re.escape(form) + r"\b\s*(?:\w+\s+){0,2}?"
                    + EXIT_NOUN + r"\b"
                )
                if re.search(pattern, lowered, flags=re.UNICODE):
                    return n
        # Exit noun present but no parseable ordinal → generic glyph.
        return None

    # 3. Bare number only (no exit noun anywhere).
    m = _BARE_NUMBER.match(lowered)
    if m:
        n = int(m.group(1))
        if 1 <= n <= 20:
            return n

    return None
