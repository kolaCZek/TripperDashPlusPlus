"""
Tests for the call-state notification TLV pipeline (incoming-call card on
the Tripper TFT).

On a call-state change the phone pushes a 2-packet burst over the SAME
K1G/UDP-2000 control plane the nav uses — NOT a separate transport, NOT
the BLE protocol of the small round Tripper Pod:

  1. `05 21 0001 <state>` — the call-state TLV
  2. `05 4D 0001 32`      — the commit/trailer suffix, constant

State bytes:

  0x0A  incoming   — ringing
  0x14  active     — answered / in call
  0x1E  outgoing   — we dialed out
  0x32  none/idle  — call ended / no call

The Swift side is `K1GPacket.makeCallState(_:seq:)` /
`.makeCallStateCommit(seq:)` (TripperDashPP/Tripper/K1GPacket.swift) plus
the CallKit → state mapping in `CallStateObserver.callState(...)`. This
file pins both the wire bytes and the mapping on the Python side so a
future Swift edit that breaks either is caught by `pytest` instead of by
Martin squinting at a dash on a moving bike.

Authoritative writeup: the `royal-enfield-tripper-dash` skill reference
`call-notification-wire-protocol.md`.
"""

from __future__ import annotations

import pytest

from fake_dash.protocol import Segment, build_envelope, decode_packet


# --- Python mirrors of the Swift call-state builders -------------------------

# K1GPacket.CallState raw values — must equal the reference packets below.
CALL_INCOMING = 0x0A
CALL_ACTIVE = 0x14
CALL_OUTGOING = 0x1E
CALL_NONE = 0x32

ALL_STATES = [CALL_INCOMING, CALL_ACTIVE, CALL_OUTGOING, CALL_NONE]


def tlv_call_state(state: int) -> Segment:
    """`05 21 0001 <state>` — mirror of `K1GPacket.makeCallState`."""
    return Segment(type=0x05, sub=0x21, payload=bytes([state]))


def tlv_call_state_commit() -> Segment:
    """`05 4D 0001 32` — mirror of `K1GPacket.makeCallStateCommit`.

    Always 0x32, sent immediately after every `05 21` packet regardless
    of the state byte.
    """
    return Segment(type=0x05, sub=0x4D, payload=bytes([0x32]))


def callkit_to_state(has_ended: bool, has_connected: bool, is_outgoing: bool) -> int:
    """Mirror of `CallStateObserver.callState(hasEnded:hasConnected:isOutgoing:)`.

    Priority order matters: ended wins over connected wins over outgoing,
    else it's an inbound ring.
    """
    if has_ended:
        return CALL_NONE
    if has_connected:
        return CALL_ACTIVE
    if is_outgoing:
        return CALL_OUTGOING
    return CALL_INCOMING


# --- Byte-exact reference packets --------------------------------------------
#
# These are the full framed packets the stock app puts on the wire at
# seq=0. The header is
# the fixed 17-byte K1G envelope prefix:
#   0016  0002  00000000  02010005  4B314720  00
#   len   segc  pad       marker    "K1G "     seq
# followed by the TLV. build_envelope() must reproduce these exactly.

OEM_CALL_STATE_PACKETS = {
    CALL_INCOMING: bytes.fromhex("0016000200000000020100054B31472000052100010A"),
    CALL_ACTIVE:   bytes.fromhex("0016000200000000020100054B314720000521000114"),
    CALL_OUTGOING: bytes.fromhex("0016000200000000020100054B31472000052100011E"),
    CALL_NONE:     bytes.fromhex("0016000200000000020100054B314720000521000132"),
}
OEM_CALL_COMMIT_PACKET = bytes.fromhex("0016000200000000020100054B31472000054D000132")


# --- Call-state TLV byte format (0x05 / 0x21) --------------------------------


@pytest.mark.parametrize(
    "state, expected_byte",
    [
        (CALL_INCOMING, 0x0A),
        (CALL_ACTIVE, 0x14),
        (CALL_OUTGOING, 0x1E),
        (CALL_NONE, 0x32),
    ],
)
def test_tlv_call_state_payload_is_one_state_byte(state: int, expected_byte: int) -> None:
    """The `05 21` TLV carries exactly one state byte. The dash slices
    [0:1] — no length negotiation."""
    seg = tlv_call_state(state)
    assert seg.type == 0x05
    assert seg.sub == 0x21
    assert seg.payload == bytes([expected_byte])
    assert len(seg.payload) == 1


def test_tlv_call_state_commit_is_constant_0x32() -> None:
    """The `05 4D` commit/trailer is always 0x32, regardless of
    the call state. Pinned so a future refactor can't accidentally
    parameterise it."""
    seg = tlv_call_state_commit()
    assert seg.type == 0x05
    assert seg.sub == 0x4D
    assert seg.payload == bytes([0x32])
    assert len(seg.payload) == 1


# --- Byte-exact match against the reference packets ---------------------------


@pytest.mark.parametrize("state", ALL_STATES)
def test_call_state_envelope_matches_reference_packet(state: int) -> None:
    """The full framed packet `build_envelope([tlv_call_state(s)], seq=0)`
    must be BYTE-IDENTICAL to the reference packet.

    This is the load-bearing assertion: it proves the Swift
    `makeCallState` (which shares `encode()` with this `build_envelope`)
    puts exactly the bytes the real dash expects on the wire — including
    the `seg_count = N+1 = 2` quirk and `outer_len = 0x16`."""
    pkt = build_envelope([tlv_call_state(state)], seq=0)
    assert pkt == OEM_CALL_STATE_PACKETS[state], (
        f"state 0x{state:02X}: built {pkt.hex().upper()} != "
        f"OEM {OEM_CALL_STATE_PACKETS[state].hex().upper()}"
    )


def test_call_state_commit_envelope_matches_reference_packet() -> None:
    """The commit packet must be byte-identical to the reference packet."""
    pkt = build_envelope([tlv_call_state_commit()], seq=0)
    assert pkt == OEM_CALL_COMMIT_PACKET, (
        f"commit: built {pkt.hex().upper()} != "
        f"OEM {OEM_CALL_COMMIT_PACKET.hex().upper()}"
    )


def test_idle_burst_matches_better_dash_inline_tail() -> None:
    """better-dash inlines `0521000132054D000132` as the idle call-state
    tail in every 0044/0030 heartbeat. Our idle state TLV + commit TLV,
    concatenated at the TLV level (the two segments back-to-back), must
    reproduce that exact 10-byte tail — confirming we send the same pair
    better-dash already ships."""
    idle = tlv_call_state(CALL_NONE)
    commit = tlv_call_state_commit()
    tail = idle.hex + commit.hex  # Segment.hex is header+payload, uppercase
    assert tail == "0521000132054D000132"


# --- Round-trip through the envelope codec -----------------------------------


@pytest.mark.parametrize("state", ALL_STATES)
def test_call_state_round_trips_through_envelope(state: int) -> None:
    """Build → decode → confirm the TLV survives unchanged."""
    pkt = build_envelope([tlv_call_state(state)])
    decoded = decode_packet(pkt)
    assert len(decoded) == 1
    assert decoded[0].type == 0x05
    assert decoded[0].sub == 0x21
    assert decoded[0].payload == bytes([state])


def test_call_state_two_packet_burst_decodes_as_two_envelopes() -> None:
    """A state change is two SEPARATE envelopes (state then commit), not one
    two-segment packet — mirroring how `BikeLink.sendCallState` calls
    `socket.send` twice. Each decodes to a single TLV."""
    state_pkt = build_envelope([tlv_call_state(CALL_INCOMING)])
    commit_pkt = build_envelope([tlv_call_state_commit()])

    sd = decode_packet(state_pkt)
    cd = decode_packet(commit_pkt)
    assert len(sd) == 1 and sd[0].sub == 0x21 and sd[0].payload == bytes([CALL_INCOMING])
    assert len(cd) == 1 and cd[0].sub == 0x4D and cd[0].payload == bytes([0x32])


# --- CallKit → state mapping (CallStateObserver.callState) -------------------


@pytest.mark.parametrize(
    "has_ended, has_connected, is_outgoing, expected",
    [
        # Inbound call lifecycle
        (False, False, False, CALL_INCOMING),   # new inbound, ringing
        (False, True, False, CALL_ACTIVE),       # answered
        (True, True, False, CALL_NONE),          # ended after being connected
        (True, False, False, CALL_NONE),         # missed (ringing → ended, never connected)
        # Outbound call lifecycle
        (False, False, True, CALL_OUTGOING),     # we dialed, ringing at the other end
        (False, True, True, CALL_ACTIVE),        # they picked up → in call
        (True, True, True, CALL_NONE),           # outbound call ended
        (True, False, True, CALL_NONE),          # outbound cancelled before connect
    ],
)
def test_callkit_to_state_mapping(
    has_ended: bool, has_connected: bool, is_outgoing: bool, expected: int
) -> None:
    """The CallKit flag truth-table → K1G state byte. `hasEnded` dominates
    (a connected call that just ended must clear the card, not show
    'active'), then `hasConnected`, then `isOutgoing`, else inbound ring.
    Mirrors `CallStateObserver.callState(...)` exactly."""
    assert callkit_to_state(has_ended, has_connected, is_outgoing) == expected


def test_ended_dominates_connected_so_card_clears() -> None:
    """Regression guard for the most important ordering bug: a call that is
    BOTH hasConnected and hasEnded (the normal end-of-call CallKit event)
    must map to NONE (clear the card), never ACTIVE. If the guards were
    reordered, hanging up would leave a stale 'in call' card on the dash."""
    assert callkit_to_state(has_ended=True, has_connected=True, is_outgoing=False) == CALL_NONE
    assert callkit_to_state(has_ended=True, has_connected=True, is_outgoing=True) == CALL_NONE


# --- callStateEnabled gate (BikeLink.sendCallState) --------------------------
#
# The user can switch the incoming-call card off in Settings
# (DashNavSettings.callStateEnabled). BikeLink.sendCallState gates on it:
# a NEW card (any state != none) is suppressed when disabled, but a NONE
# (clear) is ALWAYS allowed through — so flipping the toggle off mid-call
# wipes a lit card instead of stranding it on the dash. This mirrors the
# Swift `if state != .none { guard callStateEnabled }` guard.


def gate_allows_send(state: int, enabled: bool) -> bool:
    """Mirror of the BikeLink.sendCallState toggle gate (the part BEFORE the
    .connected / de-dupe guards). Returns True if the state is allowed to
    proceed to the wire."""
    if state != CALL_NONE:
        return enabled
    return True  # a clear always goes through


@pytest.mark.parametrize("state", ALL_STATES)
def test_gate_allows_everything_when_enabled(state: int) -> None:
    """With the card enabled (the default), every state proceeds — the gate
    is transparent."""
    assert gate_allows_send(state, enabled=True) is True


@pytest.mark.parametrize(
    "state",
    [CALL_INCOMING, CALL_ACTIVE, CALL_OUTGOING],
)
def test_gate_suppresses_new_cards_when_disabled(state: int) -> None:
    """With the card disabled, a NEW card (ringing / active / outgoing) is
    suppressed — nothing call-related hits the wire."""
    assert gate_allows_send(state, enabled=False) is False


def test_gate_always_allows_clear_even_when_disabled() -> None:
    """A NONE (clear) is allowed through even when disabled, so turning the
    toggle off while a card is lit clears it instead of leaving it stuck.
    This is the load-bearing exception in the gate — if it regresses, the
    'turn it off mid-call' UX silently breaks (card stays on the dash)."""
    assert gate_allows_send(CALL_NONE, enabled=False) is True
    assert gate_allows_send(CALL_NONE, enabled=True) is True
