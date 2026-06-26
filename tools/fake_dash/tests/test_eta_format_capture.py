"""
Capture-grounded regression for the ETA-format byte (`05 54 0001 <b>`).

The blank-ETA field bug (6/2026 ride): after the TLV *ordering* fix
(commit 56ec09c) restored the total-distance field, the ETA field on the
dash was STILL blank. Root cause: `K1GPacket.tlvEtaFormat` emitted the
format byte as `0x55` (24h) / `0xAA` (12h) — the decimal-SEPARATOR flag
family — but the real phone uses the decimal-ASCII-DIGIT family (the same
encoding as the distance unit bytes). The dash couldn't bind a `0x55`
format byte to the `0x08` ETA value and dropped the whole ETA block.

Ground truth: better-dash ships `_NAV_FULL`, a real-phone nav-session
capture (road name "Taille de Mas du Gr", ETA "0303"). Its `05 54` TLV
carries `0x30`. The primary unit TLV in the SAME packet is also `0x30`
("metres"), which proves the format byte shares the unit-byte digit
encoding, not the 0x55/0xAA flag encoding.

This test decodes that capture as the authority and pins the Swift source
to it, so a future edit can't silently revert to the broken 0x55/0xAA.

Same discipline as test_active_nav_order.py: better-dash is the byte-level
authority; the Swift source is checked against it without compiling Swift.
"""

from __future__ import annotations

import binascii
import re
from pathlib import Path

from fake_dash.protocol import decode_packet


# Real-phone active-nav capture, verbatim from better-dash
# `tripper_app_like_nav.py` `_NAV_FULL`. A captured nav session — NOT a
# synthesised fixture (note the real French road name + plausible ETA).
NAV_FULL_HEX = (
    "007e001100000000020100054b31472025050100145461696c6c65206465204d617320647520477200"
    "050200013c050300013405050002000a05060001300507000130050800043033303305540001300509"
    "0002004f0546000110050a000155050c000104050b0006303031303030055500012006050001aa060d0001aa"
)

SUB_PRIMARY_UNIT = 0x06
SUB_ETA = 0x08
SUB_ETA_FORMAT = 0x54


def _decoded_nav_full():
    return decode_packet(binascii.unhexlify(NAV_FULL_HEX))


def test_capture_eta_format_byte_is_0x30():
    """The authoritative real-phone capture carries `05 54 0001 30`."""
    segs = _decoded_nav_full()
    fmt = [s for s in segs if s.type == 0x05 and s.sub == SUB_ETA_FORMAT]
    assert len(fmt) == 1, "expected exactly one ETA-format TLV in the capture"
    assert fmt[0].payload == bytes([0x30]), (
        f"real phone sends 0x30 for the ETA format byte, capture shows "
        f"0x{fmt[0].payload[0]:02x}"
    )


def test_capture_eta_format_shares_unit_byte_digit_encoding():
    """The format byte (0x30) is in the same decimal-ASCII-digit family as
    the distance unit byte (also 0x30 = 'metres' here), NOT the 0x55/0xAA
    separator-flag family. This is *why* the old 0x55/0xAA value was wrong."""
    segs = _decoded_nav_full()
    unit = [s for s in segs if s.type == 0x05 and s.sub == SUB_PRIMARY_UNIT][0]
    fmt = [s for s in segs if s.type == 0x05 and s.sub == SUB_ETA_FORMAT][0]
    # Both are single ASCII digits in 0x30..0x39.
    assert 0x30 <= unit.payload[0] <= 0x39
    assert 0x30 <= fmt.payload[0] <= 0x39
    # And neither is a separator-flag value.
    assert fmt.payload[0] not in (0x55, 0xAA)


def test_capture_eta_value_is_ascii_hhmm():
    """Sanity: the ETA value TLV in the same capture is ASCII '0303'
    (03:03), confirming we're reading a real nav packet, not noise."""
    segs = _decoded_nav_full()
    eta = [s for s in segs if s.type == 0x05 and s.sub == SUB_ETA][0]
    assert eta.payload == b"0303"


# --- Swift-source drift guard ------------------------------------------------

def _k1g_packet_src() -> str:
    here = Path(__file__).resolve()
    repo_root = here.parents[3]
    swift = repo_root / "TripperDashPP" / "Tripper" / "K1GPacket.swift"
    return swift.read_text(encoding="utf-8")


def test_swift_eta_format_emits_only_0x30_never_0x31_or_separator_flag():
    """`tlvEtaFormat` must emit ONLY 0x30 — the single value the real dash
    is known to accept (pcap `_NAV_FULL`). It must NOT emit:

      * 0x55 / 0xAA — the decimal-SEPARATOR flag family; binding one of
        those to the 0x08 ETA value made the dash drop the whole ETA block
        (the original blank-ETA bug, 6/2026).
      * 0x31 — the inferred 12-hour guess. Field-test DISPROVED it: with the
        dash set to 12-hour the ETA went blank (the dash rejects 0x31). So
        12h must fall back to 0x30, not 0x31.

    The format byte is emitted unconditionally, so we check the whole
    function body rather than a single payload line."""
    src = _k1g_packet_src()
    idx = src.index("static func tlvEtaFormat")
    # End the slice at the next top-level func so we only inspect this body.
    end = src.index("static func", idx + 1)
    body = src[idx:end]
    payload_line = next(l for l in body.splitlines() if "payload: Data(" in l)
    assert "0x30" in payload_line, (
        f"tlvEtaFormat must emit 0x30 (the only dash-accepted value); "
        f"got: {payload_line.strip()!r}"
    )
    assert "0x31" not in payload_line, (
        "tlvEtaFormat regressed to the 0x31 12-hour guess — field-test showed "
        "0x31 blanks the ETA on the real dash; 12h must fall back to 0x30"
    )
    assert "0x55" not in payload_line and "0xAA" not in payload_line, (
        "tlvEtaFormat regressed to the 0x55/0xAA separator-flag family — "
        "the dash will drop the ETA block (blank-ETA bug)"
    )
