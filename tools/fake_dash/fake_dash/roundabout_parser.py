"""
Python mirror of `TripperDashPP/Navigation/Models/RoundaboutInstructionParser.swift`.

Same regex + word-ordinal table as the Swift parser. Used by
`tests/test_roundabout_parser.py` to drive a shared fixture set
through both parsers and assert they agree, so the iOS and tooling
sides can't drift apart silently.

If you change either side, mirror the change here (and vice versa).
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

# Digit-form regex — must match the Swift `digitOrdinalRegex` byte for
# byte. Matches "2", "2.", "2nd", "2-nd", "2.výjezdem" and captures the
# digits in group 1.
_DIGIT_RE = re.compile(
    r"\b(\d{1,2})(?:-?(?:st|nd|rd|th))?\.?(?=\s|\b|$)",
    flags=re.IGNORECASE | re.UNICODE,
)


def parse_exit_number(instructions: str) -> int | None:
    """
    Extract exit number from an instructions string.

    Returns int in [1, 20] if a recognisable ordinal is present, else
    None (caller should fall back to exit 0 = generic glyph).
    """
    lowered = instructions.lower()

    # Digit form (covers almost every Apple Maps emission).
    m = _DIGIT_RE.search(lowered)
    if m:
        n = int(m.group(1))
        if 1 <= n <= 20:
            return n

    # Word form fallback. Iterate by number so behaviour is deterministic.
    for n in sorted(WORD_ORDINALS.keys()):
        for form in WORD_ORDINALS[n]:
            if re.search(rf"\b{re.escape(form)}\b", lowered, flags=re.UNICODE):
                return n

    return None
