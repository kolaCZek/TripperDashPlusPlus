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
