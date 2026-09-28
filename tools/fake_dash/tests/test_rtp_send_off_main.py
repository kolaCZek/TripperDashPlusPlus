"""RTP packetize + send must stay on the send queue (review B7).

The encoder callback used to hop to the main actor for every NAL, and every
datagram's send-completion hopped back again to bump a counter — dozens of
main-actor jobs a second, each one able to queue behind a tile bake and
stall the stream. Now `RtpSendPipe` does both on `sendQueue`, counters sit
behind a lock, and the main actor reads them from the 1 Hz metrics timer.
The packetizer itself (the wire bytes) is untouched; pinned byte-for-byte by
the RTP tests against better-dash. Swift can't be compiled on Linux, so pin
the threading in source.
"""

from __future__ import annotations

import pathlib

from tests.swift_source import decl_body, strip_comments

APP = pathlib.Path(__file__).resolve().parents[3] / "TripperDashPP"


def _src(rel: str) -> str:
    return strip_comments((APP / rel).read_text(encoding="utf-8"))


def test_send_path_has_no_main_actor_hop():
    src = _src("Stream/RtpStreamer.swift")
    start = decl_body(src, "func start()")
    assert "queue.async { pipe.handle(nal) }" in start
    assert "handleEncodedNAL" not in src

    pipe = decl_body(src, "nonisolated final class RtpSendPipe: @unchecked Sendable {")
    assert "@MainActor" not in pipe
    assert "Task" not in pipe
    handle = decl_body(pipe, "func handle(_ nal: EncodedNAL)")
    assert "packetizer.packetize(" in handle
    # Datagrams go out in packetizer order, then the one per-frame kick.
    assert handle.index("for datagram in datagrams {") < handle.index("link.onFrame?()")
    send = decl_body(pipe, "private func send(")
    assert "self.lock.withLock { self.counters.packetsSent += 1 }" in send

    # Metrics reach the main actor only through the 1 Hz timer.
    assert "Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true)" in start
    assert "pipe.takeWindow()" in decl_body(src, "private func flushMetrics()")


def test_send_path_types_are_nonisolated():
    assert "nonisolated final class RtpPacketizer: @unchecked Sendable {" in _src(
        "Stream/RtpPacketizer.swift"
    )
    assert "nonisolated struct RtpDatagram: Sendable {" in _src("Stream/RtpPacketizer.swift")
    assert "nonisolated struct EncodedNAL: @unchecked Sendable {" in _src("Stream/H264Encoder.swift")
