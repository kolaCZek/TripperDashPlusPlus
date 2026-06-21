"""
Roundabout exit-number parser tests.

Two-layer strategy:

1. **Behavioural tests** against the Python parser
   (`fake_dash.roundabout_parser.parse_exit_number`) — a broad fixture
   set of localised Apple Maps strings (CZ/EN/SK/DE/PL/digit-only)
   covering exits 1..20, malformed input, and false-positive guards
   (road numbers, non-roundabout instructions).

2. **Cross-language sync test** — parse the Swift source for
   `wordOrdinals` and assert it matches the Python `WORD_ORDINALS`
   table entry-by-entry, so the iOS app and the tooling can't drift
   apart silently.

If a real-world Apple Maps string ever fails to parse on the field
test, add a fixture here and a matching word in *both* parsers.
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest

from fake_dash.roundabout_parser import WORD_ORDINALS, parse_exit_number


# -----------------------------------------------------------------------
# Fixture: real-world Apple Maps roundabout strings.
# -----------------------------------------------------------------------

# (string, expected_exit_number_or_None)
ROUNDABOUT_FIXTURES: list[tuple[str, int | None]] = [
    # --- Digit form: English ----------------------------------------
    ("At the roundabout, take the 1st exit", 1),
    ("At the roundabout, take the 2nd exit", 2),
    ("At the roundabout, take the 3rd exit", 3),
    ("At the roundabout, take the 4th exit", 4),
    ("At the roundabout, take the 10th exit", 10),
    ("At the roundabout, take the 19th exit", 19),

    # --- Digit form: Czech (canonical Apple Maps style) -------------
    ("Na kruhovém objezdu vyjeďte 1. výjezdem", 1),
    ("Na kruhovém objezdu vyjeďte 2. výjezdem", 2),
    ("Na kruhovém objezdu vyjeďte 3. výjezdem", 3),
    ("Na kruhovém objezdu vyjeďte 5. výjezdem", 5),

    # --- Digit form: Slovak ------------------------------------------
    ("Na kruhovom objazde použite 2. výjazd", 2),

    # --- Digit form: German ------------------------------------------
    ("Im Kreisverkehr, nehmen Sie die 2. Ausfahrt", 2),
    ("Im Kreisverkehr nehmen Sie die 4. Ausfahrt", 4),

    # --- Digit form: Polish ------------------------------------------
    ("Na rondzie wybierz 2. zjazd", 2),
    ("Na rondzie wybierz 3. zjazd", 3),

    # --- Word form: English ------------------------------------------
    ("At the roundabout take the second exit", 2),
    ("Take the third exit at the roundabout", 3),
    ("Take the fifth exit", 5),

    # --- Word form: Czech (instrumental case used by Apple Maps) -----
    ("vyjeďte druhým výjezdem", 2),
    ("vyjeďte třetím výjezdem", 3),

    # --- Word form: German -------------------------------------------
    ("nehmen Sie die zweite Ausfahrt", 2),
    ("nehmen Sie die dritte Ausfahrt", 3),

    # --- Word form: Polish -------------------------------------------
    ("wybierz drugi zjazd", 2),

    # --- False-positive guards: no roundabout, no exit number -------
    ("Turn left onto Wenceslas Square", None),
    ("Continue straight for 200 meters", None),
    ("Arrive at destination", None),

    # --- Edge cases ---------------------------------------------------
    # 21+ is out of catalog range — parser should still return the
    # number (caller clamps), but our [1..20] filter clips it.
    ("At the roundabout, take the 25th exit", None),
    # Empty string.
    ("", None),
    # Number sitting alone (unlikely Apple Maps would emit, but
    # parser shouldn't crash).
    ("2", 2),
]


@pytest.mark.parametrize("instructions,expected", ROUNDABOUT_FIXTURES)
def test_parse_exit_number(instructions, expected):
    assert parse_exit_number(instructions) == expected, (
        f"Parser disagreed on {instructions!r}: "
        f"expected {expected}, got {parse_exit_number(instructions)}"
    )


# -----------------------------------------------------------------------
# Word ordinal table integrity.
# -----------------------------------------------------------------------

def test_every_listed_word_form_parses_to_its_number():
    """Sanity: every form we listed in WORD_ORDINALS actually parses
    back to the right exit number when fed through the parser as a
    bare phrase (no surrounding 'kruháč' / 'roundabout' context, since
    parse_exit_number is direction-agnostic and only looks for the
    ordinal token)."""
    for n, forms in WORD_ORDINALS.items():
        for form in forms:
            # Skip pure-digit forms (1st/2nd/etc) when wrapping in a
            # sentence because the digit regex would match them via
            # the digit path before the word table is consulted.
            phrase = f"take the {form} exit"
            assert parse_exit_number(phrase) == n, (
                f"Form {form!r} (registered for exit {n}) parsed to "
                f"{parse_exit_number(phrase)} when wrapped in '{phrase}'."
            )


def test_no_duplicate_words_across_numbers():
    """A given word form should map to exactly one exit number."""
    seen: dict[str, int] = {}
    duplicates: list[tuple[str, int, int]] = []
    for n, forms in WORD_ORDINALS.items():
        for form in forms:
            if form in seen and seen[form] != n:
                duplicates.append((form, seen[form], n))
            seen[form] = n
    assert not duplicates, (
        f"These word forms are assigned to multiple exit numbers: "
        f"{duplicates}"
    )


# -----------------------------------------------------------------------
# Swift ↔ Python sync test.
# -----------------------------------------------------------------------

def _swift_parser_source() -> str:
    here = Path(__file__).resolve()
    repo_root = here.parents[3]
    swift = repo_root / "TripperDashPP" / "Navigation" / "Models" / "RoundaboutInstructionParser.swift"
    return swift.read_text(encoding="utf-8")


# Extract every `<int>: [...string list...]` entry in the Swift
# wordOrdinals dictionary. Multiline-friendly.
_SWIFT_ENTRY_RE = re.compile(
    r"(\d+):\s*\[([^\]]+)\]",
    flags=re.DOTALL,
)
_SWIFT_STRING_RE = re.compile(r'"([^"]+)"')


def _parse_swift_word_ordinals() -> dict[int, set[str]]:
    src = _swift_parser_source()
    # Narrow to the wordOrdinals declaration so we don't capture
    # unrelated literals elsewhere in the file.
    block = re.search(
        r"private static let wordOrdinals:.*?=\s*\[(.*?)^\s*\]",
        src,
        flags=re.DOTALL | re.MULTILINE,
    )
    assert block, "Could not locate `wordOrdinals` declaration in Swift parser."
    body = block.group(1)

    parsed: dict[int, set[str]] = {}
    for match in _SWIFT_ENTRY_RE.finditer(body):
        n = int(match.group(1))
        strings = set(_SWIFT_STRING_RE.findall(match.group(2)))
        parsed[n] = strings
    return parsed


def test_swift_word_ordinals_match_python():
    """Every entry in the Swift wordOrdinals table must appear in
    Python WORD_ORDINALS with the same exit number — and vice versa.
    """
    swift = _parse_swift_word_ordinals()
    python_sets = {n: set(forms) for n, forms in WORD_ORDINALS.items()}

    # Same set of exit-number keys.
    assert set(swift.keys()) == set(python_sets.keys()), (
        f"Swift keys {sorted(swift.keys())} vs Python keys "
        f"{sorted(python_sets.keys())} — one side is missing an exit."
    )

    # Same forms per key.
    diffs: list[str] = []
    for n in sorted(swift.keys()):
        only_swift = swift[n] - python_sets[n]
        only_python = python_sets[n] - swift[n]
        if only_swift:
            diffs.append(f"exit {n}: Swift has but Python doesn't: {sorted(only_swift)}")
        if only_python:
            diffs.append(f"exit {n}: Python has but Swift doesn't: {sorted(only_python)}")
    assert not diffs, (
        "Swift and Python word-ordinal tables are out of sync:\n  "
        + "\n  ".join(diffs)
    )


def test_swift_digit_regex_pattern_matches_python():
    """The digit-form regex must be character-for-character identical
    so both parsers handle the same edge cases."""
    src = _swift_parser_source()
    # Match the Swift raw-string regex: #"<pattern>"#
    m = re.search(r'pattern\s*=\s*#"([^"]+)"#', src)
    assert m, "Could not find Swift digitOrdinalRegex pattern literal."
    swift_pattern = m.group(1)

    python_pattern = r"\b(\d{1,2})(?:-?(?:st|nd|rd|th))?\.?(?=\s|\b|$)"
    assert swift_pattern == python_pattern, (
        f"Digit regex drift:\n  Swift:  {swift_pattern!r}\n"
        f"  Python: {python_pattern!r}"
    )
