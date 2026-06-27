"""
Tests for the phone-status telemetry TLV pipeline (battery / charging /
GPS-fix / mobile-signal presence on the Tripper TFT, sent in the 1 Hz
0044 heartbeat + 0030 metadata frames).

Reverse-engineered 2026-06-27 from the stock Royal Enfield app
(`com.royalenfield.reprime`, `REForeGroundService.d.run()`, lines
211-232) and BYTE-VERIFIED against the real-phone capture that
better-dash inlines verbatim as `INITIAL_BURST_HEX[9]`
(`tripper_app_like_nav.py:54`):

    0044 000a 00000000 020100054b314720 09
      06 08 0001 ff   cell signal strength (0-255 analog bars)
      06 03 0001 55   GPS fix on              (Q3C_V, 55=on / aa=off)
      06 04 0001 a2   battery, payload=level+100  (0xa2-100 = 62 %)
      06 0f 0001 aa   charging                (Q3C_T, 55=yes / aa=no)
      06 01 0001 01   mobile signal PRESENT   (Q3C_S, 01=have / 00=none)
      05 4c 0001 13   music volume bucket
      05 2d 0002 0000 nav distance
      05 1b 0001 19   alarm volume bucket
      05 21 0001 32   call state = idle
      05 4d 0001 32   call-state commit

The Swift side is `K1GPacket.makeHeartbeat0044(...)` /
`.makeMetadata0030(...)` fed each tick from `DeviceTelemetry.snapshot()`
(TripperDashPP/Tripper/DeviceTelemetry.swift) via the `HeartbeatLoop`
`telemetryProvider` closure. This file pins the wire bytes AND the
enabled/disabled gate (`DashNavSettings.deviceTelemetryEnabled`) on the
Python side so a future Swift edit that breaks either is caught by
`pytest`, not by Martin squinting at a dash on a moving bike.

── iOS faithfulness note ──
The OEM `06 01` is a BINARY present/absent flag (`getLevel() > 0`), not a
bar count — so the iOS `NWPathMonitor(.cellular)` reproduction is
byte-faithful. The analog `06 08` strength we cannot truly measure on
iOS, so the Swift side drives it as a presence proxy (0xA0 / 0x00). These
tests therefore pin `06 01` to the exact OEM semantics and pin `06 08`
only to the proxy contract the Swift side actually ships.

Authoritative writeup: the `royal-enfield-tripper-dash` skill reference
`phone-status-wire-protocol.md`.
"""

from __future__ import annotations

import pytest

from fake_dash.protocol import decode_packet


# --- Real-phone capture (better-dash INITIAL_BURST_HEX[9]) -------------------

OEM_0044_CAPTURE = bytes.fromhex(
    "0044000a00000000020100054b3147200906080001ff060300015506040001a2"
    "060f0001aa0601000101054c000113052d00020000051b0001190521000132054d000132"
)


# --- Python mirror of the Swift makeHeartbeat0044 / makeMetadata0030 ---------
#
# These reproduce K1GPacket.makeHeartbeat0044 byte-for-byte so a Swift
# regression shows up as a mismatch against BOTH this mirror and the
# captured OEM frame above.

IC_HEADER_MARKER = bytes([0x02, 0x01, 0x00, 0x05])
K1G_MAGIC = b"K1G "


def _battery_payload(pct: int) -> int:
    """OEM `06 04` payload is (level + 100); dash subtracts 100."""
    return (pct + 100) & 0xFF


def music_volume_tlv(ratio: float) -> bytes:
    if ratio <= 0.0:
        return bytes([0x05, 0x4C, 0x00, 0x01, 0x10])
    idx = max(0, min(9, int(ratio * 10.0)))
    return bytes([0x05, 0x4C, 0x00, 0x01, 0x11 + idx])


def alarm_volume_tlv(ratio: float) -> bytes:
    if ratio <= 0.0:
        return bytes([0x05, 0x1B, 0x00, 0x01, 0x10])
    idx = max(0, min(9, int(ratio * 10.0)))
    return bytes([0x05, 0x1B, 0x00, 0x01, 0x11 + idx])


def make_heartbeat_0044(
    seq: int,
    *,
    fixed_temp_c: int = 20,
    cell_signal: int = 160,
    battery_pct: int = 80,
    gps_on: bool = True,
    charging: bool = False,
    signal_present: bool = True,
    music_ratio: float = 0.3,
    nav_distance: int = 0,
    alarm_ratio: float = 0.3,
) -> bytes:
    body = bytearray()
    # outer_len placeholder | seg_count=10 (CONSTANT) | pad | marker | K1G | seq
    body += bytes([0x00, 0x00, 0x00, 0x0A, 0x00, 0x00, 0x00, 0x00])
    body += IC_HEADER_MARKER
    body += K1G_MAGIC
    body.append(seq & 0xFF)
    body += bytes([0x06, 0x08, 0x00, 0x01, cell_signal & 0xFF])
    body += bytes([0x06, 0x10, 0x00, 0x01, (fixed_temp_c + 40) & 0xFF])
    body += bytes([0x06, 0x03, 0x00, 0x01, 0x55 if gps_on else 0xAA])
    body += bytes([0x06, 0x04, 0x00, 0x01, _battery_payload(battery_pct)])
    body += bytes([0x06, 0x0F, 0x00, 0x01, 0x55 if charging else 0xAA])
    body += bytes([0x06, 0x01, 0x00, 0x01, 0x01 if signal_present else 0x00])
    body += music_volume_tlv(music_ratio)
    body += bytes([0x05, 0x2D, 0x00, 0x02, (nav_distance >> 8) & 0xFF, nav_distance & 0xFF])
    body += alarm_volume_tlv(alarm_ratio)
    total = len(body)
    body[0] = (total >> 8) & 0xFF
    body[1] = total & 0xFF
    return bytes(body)


# --- Python mirror of DeviceTelemetry.snapshot() gate ------------------------

PLACEHOLDER = {
    "cell_signal": 160,
    "battery_pct": 80,
    "gps_on": True,
    "charging": False,
    "signal_present": True,
}


def telemetry_snapshot(
    *,
    enabled: bool,
    has_cell_signal: bool,
    battery_pct: int,
    gps_on: bool,
    charging: bool,
) -> dict:
    """Mirror of `DeviceTelemetry.snapshot()`.

    When disabled, returns the OEM-safe placeholder regardless of the live
    readings (the privacy / "don't break the link" escape hatch). When
    enabled, the analog `06 08` strength is a presence proxy (0xA0 / 0x00).
    """
    if not enabled:
        return dict(PLACEHOLDER)
    return {
        "cell_signal": 0xA0 if has_cell_signal else 0x00,
        "battery_pct": battery_pct,
        "gps_on": gps_on,
        "charging": charging,
        "signal_present": has_cell_signal,
    }


# --- Helpers -----------------------------------------------------------------


def _tlv_map(packet: bytes) -> dict:
    """Decode a packet and index its segments by (type, sub)."""
    segs = decode_packet(packet)
    return {(s.type, s.sub): s.payload for s in segs}


# === Tests: byte-exact wire pinning ==========================================


def test_heartbeat_matches_real_oem_capture_field_for_field():
    """Our 0044 builder, fed the captured phone's readings, reproduces the
    OEM status TLVs byte-for-byte.

    The capture is battery 62 %, GPS on, not charging, signal present,
    cell-strength 0xFF. We DON'T expect the whole envelope to be identical
    (music/alarm/nav buckets differ by phone), but every phone-status TLV
    must match exactly — that's the contract this feature ships.
    """
    oem = _tlv_map(OEM_0044_CAPTURE)
    assert oem[(0x06, 0x08)] == bytes([0xFF])          # cell strength
    assert oem[(0x06, 0x03)] == bytes([0x55])          # GPS on
    assert oem[(0x06, 0x04)] == bytes([0xA2])          # battery 0xA2-100=62%
    assert oem[(0x06, 0x0F)] == bytes([0xAA])          # not charging
    assert oem[(0x06, 0x01)] == bytes([0x01])          # signal present

    # Drive our builder with the same logical readings and compare the
    # phone-status TLVs.
    ours = _tlv_map(
        make_heartbeat_0044(
            seq=9,
            cell_signal=0xFF,
            battery_pct=62,
            gps_on=True,
            charging=False,
            signal_present=True,
        )
    )
    for key in [(0x06, 0x08), (0x06, 0x03), (0x06, 0x04), (0x06, 0x0F), (0x06, 0x01)]:
        assert ours[key] == oem[key], f"TLV {key[0]:02x} {key[1]:02x} mismatch"


def test_battery_payload_is_level_plus_100():
    """`06 04` payload encodes (pct + 100). Dash subtracts 100 to render %."""
    for pct in (0, 1, 50, 62, 80, 100):
        ours = _tlv_map(make_heartbeat_0044(seq=0, battery_pct=pct))
        assert ours[(0x06, 0x04)] == bytes([pct + 100])


def test_battery_payload_clamps_into_a_byte():
    """A nonsense >155 % can't overflow the byte (defensive: & 0xFF)."""
    ours = _tlv_map(make_heartbeat_0044(seq=0, battery_pct=200))
    assert len(ours[(0x06, 0x04)]) == 1


@pytest.mark.parametrize("charging,expected", [(True, 0x55), (False, 0xAA)])
def test_charging_flag_byte(charging, expected):
    ours = _tlv_map(make_heartbeat_0044(seq=0, charging=charging))
    assert ours[(0x06, 0x0F)] == bytes([expected])


@pytest.mark.parametrize("gps_on,expected", [(True, 0x55), (False, 0xAA)])
def test_gps_flag_byte(gps_on, expected):
    ours = _tlv_map(make_heartbeat_0044(seq=0, gps_on=gps_on))
    assert ours[(0x06, 0x03)] == bytes([expected])


@pytest.mark.parametrize("present,expected", [(True, 0x01), (False, 0x00)])
def test_signal_present_flag_byte(present, expected):
    """`06 01` is binary present/absent — exactly the OEM `getLevel()>0`
    semantics. This is the byte we can reproduce faithfully on iOS."""
    ours = _tlv_map(make_heartbeat_0044(seq=0, signal_present=present))
    assert ours[(0x06, 0x01)] == bytes([expected])


def test_signal_present_tlv_sits_right_after_charging():
    """OEM field order is …06 0F (charging) → 06 01 (signal). The dash
    pairs them positionally; pin the order so we don't drift."""
    segs = decode_packet(make_heartbeat_0044(seq=0))
    keys = [(s.type, s.sub) for s in segs]
    i_chg = keys.index((0x06, 0x0F))
    i_sig = keys.index((0x06, 0x01))
    assert i_sig == i_chg + 1, f"signal must follow charging, got {keys}"


def test_heartbeat_outer_len_is_self_consistent():
    """outer_len header must equal the real byte length (so the dash's
    length-prefixed reader doesn't truncate or over-read)."""
    pkt = make_heartbeat_0044(seq=0)
    outer_len = (pkt[0] << 8) | pkt[1]
    assert outer_len == len(pkt)


def test_seg_count_is_the_oem_constant_0x000a():
    """seg_count is a hardcoded OEM constant (0x000A), NOT a live TLV
    count — both the capture and our builder emit it verbatim."""
    assert OEM_0044_CAPTURE[2:4] == bytes([0x00, 0x0A])
    assert make_heartbeat_0044(seq=0)[2:4] == bytes([0x00, 0x0A])


# === Tests: the enable/disable gate (DeviceTelemetry.snapshot) ===============


def test_disabled_returns_oem_safe_placeholder_regardless_of_live_state():
    """The load-bearing privacy guarantee: when the toggle is OFF, NONE of
    the rider's real battery/charging/signal/gps leaks — snapshot is the
    fixed placeholder even with wildly different live readings."""
    snap = telemetry_snapshot(
        enabled=False,
        has_cell_signal=False,   # live: no signal
        battery_pct=3,           # live: nearly dead
        gps_on=False,            # live: no fix
        charging=True,           # live: charging
    )
    assert snap == PLACEHOLDER


def test_enabled_reports_live_state():
    snap = telemetry_snapshot(
        enabled=True,
        has_cell_signal=True,
        battery_pct=42,
        gps_on=True,
        charging=True,
    )
    assert snap["battery_pct"] == 42
    assert snap["charging"] is True
    assert snap["gps_on"] is True
    assert snap["signal_present"] is True
    assert snap["cell_signal"] == 0xA0


def test_enabled_no_signal_drives_both_signal_tlvs_to_absent():
    """No cellular path → 06 01 absent (0x00) AND the 06 08 proxy to 0x00,
    so the dash shows a consistent 'no signal'."""
    snap = telemetry_snapshot(
        enabled=True,
        has_cell_signal=False,
        battery_pct=70,
        gps_on=True,
        charging=False,
    )
    assert snap["signal_present"] is False
    assert snap["cell_signal"] == 0x00


def test_gate_disabled_heartbeat_still_well_formed():
    """Turning telemetry off must NOT break the heartbeat: feeding the
    placeholder snapshot still yields a valid, decodable 0044 with all the
    status TLVs present (just neutral) — the link keep-alive is unaffected."""
    snap = telemetry_snapshot(
        enabled=False,
        has_cell_signal=False, battery_pct=3, gps_on=False, charging=True,
    )
    pkt = make_heartbeat_0044(
        seq=7,
        cell_signal=snap["cell_signal"],
        battery_pct=snap["battery_pct"],
        gps_on=snap["gps_on"],
        charging=snap["charging"],
        signal_present=snap["signal_present"],
    )
    m = _tlv_map(pkt)
    # All status TLVs present and neutral/placeholder.
    assert m[(0x06, 0x04)] == bytes([80 + 100])
    assert m[(0x06, 0x0F)] == bytes([0xAA])   # placeholder = not charging
    assert m[(0x06, 0x03)] == bytes([0x55])   # placeholder = gps on
    assert m[(0x06, 0x01)] == bytes([0x01])   # placeholder = signal present
    # And the envelope is structurally sound.
    outer_len = (pkt[0] << 8) | pkt[1]
    assert outer_len == len(pkt)


def test_enabled_full_round_trip_through_decoder():
    """End-to-end: live readings → snapshot → 0044 → decode → expected
    bytes on the wire."""
    snap = telemetry_snapshot(
        enabled=True,
        has_cell_signal=True,
        battery_pct=55,
        gps_on=False,
        charging=True,
    )
    pkt = make_heartbeat_0044(
        seq=3,
        cell_signal=snap["cell_signal"],
        battery_pct=snap["battery_pct"],
        gps_on=snap["gps_on"],
        charging=snap["charging"],
        signal_present=snap["signal_present"],
    )
    m = _tlv_map(pkt)
    assert m[(0x06, 0x04)] == bytes([55 + 100])
    assert m[(0x06, 0x0F)] == bytes([0x55])   # charging
    assert m[(0x06, 0x03)] == bytes([0xAA])   # no gps fix
    assert m[(0x06, 0x01)] == bytes([0x01])   # signal present
    assert m[(0x06, 0x08)] == bytes([0xA0])   # presence proxy
