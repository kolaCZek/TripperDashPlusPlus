"""Unit tests for K1G wire-format helpers."""

from fake_dash.protocol import (
    K1G_MAGIC,
    RollingSeq,
    Segment,
    build_envelope,
    decode_packet,
    patch_seq,
)


def test_segment_hex_format():
    seg = Segment(type=0x07, sub=0x01, payload=b"\x01")
    # type sub len_hi len_lo payload
    assert seg.hex == "07010001" + "01"


def test_envelope_roundtrip_single_segment():
    seg = Segment(type=0x09, sub=0x00, payload=b"\x00\x01\x14")  # LEFT button
    pkt = build_envelope([seg], seq=0xAB)
    # Outer len patched to actual length.
    outer_len = int.from_bytes(pkt[:2], "big")
    assert outer_len == len(pkt)
    # K1G magic + seq located somewhere in the envelope.
    assert K1G_MAGIC in pkt
    k = pkt.find(K1G_MAGIC)
    assert pkt[k + 4] == 0xAB

    # Round-trip back to segments.
    segs = decode_packet(pkt)
    assert len(segs) == 1
    assert segs[0].type == 0x09
    assert segs[0].sub == 0x00
    assert segs[0].payload == b"\x00\x01\x14"


def test_envelope_roundtrip_multi_segment():
    s1 = Segment(type=0x07, sub=0x00, payload=b"\xAA" * 128)  # RSA modulus
    s2 = Segment(type=0x07, sub=0x03, payload=b"\x00\x01\x00\x01")  # exponent
    pkt = build_envelope([s1, s2])
    segs = decode_packet(pkt)
    assert len(segs) == 2
    assert segs[0].type == 0x07 and segs[0].sub == 0x00
    assert len(segs[0].payload) == 128
    assert segs[1].sub == 0x03
    assert segs[1].payload == b"\x00\x01\x00\x01"


def test_patch_seq_updates_byte_and_len():
    seg = Segment(type=0x06, sub=0x10, payload=b"\x00\x01\x55")
    pkt = build_envelope([seg], seq=0x00)
    patched = patch_seq(pkt, seq=0x42)
    k = patched.find(K1G_MAGIC)
    assert patched[k + 4] == 0x42
    # Length still matches body.
    assert int.from_bytes(patched[:2], "big") == len(patched)


def test_decode_short_packet_returns_empty():
    assert decode_packet(b"") == []
    assert decode_packet(b"\x00\x16") == []


def test_rolling_seq_wraps_at_256():
    s = RollingSeq(start=0xFE)
    assert s.consume() == 0xFE
    assert s.consume() == 0xFF
    assert s.consume() == 0x00
    assert s.consume() == 0x01
