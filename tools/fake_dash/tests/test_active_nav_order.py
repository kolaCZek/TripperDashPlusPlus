"""
Tests for the ACTIVE-NAV TLV *ordering* in `K1GPacket.makeActiveNav`.

Motivating field bug (6/2026 ride): the dash bubble rendered the turn
arrow + primary distance fine, but the ETA and the total-distance-remaining
fields were always BLANK — even though every individual TLV
(`0x08` ETA, `0x09` total, `0x46` total-unit, `0x54` eta-format) was
byte-correct and `test_eta_pipeline.py` was green.

Root cause was ORDER, not bytes. The dash pairs a value TLV with its
unit/format TLV *positionally*: it reads `0x09` (total distance) and then
expects `0x46` (its unit) to be the very next nav-info TLV; likewise it
reads `0x08` (ETA) and expects `0x54` (its format flag) next. The old
Swift builder emitted both units at the *end* of the chain (after the
decimal separator and the remaining-time block), so the dash saw a
"dangling" value with no unit and silently dropped the whole field.

`test_eta_pipeline.py` pins each TLV's bytes in isolation, so it could
never catch this. This file pins the ADJACENCY, against the better-dash
authority `build_active_nav_packet` (which appends
`total_distance` → `total_distance_unit` back-to-back) and the real-phone
pcap field order documented in `references/k1g-active-nav-tlv-chain.md`.

Three layers, cheapest first:

  1. A Python mirror of `makeActiveNav`'s ordering, table-tested for the
     two adjacency invariants on representative packets.
  2. A full byte-level decode of a representative packet through
     `fake_dash.protocol`, asserting the decoded TLV stream has the units
     adjacent to their values.
  3. A Swift-source drift guard: parse the literal order of
     `segs.append(tlv…())` calls out of `K1GPacket.swift` and assert the
     adjacency holds there too, so a future reorder that breaks the wire
     contract fails here instead of on a moving bike.
"""

from __future__ import annotations

import re
from datetime import datetime
from pathlib import Path

import pytest

from fake_dash.protocol import Segment, build_envelope, decode_packet

# Nav-info / status segment family bytes (K1G.SegType raw values).
NAV_INFO = 0x05
STATUS = 0x06

# Sub-types we care about for ordering (full set lives in K1GPacket.swift).
SUB_ROAD_NAME = 0x01
SUB_PRIMARY_MANEUVER = 0x02
SUB_SECONDARY_MANEUVER = 0x03
SUB_PRIMARY_DISTANCE = 0x04
SUB_SECONDARY_DISTANCE = 0x05
SUB_PRIMARY_UNIT = 0x06
SUB_SECONDARY_UNIT = 0x07
SUB_ETA = 0x08
SUB_TOTAL_DISTANCE = 0x09
SUB_DECIMAL_SEPARATOR = 0x0A
SUB_REMAINING_TIME = 0x0B
SUB_TOTAL_DISTANCE_UNIT = 0x46
SUB_ETA_FORMAT = 0x54
SUB_REMAINING_UNIT = 0x55
SUB_PROJECTION_FLAG = 0x05  # under STATUS family
SUB_DECIMAL_FLAG = 0x0D     # under STATUS family


def _swift_packet_source() -> str:
    here = Path(__file__).resolve()
    repo_root = here.parents[3]
    swift = repo_root / "TripperDashPP" / "Tripper" / "K1GPacket.swift"
    return swift.read_text(encoding="utf-8")


# ----------------------------------------------------------------------
# 1. Python mirror of makeActiveNav's ordering.
# ----------------------------------------------------------------------

def make_active_nav_order(
    *,
    road_name: bool = False,
    secondary: bool = False,
    eta: bool = False,
    remaining: bool = False,
) -> list[tuple[int, int]]:
    """Mirror of the TLV ordering in `K1GPacket.makeActiveNav`. Returns
    the (type, sub) sequence for the given optional-field toggles. Must
    stay in lockstep with the Swift builder — the drift guard below reads
    the Swift source to keep us honest."""
    segs: list[tuple[int, int]] = []
    if road_name:
        segs.append((NAV_INFO, SUB_ROAD_NAME))
    segs.append((NAV_INFO, SUB_PRIMARY_MANEUVER))
    segs.append((NAV_INFO, SUB_PRIMARY_DISTANCE))
    segs.append((NAV_INFO, SUB_PRIMARY_UNIT))
    if secondary:
        segs.append((NAV_INFO, SUB_SECONDARY_MANEUVER))
        segs.append((NAV_INFO, SUB_SECONDARY_DISTANCE))
        segs.append((NAV_INFO, SUB_SECONDARY_UNIT))
    if eta:
        segs.append((NAV_INFO, SUB_ETA))
        segs.append((NAV_INFO, SUB_ETA_FORMAT))        # MUST follow ETA
    segs.append((NAV_INFO, SUB_TOTAL_DISTANCE))
    segs.append((NAV_INFO, SUB_TOTAL_DISTANCE_UNIT))   # MUST follow total
    segs.append((NAV_INFO, SUB_DECIMAL_SEPARATOR))
    if remaining:
        segs.append((NAV_INFO, SUB_REMAINING_TIME))
        segs.append((NAV_INFO, SUB_REMAINING_UNIT))
    segs.append((STATUS, SUB_PROJECTION_FLAG))
    segs.append((STATUS, SUB_DECIMAL_FLAG))
    return segs


def _assert_adjacent(order: list[tuple[int, int]], value_sub: int, unit_sub: int) -> None:
    """Assert `unit_sub` is the nav-info TLV immediately after `value_sub`."""
    subs = [sub for (t, sub) in order if t == NAV_INFO]
    assert value_sub in subs, f"value TLV 0x{value_sub:02X} missing from packet"
    i = subs.index(value_sub)
    assert i + 1 < len(subs), f"value 0x{value_sub:02X} is last — no unit follows"
    assert subs[i + 1] == unit_sub, (
        f"unit 0x{unit_sub:02X} must immediately follow value 0x{value_sub:02X}; "
        f"got 0x{subs[i + 1]:02X}. This is the blank-ETA/blank-total field bug."
    )


@pytest.mark.parametrize("road_name,secondary,eta,remaining", [
    (False, False, False, False),  # minimal 8-TLV packet
    (False, False, True, False),   # + ETA
    (True, True, True, False),     # road name + secondary + ETA
    (False, False, False, True),   # + remaining time
    (True, True, True, True),      # everything
])
def test_total_distance_unit_immediately_follows_value(road_name, secondary, eta, remaining):
    order = make_active_nav_order(
        road_name=road_name, secondary=secondary, eta=eta, remaining=remaining
    )
    _assert_adjacent(order, SUB_TOTAL_DISTANCE, SUB_TOTAL_DISTANCE_UNIT)


@pytest.mark.parametrize("road_name,secondary,remaining", [
    (False, False, False),
    (True, True, False),
    (False, False, True),
    (True, True, True),
])
def test_eta_format_immediately_follows_eta(road_name, secondary, remaining):
    order = make_active_nav_order(
        road_name=road_name, secondary=secondary, eta=True, remaining=remaining
    )
    _assert_adjacent(order, SUB_ETA, SUB_ETA_FORMAT)


def test_minimal_packet_exact_order():
    """Pin the canonical 8-TLV order against the better-dash authority
    `build_active_nav_packet` (primary man/dist/unit → total → total-unit
    → decimal-sep → projection → decimal-flag)."""
    assert make_active_nav_order() == [
        (NAV_INFO, SUB_PRIMARY_MANEUVER),
        (NAV_INFO, SUB_PRIMARY_DISTANCE),
        (NAV_INFO, SUB_PRIMARY_UNIT),
        (NAV_INFO, SUB_TOTAL_DISTANCE),
        (NAV_INFO, SUB_TOTAL_DISTANCE_UNIT),
        (NAV_INFO, SUB_DECIMAL_SEPARATOR),
        (STATUS, SUB_PROJECTION_FLAG),
        (STATUS, SUB_DECIMAL_FLAG),
    ]


# ----------------------------------------------------------------------
# 2. Byte-level decode of a representative packet.
# ----------------------------------------------------------------------

def _seg(type_: int, sub: int, payload: bytes = b"\x00") -> Segment:
    return Segment(type=type_, sub=sub, payload=payload)


def test_decoded_packet_keeps_units_adjacent_to_values():
    """Build an envelope with the full ETA + total chain in the correct
    order, decode it back through fake_dash, and confirm the value→unit
    adjacency survives the wire round-trip."""
    order = make_active_nav_order(eta=True)
    segs = [_seg(t, sub, b"\x18\x32" if sub == SUB_ETA else b"\x00") for (t, sub) in order]
    pkt = build_envelope(segs)
    decoded = decode_packet(pkt)
    nav_subs = [s.sub for s in decoded if s.type == NAV_INFO]

    eta_i = nav_subs.index(SUB_ETA)
    assert nav_subs[eta_i + 1] == SUB_ETA_FORMAT
    tot_i = nav_subs.index(SUB_TOTAL_DISTANCE)
    assert nav_subs[tot_i + 1] == SUB_TOTAL_DISTANCE_UNIT


# ----------------------------------------------------------------------
# 3. Swift-source drift guard.
# ----------------------------------------------------------------------

# Map each tlv builder name to the sub-byte it emits, so we can reduce the
# literal `segs.append(tlv…())` call sequence in the Swift source to a
# sub-type stream and check adjacency without compiling Swift.
_BUILDER_SUB = {
    "tlvRoadName": SUB_ROAD_NAME,
    "tlvPrimaryManeuver": SUB_PRIMARY_MANEUVER,
    "tlvPrimaryDistance": SUB_PRIMARY_DISTANCE,
    "tlvPrimaryUnit": SUB_PRIMARY_UNIT,
    "tlvSecondaryManeuver": SUB_SECONDARY_MANEUVER,
    "tlvSecondaryDistance": SUB_SECONDARY_DISTANCE,
    "tlvSecondaryUnit": SUB_SECONDARY_UNIT,
    "tlvEta": SUB_ETA,
    "tlvEtaFormat": SUB_ETA_FORMAT,
    "tlvTotalDistance": SUB_TOTAL_DISTANCE,
    "tlvTotalDistanceUnit": SUB_TOTAL_DISTANCE_UNIT,
    "tlvDecimalSeparator": SUB_DECIMAL_SEPARATOR,
    "tlvRemainingTime": SUB_REMAINING_TIME,
    "tlvRemainingUnit": SUB_REMAINING_UNIT,
    "tlvProjectionFlag": SUB_PROJECTION_FLAG,
    "tlvDecimalFlag": SUB_DECIMAL_FLAG,
}


def _swift_make_active_nav_append_order() -> list[str]:
    """Extract the ordered builder-name sequence from the body of
    `makeActiveNav` in K1GPacket.swift. Robust to the optional-field
    `if let …` blocks: we only care about the textual order of the
    `tlv…(` calls inside the function body, which is exactly the emit
    order for whichever optionals are present."""
    src = _swift_packet_source()
    start = src.index("func makeActiveNav(")
    # Body ends at the `return encode(` that closes the function.
    end = src.index("return encode(segments: segs", start)
    body = src[start:end]
    # Distinguish builder *calls* from the `tlvTotalDistance` substring in
    # `tlvTotalDistanceUnit` by capturing the full identifier up to `(`.
    calls = re.findall(r"\b(tlv[A-Za-z]+)\s*\(", body)
    # Keep only ones we know how to map (skips e.g. nested helper calls).
    return [c for c in calls if c in _BUILDER_SUB]


def test_swift_source_emits_total_unit_after_total():
    names = _swift_make_active_nav_append_order()
    assert "tlvTotalDistance" in names and "tlvTotalDistanceUnit" in names
    i = names.index("tlvTotalDistance")
    assert names[i + 1] == "tlvTotalDistanceUnit", (
        "K1GPacket.makeActiveNav emits tlvTotalDistanceUnit out of order — "
        f"expected it right after tlvTotalDistance, got {names[i + 1]!r}. "
        "The dash will blank the total-distance field (6/2026 field bug)."
    )


def test_swift_source_emits_eta_format_after_eta():
    names = _swift_make_active_nav_append_order()
    assert "tlvEta" in names and "tlvEtaFormat" in names
    i = names.index("tlvEta")
    assert names[i + 1] == "tlvEtaFormat", (
        "K1GPacket.makeActiveNav emits tlvEtaFormat out of order — expected "
        f"it right after tlvEta, got {names[i + 1]!r}. The dash will blank "
        "the ETA field."
    )


def test_swift_append_order_matches_python_mirror():
    """The Swift source's full builder order (with all optionals present)
    must match the Python mirror, so the mirror stays a faithful twin."""
    names = _swift_make_active_nav_append_order()
    swift_subs = [_BUILDER_SUB[n] for n in names]
    mirror_subs = [
        sub for (_t, sub) in make_active_nav_order(
            road_name=True, secondary=True, eta=True, remaining=True
        )
    ]
    assert swift_subs == mirror_subs, (
        "Swift makeActiveNav order drifted from the Python mirror.\n"
        f"  Swift : {[hex(s) for s in swift_subs]}\n"
        f"  Mirror: {[hex(s) for s in mirror_subs]}"
    )
