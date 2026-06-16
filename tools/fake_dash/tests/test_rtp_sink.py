"""Unit tests for RTP H.264 reassembly."""

import struct
from pathlib import Path

import pytest

from fake_dash.rtp_sink import RtpSink


def _rtp_header(seq: int, ts: int, marker: bool = False, pt: int = 96) -> bytes:
    """Minimal RTP header — no CSRC, no extension."""
    return struct.pack(
        ">BBHII",
        0x80,  # V=2, P=0, X=0, CC=0
        (0x80 if marker else 0x00) | (pt & 0x7F),
        seq & 0xFFFF,
        ts & 0xFFFFFFFF,
        0xDEADBEEF,  # SSRC
    )


def _fu_a(seq: int, ts: int, nal_type: int, body: bytes, *, start: bool, end: bool, f_nri: int = 0x60) -> bytes:
    fu_indicator = f_nri | 28
    fu_header = (0x80 if start else 0) | (0x40 if end else 0) | nal_type
    return _rtp_header(seq, ts) + bytes((fu_indicator, fu_header)) + body


def _single_nal(seq: int, ts: int, nal: bytes) -> bytes:
    return _rtp_header(seq, ts) + nal


@pytest.fixture
def sink(tmp_path: Path):
    s = RtpSink(bind_addr="127.0.0.1", port=0, captures_dir=tmp_path, capture_filename="test.h264")
    # Don't actually bind; tests poke the private API directly.
    s._fh = (tmp_path / "test.h264").open("wb")
    yield s
    if s._fh:
        s._fh.close()


def test_single_nal_written_as_annexb(sink):
    nal = b"\x65\xB8\x40" + b"\x00" * 50  # IDR
    sink._handle_packet(_single_nal(100, 1000, nal))
    sink._fh.flush()
    out = Path(sink._fh.name).read_bytes()
    assert out == b"\x00\x00\x00\x01" + nal
    assert sink.stats.nals_completed == 1
    assert sink.stats.idr_count == 1


def test_fu_a_reassembly_two_fragments(sink):
    # Reconstructed NAL header has type=5 (IDR), f_nri=0x60
    body_part_a = b"\x11" * 100
    body_part_b = b"\x22" * 100
    sink._handle_packet(_fu_a(200, 2000, nal_type=5, body=body_part_a, start=True, end=False))
    sink._handle_packet(_fu_a(201, 2000, nal_type=5, body=body_part_b, start=False, end=True))
    sink._fh.flush()
    out = Path(sink._fh.name).read_bytes()
    expected_nal_hdr = bytes([0x60 | 5])  # f_nri (from FU indicator) | nal_type
    assert out == b"\x00\x00\x00\x01" + expected_nal_hdr + body_part_a + body_part_b
    assert sink.stats.nals_completed == 1
    assert sink.stats.idr_count == 1


def test_fu_a_out_of_order_fragment_drops_nal(sink):
    sink._handle_packet(_fu_a(300, 3000, nal_type=1, body=b"A" * 100, start=True, end=False))
    # Skip a sequence number — this should abort the reassembly.
    sink._handle_packet(_fu_a(302, 3000, nal_type=1, body=b"B" * 100, start=False, end=True))
    sink._fh.flush()
    out = Path(sink._fh.name).read_bytes()
    assert out == b""
    assert sink.stats.nals_completed == 0
    assert sink.stats.fragments_dropped >= 1


def test_fu_a_new_start_discards_incomplete(sink):
    sink._handle_packet(_fu_a(400, 4000, nal_type=1, body=b"X" * 100, start=True, end=False))
    # New START before previous END.
    sink._handle_packet(_fu_a(401, 4001, nal_type=1, body=b"Y" * 50, start=True, end=True))
    sink._fh.flush()
    out = Path(sink._fh.name).read_bytes()
    # Only the second (complete) NAL written.
    assert out == b"\x00\x00\x00\x01" + bytes([0x60 | 1]) + b"Y" * 50
    assert sink.stats.fragments_dropped == 1


def test_stap_a_ignored(sink):
    # STAP-A packet (type 24) — we log + drop.
    payload = bytes([24]) + b"\x00" * 10
    sink._handle_packet(_rtp_header(500, 5000) + payload)
    sink._fh.flush()
    assert Path(sink._fh.name).read_bytes() == b""
    assert sink.stats.nals_completed == 0


def test_short_packet_ignored(sink):
    sink._handle_packet(b"\x00")
    sink._handle_packet(_rtp_header(1, 1))  # header only, no NAL
    assert sink.stats.nals_completed == 0
    assert sink.stats.fragments_dropped == 0
