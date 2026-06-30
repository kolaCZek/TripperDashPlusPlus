"""
Maneuver-keyword classifier tests (multi-language).

Layer 1 — behavioural: realistic Apple Maps instruction strings in many
locales are run through the Python mirror's family predicates + textual
turn fallback. This is the layer that proves the app actually recognises
a Spanish "rotonda" or a French "demi-tour" as the right family — the gap
this whole change set closes for a worldwide release.

Layer 2 — Swift ↔ Python sync: parse every token array out of
`ManeuverKeywords.swift` and assert it matches the Python table exactly,
so the two can't drift.
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest

from tests.maneuver_keywords import (
    ARRIVE, EXIT_RAMP, FERRY, LEFT_TOKENS, MERGE, RAILROAD, RIGHT_TOKENS,
    ROUNDABOUT, SHARP_TOKENS, SLIGHT_TOKENS, U_TURN,
    first_index, is_arrive, is_exit_ramp, is_ferry, is_merge, is_railroad,
    is_roundabout, is_u_turn, textual_turn,
)


# ----------------------------------------------------------------------
# Layer 1a — family detection across locales.
# Each case: (instruction, predicate, expected_bool).
# ----------------------------------------------------------------------

# Roundabout in many languages (the #2 bug: only CZ/EN/SK/DE/PL before).
ROUNDABOUT_STRINGS = [
    "At the roundabout, take the 2nd exit",            # EN
    "Na kruhovém objezdu vyjeďte 2. výjezdem",         # CZ
    "Im Kreisverkehr nehmen Sie die 2. Ausfahrt",      # DE
    "Na rondzie wybierz 2. zjazd",                     # PL
    "En la rotonda, toma la 2ª salida",                # ES
    "Au rond-point, prenez la 2e sortie",              # FR
    "Alla rotatoria, prendi la 2ª uscita",             # IT
    "Na rotunda, saia na 2ª saída",                    # PT
    "Neem op de rotonde de 2e afslag",                 # NL
    "I rundkjøringen, ta den 2. avkjørselen",          # NO
    "Ta den andra avfarten i rondellen",               # SV
]

U_TURN_STRINGS = [
    "Make a U-turn",                                   # EN
    "Otočte se",                                       # CZ
    "Bitte wenden",                                    # DE
    "Haz un cambio de sentido",                        # ES
    "Faites demi-tour",                                # FR
    "Fai inversione a U",                              # IT
]

FERRY_STRINGS = [
    "Board the ferry",                                 # EN
    "Najeďte na trajekt",                              # CZ
    "Nehmen Sie die Fähre",                            # DE
    "Tome el transbordador",                           # ES
    "Prendi il traghetto",                             # IT
    "Ta ferja",                                        # NO
]

EXIT_STRINGS = [
    "Take exit 12",                                    # EN
    "Sjeďte na sjezdu 12",                             # CZ
    "Nehmen Sie die Ausfahrt 12",                      # DE
    "Toma la salida 12",                               # ES
    "Prenez la sortie 12",                             # FR
    "Prendi l'uscita 12",                              # IT
]

ARRIVE_STRINGS = [
    "You have arrived at your destination",            # EN
    "Dorazili jste do cíle",                           # CZ
    "Sie haben Ihr Ziel erreicht",                     # DE
    "Has llegado a tu destino",                        # ES
    "Vous êtes arrivé",                                # FR
    "Sei arrivato a destinazione",                     # IT
]


@pytest.mark.parametrize("s", ROUNDABOUT_STRINGS)
def test_roundabout_detected_in_locale(s):
    assert is_roundabout(s.lower()), f"roundabout not detected: {s!r}"


@pytest.mark.parametrize("s", U_TURN_STRINGS)
def test_uturn_detected_in_locale(s):
    assert is_u_turn(s.lower()), f"U-turn not detected: {s!r}"


@pytest.mark.parametrize("s", FERRY_STRINGS)
def test_ferry_detected_in_locale(s):
    assert is_ferry(s.lower()), f"ferry not detected: {s!r}"


@pytest.mark.parametrize("s", EXIT_STRINGS)
def test_exit_detected_in_locale(s):
    assert is_exit_ramp(s.lower()), f"exit not detected: {s!r}"


@pytest.mark.parametrize("s", ARRIVE_STRINGS)
def test_arrive_detected_in_locale(s):
    assert is_arrive(s.lower()), f"arrival not detected: {s!r}"


# ----------------------------------------------------------------------
# Layer 1b — direction fallback across locales (geometry-unavailable path).
# (instruction, expected_turn_string)
# ----------------------------------------------------------------------

DIRECTION_FIXTURES = [
    ("Turn left onto Main St", "left"),                # EN
    ("Turn right onto Main St", "right"),              # EN
    ("Gire a la izquierda", "left"),                   # ES
    ("Gire a la derecha", "right"),                    # ES
    ("Tournez à gauche", "left"),                      # FR
    ("Tournez à droite", "right"),                     # FR
    ("Svolta a sinistra", "left"),                     # IT
    ("Svolta a destra", "right"),                      # IT
    ("Vire à esquerda", "left"),                       # PT
    ("Vire à direita", "right"),                       # PT
    ("Sla linksaf", "left"),                           # NL (fused)
    ("Sla rechtsaf", "right"),                         # NL (fused)
    ("Ta til venstre", "left"),                        # NO
    ("Sväng höger", "right"),                          # SV
    ("Käänny vasemmalle", "left"),                     # FI
    ("Käänny oikealle", "right"),                      # FI
    # Sharpness
    ("Turn sharp left", "sharpLeft"),                  # EN
    ("Gire ligeramente a la derecha", "slightRight"),  # ES
    # No direction word at all → straight.
    ("Continue onto Main St", "straight"),
]


@pytest.mark.parametrize("s,expected", DIRECTION_FIXTURES)
def test_textual_turn(s, expected):
    got = textual_turn(s.lower())
    assert got == expected, f"{s!r}: expected {expected}, got {got}"


# ----------------------------------------------------------------------
# Layer 1c — road-name false-positive guard (word boundary).
# A road NAME that contains a direction substring must NOT flip the turn.
# ----------------------------------------------------------------------

def test_road_name_does_not_flip_direction():
    # "Leftbank Road" contains "left" but the verb is RIGHT.
    assert textual_turn("turn right onto leftbank road") == "right"
    # "Linksstrasse" contains "links" but the verb is RIGHT (rechts).
    assert textual_turn("rechts auf linksstrasse") == "right"


# ----------------------------------------------------------------------
# Layer 2 — Swift ↔ Python sync.
# ----------------------------------------------------------------------

_TABLES = {
    "roundabout": ROUNDABOUT,
    "uTurn": U_TURN,
    "merge": MERGE,
    "exitRamp": EXIT_RAMP,
    "ferry": FERRY,
    "railroad": RAILROAD,
    "arrive": ARRIVE,
    "leftTokens": LEFT_TOKENS,
    "rightTokens": RIGHT_TOKENS,
    "sharpTokens": SHARP_TOKENS,
    "slightTokens": SLIGHT_TOKENS,
}

_STRING_RE = re.compile(r'"([^"]+)"')


def _swift_source() -> str:
    here = Path(__file__).resolve()
    repo_root = here.parents[3]
    swift = (repo_root / "TripperDashPP" / "Navigation" / "Models"
             / "ManeuverKeywords.swift")
    return swift.read_text(encoding="utf-8")


def _swift_array(name: str, src: str) -> set[str]:
    """Extract the string literals from `static let <name> = [ ... ]`.

    The array terminator is matched as a `]` sitting alone on its own
    (indented) line — Swift formats every one of these tables that way —
    so a stray `]` inside an inline `// comment` can't truncate the slice.
    Comment text is then stripped before pulling quoted tokens out.
    """
    m = re.search(rf"static let {name}\s*=\s*\[(.*?)\n\s*\]",
                  src, flags=re.DOTALL)
    assert m, f"Could not find Swift array `{name}`"
    body = m.group(1)
    # Drop // line comments so a quoted word inside a comment can't leak in
    # (our comments don't contain quoted tokens, but be defensive).
    body = re.sub(r"//[^\n]*", "", body)
    return set(_STRING_RE.findall(body))


@pytest.mark.parametrize("name", sorted(_TABLES.keys()))
def test_swift_keyword_table_matches_python(name):
    src = _swift_source()
    swift = _swift_array(name, src)
    python = set(_TABLES[name])
    only_swift = swift - python
    only_python = python - swift
    assert not only_swift and not only_python, (
        f"Keyword table `{name}` out of sync:\n"
        f"  only in Swift:  {sorted(only_swift)}\n"
        f"  only in Python: {sorted(only_python)}"
    )
