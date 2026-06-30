"""
Python mirror of `TripperDashPP/Navigation/Models/ManeuverKeywords.swift`.

The Swift `Keywords` enum is the TEXT half of the maneuver classifier: it
decides the maneuver FAMILY (roundabout / U-turn / merge / exit / ferry /
railroad / arrive) from localized Apple Maps instruction strings, and
provides a word-boundary textual direction fallback.

fake_dash can't run Swift, so we mirror the keyword tables + the two
matching primitives here and:
  * behaviourally table-test them against realistic multi-language Apple
    Maps strings (`tests/test_maneuver_keywords.py` layer 1), and
  * assert via a Swift-source sync test that every token list matches the
    Swift side exactly (layer 2),
so the iOS app and the tooling can't drift apart silently — the same
discipline used for the roundabout parser, maneuver geometry, and the
driving-side table.

If you change either side, mirror the change here (and vice versa).

Matching semantics — KEEP IDENTICAL to Swift:
  * Family tables use SUBSTRING match (`containsAny`): tokens are
    distinctive verbs/nouns, not road-name fragments, so substring is
    safe AND catches inflected forms. This is why short ambiguous tokens
    (FR "bac", NL "veer", SV "vänd", NO "snu") are deliberately NOT in the
    family lists — they'd false-match inside ordinary words.
  * Direction tables use WORD-BOUNDARY match (`first_index`): a road NAME
    containing "left"/"links"/… must not flip the turn.
"""

from __future__ import annotations

import re

# ----------------------------------------------------------------------
# Family keyword sets (SUBSTRING match). Mirror order is irrelevant for
# behaviour but kept identical to Swift so the sync test can diff sets.
# ----------------------------------------------------------------------

ROUNDABOUT = [
    "roundabout", "rotary", "traffic circle",
    "kruhový", "kruhovém", "kruhovým", "kruháč", "kruhák", "kruhovom",
    "rondel", "rondo", "rondzie",
    "kreisverkehr", "kreisel",
    "rotonda", "glorieta",
    "rond-point", "rond point", "giratoire",
    "rotatoria",
    "rotunda",
    "rotonde",
    "rundkjøring", "rondell", "rundkørsel", "liikenneympyrä",
]

U_TURN = [
    "u-turn", "u turn", "make a u-turn",
    "otočte se", "otočte", "otočit", "otočení",
    "wenden", "zawróć",
    "cambio de sentido", "media vuelta",
    "demi-tour", "demi tour",
    "inversione",
    "retorno", "inverta",
    "keer om", "u-bocht",
    "u-sving", "käänny ympäri",
]

MERGE = [
    "merge",
    "zařaďte se", "zařaďte", "připojte se", "připojit",
    "einfädeln", "auffahren", "włącz się",
    "incorpór",
    "insérez", "rejoignez",
    "immett", "confluis",
    "incorpore",
    "voeg in",
    "flett", "anslut",
]

EXIT_RAMP = [
    "exit", "ramp", "off-ramp", "take the ramp",
    "sjeďte", "sjezd", "sjezdem", "nájezd",
    "ausfahrt", "abfahrt",
    "zjazd", "zjazdem",
    "salida",
    "sortie",
    "uscita", "esci",
    "saída",
    "afrit", "afslag",
    "avkjørsel", "avfart", "frakørsel", "poistu",
]

FERRY = [
    "ferry", "board the ferry",
    "trajekt", "přívoz", "fähre", "prom",
    "transbordador", "traghetto", "balsa", "veerboot",
    "ferge", "ferje", "ferja", "färja", "færge", "lautta",
]

RAILROAD = [
    "railroad", "railway", "level crossing", "grade crossing",
    "železniční přejezd", "přejezd", "bahnübergang", "przejazd kolejowy",
    "paso a nivel", "passage à niveau", "passaggio a livello",
    "passagem de nível", "overweg", "spoorwegovergang",
    "planovergang", "järnvägskorsning", "jernbaneoverskæring",
]

ARRIVE = [
    "arrive", "arrival", "destination", "you have arrived",
    "cíl", "dorazíte", "dorazili", "u cíle",
    "ziel", "cel podróży",
    "llegado", "llegada", "destino",
    "arrivé", "arrivée",
    "arrivat", "destinazione",
    "chegou", "chegada",
    "bestemming", "gearriveerd", "aankomst",
    "framme", "ankomst", "perillä", "määränpää",
]

# ----------------------------------------------------------------------
# Direction tokens (WORD-BOUNDARY match).
# ----------------------------------------------------------------------

LEFT_TOKENS = [
    "left",
    "vlevo", "doleva",
    "vľavo", "doľava",
    "links", "linksaf",
    "lewo",
    "izquierda",
    "gauche",
    "sinistra",
    "esquerda",
    "venstre",
    "vänster",
    "vasemmalle", "vasen",
]
RIGHT_TOKENS = [
    "right",
    "vpravo", "doprava",
    "rechts", "rechtsaf",
    "prawo",
    "derecha",
    "droite",
    "destra",
    "direita",
    "høyre", "højre",
    "höger",
    "oikealle", "oikea",
]
SHARP_TOKENS = [
    "sharp",
    "ostře", "ostro",
    "scharf",
    "cerrada",
    "serré",
    "secca",
    "acentuada",
    "scherp",
    "skarp",
]
SLIGHT_TOKENS = [
    "slight",
    "mírně", "mierne",
    "leicht",
    "lekko",
    "ligera",
    "légère", "légèrement",
    "leggera",
    "ligeira",
    "licht", "flauw",
    "svak", "svag",
]


# ----------------------------------------------------------------------
# Matching primitives — KEEP IDENTICAL semantics to Swift.
# ----------------------------------------------------------------------

def _contains_any(s: str, needles: list[str]) -> bool:
    """Substring match (mirrors Swift `containsAny`)."""
    return any(n in s for n in needles)


def first_index(s: str, tokens: list[str]) -> int | None:
    """Offset of the earliest WORD-BOUNDARY match of any token, or None.
    Mirrors Swift `firstIndex` (`\\btoken\\b`, case-insensitive)."""
    best: int | None = None
    for tok in tokens:
        pattern = r"\b" + re.escape(tok) + r"\b"
        m = re.search(pattern, s, flags=re.IGNORECASE | re.UNICODE)
        if m and (best is None or m.start() < best):
            best = m.start()
    return best


# Family predicates (input expected lowercased by caller, as in Swift).
def is_roundabout(s: str) -> bool: return _contains_any(s, ROUNDABOUT)
def is_u_turn(s: str) -> bool:     return _contains_any(s, U_TURN)
def is_merge(s: str) -> bool:      return _contains_any(s, MERGE)
def is_exit_ramp(s: str) -> bool:  return _contains_any(s, EXIT_RAMP)
def is_ferry(s: str) -> bool:      return _contains_any(s, FERRY)
def is_railroad(s: str) -> bool:   return _contains_any(s, RAILROAD)
def is_arrive(s: str) -> bool:     return _contains_any(s, ARRIVE)


def textual_turn(s: str) -> str:
    """Direction from text alone — mirrors Swift `textualTurn`. Returns a
    ManeuverKind-style string: straight / {slight,,sharp}{Left,Right}."""
    li = first_index(s, LEFT_TOKENS)
    ri = first_index(s, RIGHT_TOKENS)
    if li is not None and ri is not None:
        side = "left" if li <= ri else "right"
    elif li is not None:
        side = "left"
    elif ri is not None:
        side = "right"
    else:
        return "straight"

    sharp = _contains_any(s, SHARP_TOKENS)
    slight = _contains_any(s, SLIGHT_TOKENS)
    if side == "left":
        if sharp:
            return "sharpLeft"
        return "slightLeft" if slight else "left"
    if sharp:
        return "sharpRight"
    return "slightRight" if slight else "right"
