"""
Tests for the dash button ack + manual zoom-bias behaviour (Phase 1+2 of
the joystick → map-zoom feature).

Covers:
  - the wire ack the phone must echo for each joystick event
    (`06 80 0001 XX`), mirroring Swift `K1GPacket.makeButtonAck`
  - the DashButton code set matching the Swift enum
  - the zoom-bias state machine: step, clamp, cooperation with autozoom,
    and the idle auto-revert back to neutral
"""

from fake_dash.buttons import (
    Button,
    build_button_ack_packet,
    build_button_ack_segment,
    build_button_packet,
    build_button_segment,
)
from fake_dash.protocol import decode_packet

from tests.zoom_bias_mirror import (
    ZOOM_BIAS_HOLD_SECONDS,
    ZOOM_BIAS_MAX,
    ZOOM_BIAS_MIN,
    ZOOM_BIAS_STEP,
    ZoomBias,
)


# --- Button codes / ack -------------------------------------------------

def test_button_codes_match_swift_enum():
    # Must stay in lock-step with K1GPacket.DashButton.
    assert Button.RIGHT == 0x13
    assert Button.LEFT == 0x14
    assert Button.DOWN == 0x15
    assert Button.CLICK == 0x18


def test_button_ack_segment_shape():
    seg = build_button_ack_segment(0x13)
    # 06 80 0001 13
    assert seg.type == 0x06
    assert seg.sub == 0x80
    assert seg.payload == b"\x13"
    assert seg.hex == "06800001" + "13"


def test_button_ack_echoes_same_code():
    for code in (0x13, 0x14, 0x15, 0x18):
        seg = build_button_ack_segment(code)
        assert seg.payload[0] == code


# --- Button EVENT wire shape (bike → phone) ----------------------------
#
# REGRESSION (2026-08-11 on-bike capture): the real dash sends a button as
# `09 00 0001 XX` — a 1-BYTE payload with the code as the trailing byte —
# NOT the `09 00 0003 0001XX` (3-byte payload) the harness used to emit.
# The phone decoded from a fixed payload offset 2, so every real press fell
# through as "unmapped" and zoom was dead. These pins lock the harness to
# the real single-byte shape, and the phone now reads the LAST payload byte.

def test_button_event_segment_is_single_byte_payload():
    seg = build_button_segment(Button.LEFT)
    assert seg.type == 0x09
    assert seg.sub == 0x00
    # The code is the WHOLE payload — one byte — with the TLV length field
    # (0001) emitted by Segment.hex, not baked into the payload.
    assert seg.payload == b"\x14"
    assert seg.hex == "09000001" + "14"


def test_button_event_matches_on_bike_capture():
    # The button SEGMENT the bike sent for a LEFT press in the field log
    # (btn-20260811-080512.jsonl) was `09 00 0001 14`. The harness wraps it
    # in its own (richer) K1G envelope, but the segment bytes on the wire —
    # and the decode — must match the bike exactly.
    pkt = build_button_packet(Button.LEFT, seq=0)
    assert "0900000114" in pkt.hex()
    # And it round-trips: decode → last payload byte == the button code, the
    # exact operation the phone's inbound loop now performs.
    segs = decode_packet(pkt)
    btn_segs = [s for s in segs if s.type == 0x09 and s.sub == 0x00]
    assert len(btn_segs) == 1
    assert btn_segs[0].hex == "09000001" + "14"
    assert btn_segs[0].payload[-1] == Button.LEFT


def test_all_buttons_decode_via_last_payload_byte():
    for b in (Button.RIGHT, Button.LEFT, Button.DOWN, Button.CLICK):
        segs = decode_packet(build_button_packet(b))
        # Mirror of the Swift `seg.payload.last` decode.
        assert segs[0].payload[-1] == int(b)


# --- Context-dependent buttons (music skip, remove-wp, exit-nav) -------
#
# On-bike capture btn-20260811-083111.jsonl proved the dash sends DIFFERENT
# codes for the same physical stick depending on which of its own screens
# is up. These pin the exact bytes captured so the harness ↔ phone contract
# never drifts from what the real dash emits.

def test_context_button_codes_match_capture():
    # (Button, exact 1-byte segment hex seen in the field log)
    cases = {
        Button.NEXT_TRACK: "0900000109",       # next song
        Button.PREV_TRACK: "090000010A",       # previous song
        Button.REMOVE_WAYPOINT: "0900000120",  # remove upcoming waypoint
        Button.EXIT_NAV: "0900000112",         # exit navigation
    }
    for b, expected_hex in cases.items():
        seg = build_button_segment(b)
        assert seg.hex == expected_hex, f"{b.name}: {seg.hex} != {expected_hex}"
        # And it round-trips through decode the same way the phone reads it.
        segs = decode_packet(build_button_packet(b))
        assert segs[0].payload[-1] == int(b)


def test_swift_dashbutton_enum_has_context_cases():
    """The Swift DashButton enum must map the four new context codes so the
    inbound decode surfaces them instead of dropping them as unmapped."""
    import pathlib
    root = pathlib.Path(__file__).resolve().parents[3]
    src = (root / "TripperDashPP" / "Tripper" / "K1GPacket.swift").read_text()
    assert "case prevTrack     = 0x0a" in src
    assert "case nextTrack     = 0x09" in src
    assert "case removeWaypoint = 0x20" in src
    assert "case exitNav       = 0x12" in src


def test_swift_wires_context_buttons_to_actions():
    """AppStatus.wireDashButtons must route the four new codes to real app
    behaviour (music skip, leg skip, exit-nav) — not leave them as no-ops."""
    import pathlib
    root = pathlib.Path(__file__).resolve().parents[3]
    src = (root / "TripperDashPP" / "App" / "AppStatus.swift").read_text()
    assert "self.dashMediaControl.skipToNext()" in src
    assert "self.dashMediaControl.skipToPrevious()" in src
    assert "self.activeNavigator.skipCurrentLeg()" in src
    assert "self.activeNavigator.onExitNavRequested?()" in src


def test_button_ack_packet_decodes_back():
    pkt = build_button_ack_packet(0x18, seq=0x05)
    segs = decode_packet(pkt)
    assert len(segs) == 1
    assert segs[0].type == 0x06
    assert segs[0].sub == 0x80
    assert segs[0].payload == b"\x18"


# --- Zoom bias: step + clamp -------------------------------------------

def test_zoom_in_multiplies_bias_up():
    z = ZoomBias()
    z.nudge(zoom_in=True, now=0.0)
    assert z.bias == ZOOM_BIAS_STEP


def test_zoom_out_divides_bias_down():
    z = ZoomBias()
    z.nudge(zoom_in=False, now=0.0)
    assert abs(z.bias - 1.0 / ZOOM_BIAS_STEP) < 1e-9


def test_zoom_bias_clamps_at_max():
    z = ZoomBias()
    for i in range(50):
        z.nudge(zoom_in=True, now=float(i))
    assert z.bias == ZOOM_BIAS_MAX


def test_zoom_bias_clamps_at_min():
    z = ZoomBias()
    for i in range(50):
        z.nudge(zoom_in=False, now=float(i))
    assert z.bias == ZOOM_BIAS_MIN


def test_in_then_out_returns_near_neutral():
    z = ZoomBias()
    z.nudge(zoom_in=True, now=0.0)
    z.nudge(zoom_in=False, now=1.0)
    assert abs(z.bias - 1.0) < 1e-9


# --- Zoom bias: cooperation with autozoom ------------------------------

def test_effective_target_scales_autozoom():
    z = ZoomBias()
    z.nudge(zoom_in=True, now=0.0)  # bias = 1.15
    # Autozoom target 1.0 → biased 1.15; autozoom keeps breathing under it.
    assert abs(z.effective_target(1.0) - ZOOM_BIAS_STEP) < 1e-9


def test_effective_target_respects_speed_clamp():
    z = ZoomBias()  # neutral bias
    # Raw autozoom above the 2.0 speed clamp is capped before bias.
    assert z.effective_target(5.0) == 2.0
    # And below the 0.8 floor.
    assert z.effective_target(0.1) == 0.8


# --- Zoom bias: auto-revert --------------------------------------------

def test_no_revert_during_hold_window():
    z = ZoomBias()
    z.nudge(zoom_in=True, now=0.0)
    z.decay(now=ZOOM_BIAS_HOLD_SECONDS - 1)  # still holding
    assert z.bias == ZOOM_BIAS_STEP


def test_revert_starts_after_hold_window():
    z = ZoomBias()
    z.nudge(zoom_in=True, now=0.0)
    before = z.bias
    z.decay(now=ZOOM_BIAS_HOLD_SECONDS + 0.1)
    assert z.bias < before          # moved back toward 1.0
    assert z.bias > 1.0             # but not all the way in one frame


def test_revert_converges_to_neutral():
    z = ZoomBias()
    z.nudge(zoom_in=True, now=0.0)
    t = ZOOM_BIAS_HOLD_SECONDS + 1
    for _ in range(500):
        z.decay(now=t)
        t += 0.05
    assert z.bias == 1.0
    assert z.last_nudge is None     # timer cleared once neutral


def test_decay_noop_when_neutral():
    z = ZoomBias()
    z.decay(now=1000.0)             # never nudged
    assert z.bias == 1.0
    assert z.last_nudge is None


# --- Zoom bias: at-limit feedback (blocked OSD glyph) ------------------

def test_nudge_reports_not_at_limit_when_bias_moves():
    z = ZoomBias()
    assert z.nudge(zoom_in=True, now=0.0) is False   # room to grow
    assert z.nudge(zoom_in=False, now=1.0) is False  # room to shrink


def test_nudge_reports_at_limit_at_max():
    z = ZoomBias()
    at_limit = False
    for i in range(50):
        at_limit = z.nudge(zoom_in=True, now=float(i))
    assert z.bias == ZOOM_BIAS_MAX
    assert at_limit is True          # pressing further does nothing


def test_nudge_reports_at_limit_at_min():
    z = ZoomBias()
    at_limit = False
    for i in range(50):
        at_limit = z.nudge(zoom_in=False, now=float(i))
    assert z.bias == ZOOM_BIAS_MIN
    assert at_limit is True


def test_swift_zoom_osd_flags_at_limit():
    """MapViewSource must detect a clamp-swallowed press and store the
    atLimit flag on zoomOsd so drawZoomOsd can flash the blocked glyph."""
    import pathlib
    root = pathlib.Path(__file__).resolve().parents[3]
    src = (root / "TripperDashPP" / "Map" / "MapViewSource.swift").read_text()
    assert "atLimit: Bool)?" in src, "zoomOsd must carry an atLimit flag"
    assert "let atLimit = abs(userZoomBias - before) < 1e-6" in src, (
        "applyZoomButton must set atLimit when the clamp swallows the step"
    )
    # drawZoomOsd must render a distinct blocked state (red + slash).
    assert "if atLimit {" in src, "drawZoomOsd must branch on atLimit"
