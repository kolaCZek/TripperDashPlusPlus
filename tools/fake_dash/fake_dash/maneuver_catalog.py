"""
Maneuver catalog loader for the user-verified `docs/maneuver-glyphs/`
README. Single source of truth for what byte → which glyph on the dash.

Used by:
  - `tests/test_maneuver_catalog.py` to verify the Swift `wireByte`
    mapping in `ManeuverIcon.swift` stays in sync with the catalog.
  - Future replay/dump tooling that wants to label captured packets.

The catalog README lives at `docs/maneuver-glyphs/README.md`. It has
two passes of tables (a short quick-reference followed by the full
detail table); when bytes appear in both, the later occurrence wins
because it carries the richer description.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class CatalogEntry:
    byte: int                # 0x00..0x59 for visible glyphs
    description: str         # human-readable description from the README
    visible: bool = True     # False for the 0x5A..0xFF "hidden bubble" range

    @property
    def hex(self) -> str:
        return f"0x{self.byte:02X}"


# Bytes that the catalog explicitly marks as empty / placeholder. The
# dash renders an empty bubble for these — sending them as a maneuver
# is legal but useless.
EMPTY_BUBBLE_BYTES = frozenset({0x2B, 0x2C, 0x41, 0x43, 0x44, 0x45})


def _find_catalog_readme() -> Path:
    """Locate `docs/maneuver-glyphs/README.md` relative to this module."""
    here = Path(__file__).resolve()
    # tools/fake_dash/fake_dash/maneuver_catalog.py → repo root is 3 up.
    repo_root = here.parents[3]
    p = repo_root / "docs" / "maneuver-glyphs" / "README.md"
    if not p.exists():
        raise FileNotFoundError(f"Maneuver catalog README not found at {p}")
    return p


_ROW_RE = re.compile(
    r"\|\s*`0x([0-9A-Fa-f]{2})`\s*\|\s*([^|]*?)\s*\|\s*([^|]+?)\s*\|"
)


def load_catalog(readme_path: Path | None = None) -> dict[int, CatalogEntry]:
    """
    Parse the catalog README and return `{byte: CatalogEntry}` for every
    visible glyph (0x00..0x59). Later table rows override earlier ones,
    so the rich detail table wins over the quick reference.
    """
    if readme_path is None:
        readme_path = _find_catalog_readme()
    text = readme_path.read_text(encoding="utf-8")

    entries: dict[int, CatalogEntry] = {}
    for match in _ROW_RE.finditer(text):
        byte = int(match.group(1), 16)
        desc = match.group(3).strip()
        # Skip table-header style rows or trivially-short ones.
        if len(desc) < 3:
            continue
        # Only the visible range (0x00..0x59) is documented entry-by-entry.
        if byte > 0x59:
            continue
        entries[byte] = CatalogEntry(byte=byte, description=desc)

    return entries


# Convenience: the canonical "what does the Swift app need to send for
# each semantic maneuver" map. Mirrors `ManeuverKind.wireByte` in
# `TripperDashPP/Navigation/Models/ManeuverIcon.swift`. Tests assert
# these stay in sync.
CANONICAL_WIRE_BYTES: dict[str, int] = {
    "straight":         0x09,
    "slightLeft":       0x18,
    "left":             0x14,
    "sharpLeft":        0x16,
    "slightRight":      0x19,
    "right":            0x15,
    "sharpRight":       0x17,
    "uTurnLeft":        0x3D,
    "uTurnRight":       0x1A,
    "mergeLeft":        0x03,
    "mergeRight":       0x04,
    "forkLeft":         0x06,
    "forkRight":        0x05,
    "forkStraight":     0x1B,
    "exitLeft":         0x28,
    "exitRight":        0x27,
    "arrive":           0x00,
    "arriveLeft":       0x01,
    "arriveRight":      0x02,
    "recalculating":    0x1C,
    "ferry":            0x3E,
    "railroad":         0x3F,
}


def roundabout_wire_byte(exit: int, clockwise: bool) -> int:
    """
    Return the catalog byte for a roundabout maneuver with `exit` count
    and rotation direction. Mirrors the Swift `roundabout(exit:clockwise:)`
    case in `ManeuverKind.wireByte`.

    Catalog ranges:
      CCW exits 0..9   → 0x0A..0x13
      CCW exits 10..19 → 0x50..0x59
      CW  exits 0..9   → 0x31..0x3A
      CW  exits 10..19 → 0x46..0x4F

    Exit count is clamped to 0..19 (catalog limit).
    """
    n = max(0, min(19, exit))
    if not clockwise:
        return 0x0A + n if n < 10 else 0x50 + (n - 10)
    return 0x31 + n if n < 10 else 0x46 + (n - 10)
