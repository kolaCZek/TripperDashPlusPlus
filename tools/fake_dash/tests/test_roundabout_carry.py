"""
Tests for roundabout exit-number CARRY-FORWARD across MapKit's split
roundabout steps (`ManeuverKind.classify`, roundabout branch).

Field bug (6/2026 ride): a roundabout's exit number showed correctly on
approach, then the bubble flipped to a generic numberless circle (and the
burned-in glyph briefly looked like a plain right arrow) PARTWAY through
the circle.

Root cause: MapKit frequently emits a roundabout as TWO steps —

  entry: "At the roundabout, take the 1st exit"   (ordinal present)
  exit : "Exit the roundabout onto U Brodu"        (ordinal DROPPED)

Both keep a roundabout keyword, so both classify as `.roundabout`, but
`parse_exit_number` on the exit step alone returns None → exit 0 → generic
glyph. As the rider crosses the entry node, `ActiveNavigator.nextStep`
advances to the exit step and the bubble loses its number.

Fix: when the current step is a roundabout with no parseable ordinal,
CARRY the ordinal forward from the immediately-preceding step if that one
is also a roundabout. So the whole maneuver shows one stable exit number
from entry through exit.

This mirrors the Swift carry logic in `ManeuverIcon.classify`. The Swift
side is additionally covered by the existing roundabout-parser sync tests;
here we pin the carry SEMANTICS (which the parser-only tests can't see,
since carry lives in the classifier, not the parser).
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest

from fake_dash.roundabout_parser import parse_exit_number

# Roundabout family keywords — mirror of `Keywords.roundabout` in
# ManeuverKeywords.swift. Used to decide whether a previous step is a
# roundabout we may carry an ordinal from.
ROUNDABOUT_KEYWORDS = [
    "roundabout", "rotary", "traffic circle",
    "kruhový", "kruhovém", "kruhovým", "kruháč", "kruhák",
    "kruhovom",
    "rondel", "rondo", "rondzie",
    "kreisverkehr", "kreisel",
]


def _is_roundabout(s: str) -> bool:
    low = s.lower()
    return any(k in low for k in ROUNDABOUT_KEYWORDS)


def classify_roundabout_exit(step_instructions: str,
                             previous_instructions: str | None) -> int:
    """Mirror of the roundabout-exit resolution in `ManeuverKind.classify`:
    parse the current step; if that yields nothing AND the previous step is
    also a roundabout, carry its ordinal forward; else exit 0 (generic)."""
    n = parse_exit_number(step_instructions)
    if n is None and previous_instructions is not None and _is_roundabout(previous_instructions):
        n = parse_exit_number(previous_instructions)
    return n or 0


# ----------------------------------------------------------------------
# Carry-forward across the entry → exit step split.
# ----------------------------------------------------------------------

@pytest.mark.parametrize("entry,exit_step,expected", [
    # EN split: ordinal on entry, dropped on exit → carried.
    ("At the roundabout, take the 1st exit",
     "Exit the roundabout onto U Brodu", 1),
    ("At the roundabout, take the 3rd exit",
     "Exit the roundabout onto Route 7", 3),
    # CZ split: Apple Maps' "Opusťte kruhový objezd …" exit phrasing.
    ("Na kruhovém objezdu vyjeďte 2. výjezdem",
     "Opusťte kruhový objezd na ulici Hlavní", 2),
    ("Na kruhovém objezdu vyjeďte 4. výjezdem",
     "Opusťte kruhový objezd", 4),
    # DE split.
    ("Im Kreisverkehr, nehmen Sie die 2. Ausfahrt",
     "Verlassen Sie den Kreisverkehr", 2),
])
def test_exit_number_carried_from_entry_to_exit_step(entry, exit_step, expected):
    # On the exit step the classifier sees step=exit_step, previous=entry.
    assert classify_roundabout_exit(exit_step, entry) == expected


def test_entry_step_alone_still_parses_directly():
    """A non-split roundabout (single step that keeps its ordinal) must
    keep working with no previous-step dependency."""
    assert classify_roundabout_exit(
        "At the roundabout, take the 2nd exit", None) == 2


# ----------------------------------------------------------------------
# Carry guards: don't invent a number where there isn't one.
# ----------------------------------------------------------------------

def test_no_carry_when_previous_is_not_a_roundabout():
    """An exit-less roundabout step preceded by a PLAIN turn must stay
    generic (exit 0) — we must not pull a digit out of an unrelated road
    name or instruction."""
    assert classify_roundabout_exit(
        "Exit the roundabout onto X", "Turn right onto Route 7") == 0


def test_no_carry_when_no_previous_step():
    assert classify_roundabout_exit("Exit the roundabout onto X", None) == 0


def test_no_carry_from_roundabout_that_also_lacks_ordinal():
    """If neither step has an ordinal, the result is still a clean generic
    glyph, not a crash or a spurious number."""
    assert classify_roundabout_exit(
        "Exit the roundabout", "At the roundabout") == 0


def test_current_step_ordinal_wins_over_carry():
    """If the exit step somehow DOES carry its own ordinal, that wins —
    we only fall back to the previous step when the current one is silent.
    Guards against a future MapKit locale that keeps the number on both."""
    assert classify_roundabout_exit(
        "Exit via the 2nd exit", "At the roundabout, take the 3rd exit") == 2


# ----------------------------------------------------------------------
# Stability: entry and exit steps of the SAME maneuver agree, so the
# dash glyph (0x0A + exit) never changes mid-circle.
# ----------------------------------------------------------------------

@pytest.mark.parametrize("entry,exit_step", [
    ("At the roundabout, take the 1st exit", "Exit the roundabout onto A"),
    ("Na kruhovém objezdu vyjeďte 2. výjezdem", "Opusťte kruhový objezd"),
    ("At the roundabout, take the 5th exit", "Exit the roundabout onto B"),
])
def test_entry_and_exit_glyph_bytes_are_identical(entry, exit_step):
    """The wire byte is 0x0A + exit for a CCW roundabout. If entry and
    exit steps resolve to the same exit number, the dash shows one stable
    glyph across the whole maneuver instead of flipping to the numberless
    0x0A mid-circle."""
    entry_exit = classify_roundabout_exit(entry, None)
    exit_exit = classify_roundabout_exit(exit_step, entry)
    assert entry_exit == exit_exit, (
        f"entry resolved exit {entry_exit} but exit step resolved "
        f"{exit_exit} — glyph would change mid-roundabout."
    )
    # And the resulting CCW wire byte matches (0x0A + clamped exit).
    assert 0x0A + min(19, entry_exit) == 0x0A + min(19, exit_exit)


# ----------------------------------------------------------------------
# Swift-source drift guard: the carry path must exist in the classifier.
# ----------------------------------------------------------------------

def test_swift_classify_carries_exit_from_previous_step():
    here = Path(__file__).resolve()
    repo_root = here.parents[3]
    swift = (
        repo_root / "TripperDashPP" / "Navigation" / "Models" / "ManeuverIcon.swift"
    )
    src = swift.read_text(encoding="utf-8")
    # Find the roundabout branch in classify(...). The branch carries a
    # long explanatory comment before the carry logic, so widen the slice
    # enough to include the precedingStep carry path below it.
    idx = src.index("if Keywords.isRoundabout(s)")
    branch = src[idx:idx + 1600]
    # The carry path must: reference the preceding step, re-check
    # isRoundabout on it, and re-parse its instructions. We assert all
    # three so a future refactor that drops the carry fails loudly here.
    assert "precedingStep" in branch, "roundabout branch no longer reads precedingStep"
    assert "isRoundabout(prev" in branch, "carry no longer re-checks previous is a roundabout"
    assert branch.count("parseExitNumber") >= 2, (
        "carry no longer re-parses the previous step's ordinal "
        "(expected two parseExitNumber calls: current + carried)."
    )
