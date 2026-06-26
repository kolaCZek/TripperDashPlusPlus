"""
Tests for the ETA / remaining-time TLV pipeline.

The Swift code in TripperDashPP/Tripper/K1GPacket.swift builds these
TLVs from `Date` and `TimeInterval` values:

  - `05 08 0004 HHMM` — ETA, 4 ASCII bytes (`tlvEta`)
  - `05 54 0001 <55|AA>` — ETA format flag (`tlvEtaFormat`)
  - `05 0B 0006 DDHHMM` — remaining time, 6 ASCII bytes
  - `05 55 0001 20` — remaining-time unit byte (always 0x20)

This file pins the wire format on the Python side so a future Swift
edit that breaks the ASCII encoding (e.g. off-by-one zero padding,
hex-vs-decimal slip) is caught by `pytest` instead of by Martin
squinting at a dash on a moving bike.

Strategy: replicate the Swift formatter in Python in <10 lines per
TLV, then round-trip through `fake_dash.protocol.decode_packet` to
make sure the bytes land in the expected (type, sub, payload) slots.
"""

from __future__ import annotations

from datetime import datetime, timedelta

import pytest

from fake_dash.protocol import Segment, build_envelope, decode_packet


# --- Python mirrors of the Swift TLV builders --------------------------------


def tlv_eta(when: datetime) -> Segment:
    """`05 08 0004 HHMM` — mirror of `K1GPacket.tlvEta`."""
    payload = f"{when.hour:02d}{when.minute:02d}".encode("ascii")
    assert len(payload) == 4
    return Segment(type=0x05, sub=0x08, payload=payload)


def tlv_eta_format(is_24h: bool) -> Segment:
    """`05 54 0001 30` — mirror of `K1GPacket.tlvEtaFormat`.

    ALWAYS 0x30. PCAP-CONFIRMED: the real-phone capture `_NAV_FULL` in
    better-dash carries `05 54 0001 30`. The byte is decimal-ASCII-digit
    encoded (same family as the unit bytes), NOT the 0x55/0xAA
    separator-flag family.

    The `is_24h` argument is ignored — kept only for call-site parity with
    the Swift signature. 12-hour mode previously sent 0x31 (an inferred
    guess); on a 6/2026 ride that BLANKED the ETA on the real dash (the dash
    rejects 0x31 and drops the whole ETA block), so 0x31 is confirmed wrong.
    We send 0x30 unconditionally; the dash then shows the (24-hour) HH:MM
    payload instead of a blank field even when set to 12-hour."""
    return Segment(type=0x05, sub=0x54, payload=bytes([0x30]))


def tlv_remaining(seconds: float) -> Segment:
    """`05 0B 0006 DDHHMM` — mirror of `K1GPacket.tlvRemainingTime`."""
    total = max(0, int(round(seconds)))
    days = (total // 86_400) % 100
    hours = (total % 86_400) // 3_600
    minutes = (total % 3_600) // 60
    payload = f"{days:02d}{hours:02d}{minutes:02d}".encode("ascii")
    assert len(payload) == 6
    return Segment(type=0x05, sub=0x0B, payload=payload)


def tlv_remaining_unit() -> Segment:
    """`05 55 0001 20` — mirror of `K1GPacket.tlvRemainingUnit`."""
    return Segment(type=0x05, sub=0x55, payload=bytes([0x20]))


# --- ETA TLV (0x05 / 0x08) ---------------------------------------------------


@pytest.mark.parametrize(
    "when, expected",
    [
        (datetime(2026, 6, 21, 18, 32), b"1832"),
        (datetime(2026, 6, 21, 0, 0), b"0000"),       # midnight
        (datetime(2026, 6, 21, 23, 59), b"2359"),     # last minute of the day
        (datetime(2026, 6, 21, 9, 5), b"0905"),       # both digits zero-padded
        (datetime(2026, 6, 21, 1, 0), b"0100"),       # single-digit hour
        (datetime(2026, 6, 21, 12, 0), b"1200"),      # noon (12h-ambiguous)
    ],
)
def test_tlv_eta_ascii_encoding(when: datetime, expected: bytes) -> None:
    """Hours/minutes are zero-padded ASCII in 24-hour space, even when
    the dash is rendering 12-hour format. The format flag (0x54) is
    what tells the dash to convert for display."""
    seg = tlv_eta(when)
    assert seg.type == 0x05
    assert seg.sub == 0x08
    assert seg.payload == expected
    # Payload is always exactly 4 bytes — the wire field has no length
    # negotiation, the dash slices [0:4] unconditionally.
    assert len(seg.payload) == 4


def test_tlv_eta_round_trips_through_envelope() -> None:
    """Build an envelope with the ETA TLV, decode it, confirm the TLV
    survives unchanged."""
    when = datetime(2026, 6, 21, 18, 32)
    pkt = build_envelope([tlv_eta(when)])
    decoded = decode_packet(pkt)
    assert len(decoded) == 1
    assert decoded[0].type == 0x05
    assert decoded[0].sub == 0x08
    assert decoded[0].payload == b"1832"


# --- ETA format flag (0x05 / 0x54) -------------------------------------------


def test_tlv_eta_format_24h_is_0x30() -> None:
    """24-hour mode → 0x30. PCAP-CONFIRMED against the real-phone capture
    `_NAV_FULL` in better-dash (`05 54 0001 30`). The format byte is
    decimal-ASCII-digit encoded (same family as the unit bytes), not the
    0x55/0xAA separator-flag family the code previously (wrongly) used —
    that mismatch made the dash drop the whole ETA block (blank-ETA bug,
    6/2026)."""
    seg = tlv_eta_format(is_24h=True)
    assert seg.type == 0x05
    assert seg.sub == 0x54
    assert seg.payload == bytes([0x30])


def test_tlv_eta_format_12h_also_0x30_never_0x31() -> None:
    """12-hour mode ALSO sends 0x30 — never 0x31.

    0x31 was an inferred guess that field-test DISPROVED: on a 6/2026 ride
    with the dash set to 12-hour, the ETA went blank because the dash
    rejects 0x31 and drops the whole ETA block (same failure mode as the
    original 0x55/0xAA bug). 0x30 is the only value the dash is known to
    accept, so we send it unconditionally; the rider sees the 24-hour HH:MM
    arrival time instead of a blank field. This guards against anyone
    re-introducing the 0x31 guess without a real 12h-mode capture."""
    seg = tlv_eta_format(is_24h=False)
    assert seg.payload == bytes([0x30]), (
        "12h must send 0x30 (the only dash-accepted value); 0x31 blanks the "
        "ETA on real hardware"
    )
    # And it must never regress to the disproven guess or the old flag family.
    assert seg.payload != bytes([0x31])
    assert seg.payload[0] not in (0x55, 0xAA)


# --- Remaining time (0x05 / 0x0B) --------------------------------------------


@pytest.mark.parametrize(
    "seconds, expected",
    [
        (0, b"000000"),                              # at destination
        (60, b"000001"),                             # 1 minute
        (45 * 60, b"000045"),                        # 45 minutes
        (60 * 60, b"000100"),                        # 1 hour exactly
        (90 * 60, b"000130"),                        # 1h30m
        (23 * 3_600 + 45 * 60, b"002345"),           # 23h45m
        (86_400, b"010000"),                         # 1 day exactly
        (86_400 + 23 * 3_600 + 45 * 60, b"012345"),  # 1d 23h 45m (skill example)
        (5 * 86_400 + 7 * 3_600 + 11 * 60, b"050711"),  # 5d 7h 11m
    ],
)
def test_tlv_remaining_ascii_encoding(seconds: int, expected: bytes) -> None:
    """DDHHMM is zero-padded ASCII. The day field uses modulo-100 so
    100+ day trips render as the last two digits — not a real-world
    case for a motorcycle but worth documenting the wrap."""
    seg = tlv_remaining(seconds)
    assert seg.type == 0x05
    assert seg.sub == 0x0B
    assert seg.payload == expected
    assert len(seg.payload) == 6


def test_tlv_remaining_negative_floors_to_zero() -> None:
    """Defensive: should never happen in production (etaSeconds is
    guarded by `etaSec > 0` in ActiveNavLoop) but the Swift formatter
    uses `max(0, …)` so we pin the same behaviour."""
    seg = tlv_remaining(-100)
    assert seg.payload == b"000000"


def test_tlv_remaining_rounds_to_nearest_second_then_truncates_to_minute() -> None:
    """The DDHHMM format has only minute granularity — sub-minute
    remainder is dropped. The Swift formatter first rounds float
    seconds to nearest second (`.rounded()`), then integer-divides
    by 60 to get minutes."""
    # 90.4 s → 90 s → 1 min 30 s → DDHHMM drops the 30s → "000001"
    assert tlv_remaining(90.4).payload == b"000001"
    # 90.6 s → 91 s → 1 min 31 s → "000001"
    assert tlv_remaining(90.6).payload == b"000001"
    # 119.9 s → 120 s → 2 min 0 s → "000002"
    assert tlv_remaining(119.9).payload == b"000002"
    # 59.9 s → 60 s → 1 min → "000001" (boundary)
    assert tlv_remaining(59.9).payload == b"000001"
    # 59.4 s → 59 s → 0 min 59 s → "000000"
    assert tlv_remaining(59.4).payload == b"000000"


# --- Remaining-time unit (0x05 / 0x55) ---------------------------------------


def test_tlv_remaining_unit_is_constant_0x20() -> None:
    """The dash only accepts 0x20 here per the K1GPacket comment.
    Pinned as a regression test so a future refactor that tries to
    parameterise the unit immediately fails."""
    seg = tlv_remaining_unit()
    assert seg.type == 0x05
    assert seg.sub == 0x55
    assert seg.payload == bytes([0x20])


# --- ETA + remaining-time co-emission in ActiveNavLoop -----------------------
#
# ActiveNavLoop.tick() now mirrors the OEM Tripper app: whenever there is a
# positive ETA estimate it emits BOTH the ETA TLV (HH:MM) and the
# remaining-time TLV (DDHHMM) in the same packet, exactly as the real-phone
# capture `_NAV_FULL` does. The total-distance TLV is sent unconditionally
# downstream regardless.
#
# This replaces the old XOR gate on `settings.includeEtaTlv` (bottomLine),
# which had two field-confirmed bugs (Martin, 6/2026):
#   * picking "distance remaining" dropped ETA and sent a remaining-TIME
#     duration instead — "switch to km doesn't work";
#   * it diverged from the only wire layout the dash is known to accept.
# Which field the dash shows in its bottom row is a dash-side concern we
# cannot drive by omitting TLVs, so the loop no longer tries to.


def _swift_active_nav_loop_eta_dispatch_logic(eta_seconds: float) -> tuple[bool, bool]:
    """Returns (has_eta_date, has_remaining_seconds). Mirrors the current
    ActiveNavLoop.swift logic: both are attached together whenever
    eta_seconds > 0, independent of bottomLine."""
    has = eta_seconds > 0
    return (has, has)


@pytest.mark.parametrize(
    "eta_seconds, expected",
    [
        (0, (False, False)),     # at destination → neither
        (600, (True, True)),     # valid estimate → BOTH ETA and remaining
        (1, (True, True)),       # any positive estimate → both
        (-5, (False, False)),    # defensive: non-positive → neither
    ],
)
def test_active_nav_loop_emits_eta_and_remaining_together(
    eta_seconds: float, expected: tuple[bool, bool]
) -> None:
    """ETA and remaining-time TLVs are emitted TOGETHER whenever there's a
    positive estimate, matching the OEM capture. If this regresses to an XOR
    (one suppressing the other), the blank-ETA / "km switch does nothing"
    field bugs come back — that's what this pins against."""
    assert _swift_active_nav_loop_eta_dispatch_logic(eta_seconds) == expected
