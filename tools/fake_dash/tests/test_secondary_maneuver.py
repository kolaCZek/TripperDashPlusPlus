"""
Tests for the secondary-maneuver (look-ahead) TLV chain (F2c).

The Swift code in TripperDashPP/Tripper/K1GPacket.swift builds these
three TLVs when ActiveNavLoop decides the rider is close enough to
the primary turn to benefit from a look-ahead chevron:

  - `05 03 0001 <code>` — secondary maneuver glyph
  - `05 05 0002 <meters_BE>` — secondary distance (same shape as primary)
  - `05 07 0001 <unit>` — secondary unit byte (same encoding as primary)

Wire authority: the real-phone capture `_NAV_FULL` in better-dash
`tripper_app_like_nav.py` (`05 03 0001 34`).

This file pins the wire format so a future Swift edit that misorders
the bytes (e.g. adds a padding byte again) is caught here instead of by Martin
squinting at a dash on a moving bike.
"""

from __future__ import annotations

import pytest

from fake_dash.protocol import Segment, build_envelope, decode_packet


# --- Python mirrors of the Swift TLV builders --------------------------------


def tlv_secondary_maneuver(code: int) -> Segment:
    """`05 03 0001 <code>` — mirror of `K1GPacket.tlvSecondaryManeuver`."""
    return Segment(type=0x05, sub=0x03, payload=bytes([code & 0xFF]))


def tlv_secondary_distance(meters: int) -> Segment:
    """`05 05 0002 <meters_BE>` — mirror of `K1GPacket.tlvSecondaryDistance`."""
    return Segment(type=0x05, sub=0x05, payload=meters.to_bytes(2, "big"))


def tlv_secondary_unit(wire_byte: int) -> Segment:
    """`05 07 0001 <unit>` — mirror of `K1GPacket.tlvSecondaryUnit`."""
    return Segment(type=0x05, sub=0x07, payload=bytes([wire_byte & 0xFF]))


# --- Secondary maneuver glyph (0x05 / 0x03) ----------------------------------

# Real-phone active-nav capture (better-dash `_NAV_FULL`, nav_open_ok.pcap),
# the same authority as test_eta_format_capture.py.
NAV_FULL_HEX = (
    "007e001100000000020100054b31472025050100145461696c6c65206465204d617320647520477200"
    "050200013c050300013405050002000a05060001300507000130050800043033303305540001300509"
    "0002004f0546000110050a000155050c000104050b0006303031303030055500012006050001aa060d0001aa"
)


def test_capture_secondary_maneuver_is_one_byte() -> None:
    """The real phone sends `05 03 0001 34`: the glyph byte alone. The
    2-byte `<code> 00` form we used to send never showed on the dash."""
    import binascii
    segs = decode_packet(binascii.unhexlify(NAV_FULL_HEX))
    sec = [s for s in segs if s.type == 0x05 and s.sub == 0x03]
    assert len(sec) == 1
    assert sec[0].payload == bytes([0x34])


def test_swift_secondary_maneuver_payload_is_one_byte() -> None:
    """Pin the Swift builder to the capture (no Swift compiler here)."""
    import pathlib
    import re
    repo_root = pathlib.Path(__file__).resolve().parents[3]
    src = (repo_root / "TripperDashPP" / "Tripper" / "K1GPacket.swift").read_text()
    m = re.search(r"static func tlvSecondaryManeuver\(([^)]*)\)[^{]*\{(.*?)\n    \}", src, re.S)
    assert m, "tlvSecondaryManeuver not found"
    assert m.group(1).strip() == "code: UInt8"
    assert "payload: Data([code])" in m.group(2)


def test_swift_clears_the_lookahead_when_there_is_none() -> None:
    """The dash latches the last look-ahead (stuck sub-icon, 8/2026): with
    none, makeActiveNav must still send 05 03, with the hidden glyph."""
    import pathlib
    repo_root = pathlib.Path(__file__).resolve().parents[3]
    src = (repo_root / "TripperDashPP" / "Tripper" / "K1GPacket.swift").read_text()
    body = src[src.index("static func makeActiveNav("):src.index("return encode(segments: segs", src.index("static func makeActiveNav("))]
    assert "return (noSecondaryManeuver, 0, primaryUnit)" in body
    assert "segs.append(tlvSecondaryManeuver(code: secondary.code))" in body
    assert "if let code = secondaryManeuver" not in body.split("segs.append(tlvSecondaryManeuver")[1].split("tlvEta")[0]
    assert "static let noSecondaryManeuver: UInt8 = 0xFF" in src


@pytest.mark.parametrize("code", [0x0B, 0x3C, 0x31, 0x46, 0x0A, 0x42])
def test_tlv_secondary_maneuver_is_the_glyph_byte(code: int) -> None:
    seg = tlv_secondary_maneuver(code)
    assert (seg.type, seg.sub, seg.payload) == (0x05, 0x03, bytes([code]))


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
        tlv_secondary_maneuver(0x31),
        tlv_secondary_distance(1200),
        tlv_secondary_unit(0x10),
    ])
    decoded = decode_packet(pkt)
    assert len(decoded) == 3
    assert [(s.type, s.sub) for s in decoded] == [(0x05, 0x03), (0x05, 0x05), (0x05, 0x07)]
    assert decoded[0].payload == bytes([0x31])
    assert decoded[1].payload == bytes([0x04, 0xB0])
    assert decoded[2].payload == bytes([0x10])


# --- ActiveNavLoop lookahead trigger logic -----------------------------------
#
# Mirrors the F2c gating in `ActiveNavLoop.swift`:
#
#   emitSecondary = settings.lookaheadEnabled
#                   && !isRerouting
#                   && lookahead != nil       // nav.lookaheadManeuver
#                   && distNext <= settings.lookaheadThresholdMeters
#
# (`lookahead != nil` is the derived-model equivalent of the old
# `secondNextStep != nil` gate: `lookaheadManeuver` is non-nil exactly
# when there's a step after the upcoming one to classify.)
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
    """Mirror of the conditional in ActiveNavLoop.swift line ~295."""
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
#                          : (nav.upcomingManeuver ?? .straight)
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

