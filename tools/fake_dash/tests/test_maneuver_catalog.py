"""
Sync test: the Swift `ManeuverKind.wireByte` mapping in
`TripperDashPP/Navigation/Models/ManeuverIcon.swift` must point at
bytes that actually exist in `docs/maneuver-glyphs/README.md`.

If the catalog gets re-walked and a byte gets reassigned (or the
Swift mapping drifts during a refactor) these tests catch it.
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest

from fake_dash.maneuver_catalog import (
    CANONICAL_WIRE_BYTES,
    EMPTY_BUBBLE_BYTES,
    load_catalog,
    roundabout_wire_byte,
)


def _swift_source() -> str:
    here = Path(__file__).resolve()
    repo_root = here.parents[3]
    swift = repo_root / "TripperDashPP" / "Navigation" / "Models" / "ManeuverIcon.swift"
    return swift.read_text(encoding="utf-8")


# -----------------------------------------------------------------------
# Catalog integrity — make sure our reader sees a sensible catalog.
# -----------------------------------------------------------------------

def test_catalog_has_visible_glyph_count_around_90():
    """The 6/2026 walk captured ~90 visible glyphs in 0x00..0x59."""
    catalog = load_catalog()
    # 0x00..0x59 = 90 bytes total. Subtract the 6 known empty-bubble
    # placeholders to get the count of glyph-bearing entries; allow a
    # small fudge in case the README adds new "empty" markers later.
    visible_glyph_count = sum(1 for b in catalog if b not in EMPTY_BUBBLE_BYTES)
    assert 80 <= visible_glyph_count <= 90, (
        f"Expected ~84 visible glyph entries (90 minus 6 empties), "
        f"got {visible_glyph_count}. Catalog file may be malformed."
    )


def test_every_canonical_wire_byte_exists_in_catalog():
    """Every byte we hand to the dash must be a real catalog entry."""
    catalog = load_catalog()
    missing = {
        name: byte
        for name, byte in CANONICAL_WIRE_BYTES.items()
        if byte not in catalog
    }
    assert not missing, (
        f"These ManeuverKind mappings point at bytes not in the catalog: "
        f"{missing}. Either the catalog is incomplete or the Swift "
        f"mapping references a stale byte."
    )


def test_no_canonical_byte_is_an_empty_bubble():
    """Don't waste a TLV slot on a byte the dash renders as empty."""
    offenders = {
        name: byte
        for name, byte in CANONICAL_WIRE_BYTES.items()
        if byte in EMPTY_BUBBLE_BYTES
    }
    assert not offenders, (
        f"These mappings would render as an empty bubble on the dash: "
        f"{offenders}. Pick a different catalog byte."
    )


# -----------------------------------------------------------------------
# Roundabout encoder — the four ranges of the catalog roundabout glyphs.
# -----------------------------------------------------------------------

@pytest.mark.parametrize("exit_idx,expected", [
    (0, 0x0A), (1, 0x0B), (5, 0x0F), (9, 0x13),
    (10, 0x50), (15, 0x55), (19, 0x59),
])
def test_roundabout_ccw_range(exit_idx, expected):
    assert roundabout_wire_byte(exit_idx, clockwise=False) == expected


@pytest.mark.parametrize("exit_idx,expected", [
    (0, 0x31), (1, 0x32), (5, 0x36), (9, 0x3A),
    (10, 0x46), (15, 0x4B), (19, 0x4F),
])
def test_roundabout_cw_range(exit_idx, expected):
    assert roundabout_wire_byte(exit_idx, clockwise=True) == expected


@pytest.mark.parametrize("exit_idx", [-1, -100, 20, 99, 255])
def test_roundabout_exit_clamps_to_catalog_range(exit_idx):
    """Out-of-range exits clamp into [0..19] silently."""
    byte = roundabout_wire_byte(exit_idx, clockwise=False)
    assert 0x0A <= byte <= 0x59  # somewhere inside the CCW range


def test_roundabout_bytes_all_exist_in_catalog():
    """All 40 roundabout slots (10 CCW lo + 10 CCW hi + 10 CW lo + 10 CW hi)
    must be present in the user-verified catalog."""
    catalog = load_catalog()
    for clockwise in (False, True):
        for n in range(20):
            byte = roundabout_wire_byte(n, clockwise=clockwise)
            assert byte in catalog, (
                f"Roundabout byte {byte:#04x} "
                f"(exit={n}, cw={clockwise}) is not in the catalog."
            )


# -----------------------------------------------------------------------
# Swift ↔ Python sync — read the Swift source and check every byte
# literal in the `wireByte` switch matches `CANONICAL_WIRE_BYTES`.
# -----------------------------------------------------------------------

# Match a Swift case in the wireByte switch that returns a single byte
# literal, e.g. `case .left:            return 0x14`.
_SWIFT_CASE_RE = re.compile(
    r"case\s+\.(\w+):\s*return\s+0x([0-9A-Fa-f]{2})"
)


def test_swift_wire_byte_mapping_matches_python_canonical():
    """
    Parse the `wireByte` switch in `ManeuverIcon.swift` and assert every
    plain (non-associated-value) case returns the byte declared in
    `CANONICAL_WIRE_BYTES`. Roundabout (which has associated values) is
    covered by `test_roundabout_bytes_all_exist_in_catalog` above.
    """
    src = _swift_source()
    # Narrow to the wireByte computed property body so we don't
    # accidentally pick up `case .straight:` from the drawer switch.
    wire_byte_block = re.search(
        r"var wireByte: UInt8 \{(.+?)^    \}",
        src,
        flags=re.DOTALL | re.MULTILINE,
    )
    assert wire_byte_block, "Could not locate `wireByte` block in Swift source."
    block = wire_byte_block.group(1)

    swift_map: dict[str, int] = {}
    for match in _SWIFT_CASE_RE.finditer(block):
        name = match.group(1)
        byte = int(match.group(2), 16)
        swift_map[name] = byte

    # Every Python canonical entry must appear in the Swift switch with
    # the same byte. Extra Swift cases are OK (forward-compatible).
    for name, expected_byte in CANONICAL_WIRE_BYTES.items():
        assert name in swift_map, (
            f"Swift wireByte switch is missing case `.{name}`. "
            f"Add `case .{name}: return {expected_byte:#04x}` "
            f"or remove the entry from CANONICAL_WIRE_BYTES."
        )
        assert swift_map[name] == expected_byte, (
            f"Swift wireByte for `.{name}` is {swift_map[name]:#04x}, "
            f"Python canonical is {expected_byte:#04x}. Pick one."
        )
