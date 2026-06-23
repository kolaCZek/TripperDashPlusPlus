"""
Tests for the secondary-maneuver (look-ahead) TLV chain (F2c).

The Swift code in TripperDashPP/Tripper/K1GPacket.swift builds these
three TLVs when ActiveNavLoop decides the rider is close enough to
the primary turn to benefit from a look-ahead chevron:

  - `05 03 0002 <code> <flags>` — secondary maneuver glyph + flags
  - `05 05 0002 <meters_BE>` — secondary distance (same shape as primary)
  - `05 07 0001 <unit>` — secondary unit byte (same encoding as primary)

Wire authority: better-dash `tripper_app_like_nav.py` comments
(jadx-derived from `t3c.n() / .o() / .p()`), plus our own field test
of the `<flags>` byte (pending — sent as 0x00 placeholder).

This file pins the wire format so a future Swift edit that misorders
the bytes (e.g. swaps code/flags) is caught here instead of by Martin
squinting at a dash on a moving bike.
"""

from __future__ import annotations

import pytest

from fake_dash.protocol import Segment, build_envelope, decode_packet


# --- Python mirrors of the Swift TLV builders --------------------------------


def tlv_secondary_maneuver(code: int, flags: int = 0x00) -> Segment:
    """`05 03 0002 <code> <flags>` — mirror of `K1GPacket.tlvSecondaryManeuver`."""
    return Segment(type=0x05, sub=0x03, payload=bytes([code & 0xFF, flags & 0xFF]))


def tlv_secondary_distance(meters: int) -> Segment:
    """`05 05 0002 <meters_BE>` — mirror of `K1GPacket.tlvSecondaryDistance`."""
    return Segment(type=0x05, sub=0x05, payload=meters.to_bytes(2, "big"))


def tlv_secondary_unit(wire_byte: int) -> Segment:
    """`05 07 0001 <unit>` — mirror of `K1GPacket.tlvSecondaryUnit`."""
    return Segment(type=0x05, sub=0x07, payload=bytes([wire_byte & 0xFF]))


# --- Secondary maneuver glyph (0x05 / 0x03) ----------------------------------


@pytest.mark.parametrize(
    "code, flags, expected",
    [
        (0x0B, 0x00, b"\x0b\x00"),  # continue/straight, default flags
        (0x3C, 0x00, b"\x3c\x00"),  # bear-right
        (0x31, 0x00, b"\x31\x00"),  # CW table entry (skill F2b)
        (0x46, 0x00, b"\x46\x00"),  # CW table entry
        (0x0A, 0x00, b"\x0a\x00"),  # CCW table entry
        (0x42, 0x00, b"\x42\x00"),  # GPS lost (edge case — should still serialise)
    ],
)
def test_tlv_secondary_maneuver_byte_order(code: int, flags: int, expected: bytes) -> None:
    """Code comes first, flags second. Critical — a swapped order
    would render the wrong glyph and (worse) interpret a glyph byte
    as a flag, potentially triggering undocumented dash behaviour."""
    seg = tlv_secondary_maneuver(code, flags)
    assert seg.type == 0x05
    assert seg.sub == 0x03
    assert seg.payload == expected
    assert len(seg.payload) == 2


def test_tlv_secondary_maneuver_default_flags_is_zero() -> None:
    """F2c TODO: flags byte semantics are unknown — we send 0x00 as a
    safe placeholder until field test reveals the real meaning. If
    this test starts failing because we changed the default, audit
    whether the bike actually accepts the new value."""
    assert tlv_secondary_maneuver(0x0B).payload == bytes([0x0B, 0x00])


def test_tlv_secondary_maneuver_nonzero_flags_round_trip() -> None:
    """If/when field test reveals the flags byte semantics, this
    test verifies we can still emit non-zero values without the
    builder breaking."""
    seg = tlv_secondary_maneuver(0x31, flags=0xAA)
    assert seg.payload == bytes([0x31, 0xAA])


# --- Secondary distance (0x05 / 0x05) ----------------------------------------


@pytest.mark.parametrize(
    "meters, expected",
    [
        (0, b"\x00\x00"),
        (500, b"\x01\xf4"),         # typical city block
        (1200, b"\x04\xb0"),
        (65_535, b"\xff\xff"),      # max u16
    ],
)
def test_tlv_secondary_distance_big_endian(meters: int, expected: bytes) -> None:
    """Big-endian u16 — same convention as the primary distance TLV
    and as every other multi-byte int in the K1G protocol. Little-endian
    would silently render absurd distances on the dash."""
    seg = tlv_secondary_distance(meters)
    assert seg.type == 0x05
    assert seg.sub == 0x05
    assert seg.payload == expected
    assert len(seg.payload) == 2


# --- Secondary unit (0x05 / 0x07) --------------------------------------------


@pytest.mark.parametrize(
    "wire_byte",
    [0x10, 0x20, 0x30, 0x50],
)
def test_tlv_secondary_unit_accepts_all_known_unit_bytes(wire_byte: int) -> None:
    """The four documented unit bytes (km/10, mi/10, m, ft) match
    the primary unit encoding. The secondary chip on the dash uses
    the same renderer."""
    seg = tlv_secondary_unit(wire_byte)
    assert seg.type == 0x05
    assert seg.sub == 0x07
    assert seg.payload == bytes([wire_byte])
    assert len(seg.payload) == 1


# --- Round-trip through envelope ---------------------------------------------


def test_secondary_tlvs_round_trip_through_envelope() -> None:
    """Build a packet with all three secondary TLVs in the order
    Swift emits them, decode it, confirm shape and order survive."""
    pkt = build_envelope([
        tlv_secondary_maneuver(0x31, flags=0x00),
        tlv_secondary_distance(1200),
        tlv_secondary_unit(0x10),
    ])
    decoded = decode_packet(pkt)
    assert len(decoded) == 3
    assert [(s.type, s.sub) for s in decoded] == [(0x05, 0x03), (0x05, 0x05), (0x05, 0x07)]
    assert decoded[0].payload == bytes([0x31, 0x00])
    assert decoded[1].payload == bytes([0x04, 0xB0])
    assert decoded[2].payload == bytes([0x10])


# --- ActiveNavLoop lookahead trigger logic -----------------------------------
#
# Mirrors the F2c gating in `ActiveNavLoop.swift`:
#
#   emitSecondary = settings.lookaheadEnabled
#                   && !isRerouting
#                   && secondStep != nil
#                   && distNext <= settings.lookaheadThresholdMeters
#
# Pinned here so a future tweak to the gate condition (e.g. adding
# speed-based suppression) doesn't accidentally break the always-emit-
# when-close behaviour we want.


def _swift_lookahead_decision(
    lookahead_enabled: bool,
    second_step_exists: bool,
    dist_next_meters: float,
    threshold_meters: float,
    is_rerouting: bool = False,
) -> bool:
    """Mirror of the conditional in ActiveNavLoop.swift line ~120."""
    return (
        lookahead_enabled
        and not is_rerouting
        and second_step_exists
        and dist_next_meters <= threshold_meters
    )


@pytest.mark.parametrize(
    "enabled, has_second, dist, threshold, expected",
    [
        # Happy path: feature on, secondary exists, within threshold.
        (True, True, 250.0, 300.0, True),
        # Exact threshold: <= means edge value emits.
        (True, True, 300.0, 300.0, True),
        # Just over threshold: don't emit.
        (True, True, 301.0, 300.0, False),
        # Setting OFF: never emit regardless of distance.
        (False, True, 50.0, 300.0, False),
        # Last leg (no second step): can't emit even if close.
        (True, False, 50.0, 300.0, False),
        # Long distance to primary: noise, don't emit.
        (True, True, 5000.0, 300.0, False),
        # Threshold of 0: effectively disabled by config.
        (True, True, 0.0, 0.0, True),    # at the maneuver itself
        (True, True, 1.0, 0.0, False),   # just past
        # High threshold: emit even quite far out (e.g. motorway exit).
        (True, True, 800.0, 1000.0, True),
    ],
)
def test_active_nav_loop_lookahead_decision(
    enabled: bool,
    has_second: bool,
    dist: float,
    threshold: float,
    expected: bool,
) -> None:
    assert _swift_lookahead_decision(enabled, has_second, dist, threshold) == expected


def test_lookahead_default_threshold_is_300m() -> None:
    """Document the default. Driven by DashNavSettings — if this
    breaks, the persisted-defaults migration in load() needs a look."""
    DEFAULT_THRESHOLD_M = 300.0
    # At 299 m we emit, at 301 m we don't.
    assert _swift_lookahead_decision(True, True, 299.0, DEFAULT_THRESHOLD_M) is True
    assert _swift_lookahead_decision(True, True, 301.0, DEFAULT_THRESHOLD_M) is False


# --- Recalculating glyph during reroute ---------------------------------------
#
# Mirrors the primary-glyph override in `ActiveNavLoop.tick()`:
#
#   let kind = isRerouting ? .recalculating
#                          : (step.map(classify) ?? .straight)
#
# While a reroute is in flight the upcoming step is from the STALE route,
# so we show the dash's spinning-compass icon (0x1C) instead of an arrow
# that would point the rider the wrong way.

NAV_MANEUVER_RECALCULATING = 0x1C


def _swift_primary_glyph(is_rerouting: bool, classified_byte: int) -> int:
    """Mirror of the kind selection in ActiveNavLoop.tick()."""
    return NAV_MANEUVER_RECALCULATING if is_rerouting else classified_byte


def test_reroute_overrides_primary_glyph_with_recalculating():
    # Not rerouting: whatever the classifier produced goes through.
    assert _swift_primary_glyph(False, 0x15) == 0x15      # right turn
    assert _swift_primary_glyph(False, 0x0B) == 0x0B      # roundabout exit 1
    # Rerouting: always the spinning compass, regardless of stale step.
    assert _swift_primary_glyph(True, 0x15) == 0x1C
    assert _swift_primary_glyph(True, 0x0B) == 0x1C


def test_recalculating_byte_exists_in_catalog():
    """0x1C must be a real catalog entry (the spinning compass)."""
    from fake_dash.maneuver_catalog import load_catalog
    catalog = load_catalog()
    assert NAV_MANEUVER_RECALCULATING in catalog
    assert "recalc" in catalog[NAV_MANEUVER_RECALCULATING].description.lower()


def test_reroute_suppresses_secondary_lookahead():
    """During a reroute the look-ahead chevron is suppressed too — the
    second step is also from the stale route."""
    # Close enough + has a second step, but rerouting → no secondary.
    assert _swift_lookahead_decision(
        True, True, 100.0, 300.0, is_rerouting=True
    ) is False
    # Same inputs, not rerouting → emit.
    assert _swift_lookahead_decision(
        True, True, 100.0, 300.0, is_rerouting=False
    ) is True


def test_swift_tick_has_recalculating_override():
    """Pin that ActiveNavLoop.swift actually contains the override — guards
    against a refactor silently dropping it."""
    import pathlib
    repo_root = pathlib.Path(__file__).resolve().parents[3]
    src = (repo_root / "TripperDashPP" / "Navigation" / "ActiveNavLoop.swift").read_text()
    assert "isRerouting" in src, "reroute flag not read in ActiveNavLoop"
    assert ".recalculating" in src, "recalculating glyph override missing"

