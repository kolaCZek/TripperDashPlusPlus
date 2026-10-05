"""
Stall diagnostics: when the dash picture freezes, the ride log has to say
which stage stopped. Each stage logs one line, only when it stalls:

    fix gap N s        LocationService   GPS fixes > 1.5 s apart
    render stall N ms  MapViewSource     render ticks > 500 ms apart
    rtp gap N ms       RtpStreamer       coded frames sent > 750 ms apart
    dash rx gap N ms   DashSocket        nothing from the dash for > 2 s

These guards keep a refactor from silently dropping a line, and keep each
threshold above the stage's normal cadence (so a healthy ride logs nothing).
"""

from __future__ import annotations

import pathlib
import re

from tests.swift_source import decl_body, strip_comments

APP = pathlib.Path(__file__).resolve().parents[3] / "TripperDashPP"


def _src(rel: str) -> str:
    return strip_comments((APP / rel).read_text(encoding="utf-8"))


def _fps() -> int:
    return int(re.search(r"let targetFps = (\d+)", _src("Map/MapViewSource.swift")).group(1))


def test_render_stall_logged_in_render_loop():
    src = _src("Map/MapViewSource.swift")
    loop = decl_body(src, "private func startTimer()")
    assert 'log.notice("render stall' in loop
    assert "if gapMs > Self.renderStallLogMs {" in loop
    # The previous tick time must be recorded after the check, or the
    # line never fires (nil) / always measures 0.
    assert loop.index("if let lastTickAt {") < loop.index("lastTickAt = tickAt") < loop.index("await self?.tickOnMain()")
    ms = int(re.search(r"static let renderStallLogMs = (\d+)", src).group(1))
    # Two frame slots: one late tick is jitter, two is a stall.
    assert ms == 2 * 1000 // _fps(), ms


def test_missing_frame_is_logged_once_per_run():
    tick = decl_body(_src("Map/MapViewSource.swift"), "private func tickOnMain()")
    miss = tick[tick.index("guard let buffer = renderMapViewToPixelBuffer() else {"):]
    assert re.search(r'if framesMissed == 0 \{\s*log\.error\("render produced no frame', miss)
    assert "framesMissed += 1" in miss[: miss.index("return")]
    assert "framesMissed = 0" in miss[miss.index("return"):]


def test_rtp_gap_logged_per_frame():
    src = _src("Stream/RtpStreamer.swift")
    handle = decl_body(src, "func handle(_ nal: EncodedNAL)")
    assert 'log.notice("rtp gap' in handle
    assert "if let frameGap, frameGap > Self.rtpGapLogSeconds {" in handle
    # Measured between frames only — SPS/PPS NALs ride with an IDR.
    assert re.search(r"if isFrame \{\s*if let last = lastFrameUptime \{ gap = now - last \}\s*lastFrameUptime = now", handle)
    # A send path that never recovers is reported when the stream stops.
    end = decl_body(src, "func end()")
    assert 'log.notice("rtp gap' in end and "(at stop)" in end
    assert "pending > Self.rtpGapLogSeconds" in end
    secs = float(re.search(r"static let rtpGapLogSeconds: TimeInterval = ([\d.]+)", src).group(1))
    assert secs > 1.0 / _fps() * 2, secs  # above the render-stall slot
    # Reset per stream, or the first frame after a restart logs the pause.
    assert "lastFrameUptime = nil" in decl_body(src, "func begin(connection: NWConnection")


def test_dash_rx_gap_logged_on_receive():
    src = _src("Tripper/DashSocket.swift")
    assert 'log.notice("dash rx gap' in src
    assert "rxGap > 2 * K1G.heartbeatInterval" in src
    # Not on the first datagram: socket creation → first RX is the handshake.
    assert "rxDatagramCount > 1, rxGap" in src


def test_fix_gap_still_logged():
    assert 'log.info("fix gap' in _src("App/LocationService.swift")
