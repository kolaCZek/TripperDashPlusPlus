"""
Tests for scripts/decode_re_capture.py — the no-deps pcap/pcapng decoder that
pulls K1G active-nav TLVs (and especially the 05 54 ETA-format byte + the
05 0C bottom-row suspect) out of a capture of the OFFICIAL Royal Enfield app
talking to the dash.

These build real classic-pcap AND pcapng blobs in-memory wrapping a known K1G
packet, run them through the decoder's own functions, and assert the watched
bytes come back out. This guards the two historically fiddly bits:

  * pcapng Section-Header byte-order detection (the BOM is 0x1A2B3C4D, which is
    bytes 4d 3c 2b 1a in a little-endian file — getting that backwards made the
    whole pcapng decode silently yield zero packets);
  * the link-layer auto-offset in extract_udp (Ethernet vs raw-IP/rvi0).
"""

from __future__ import annotations

import importlib.util
import struct
from pathlib import Path

import pytest

from fake_dash.protocol import Segment, build_envelope

_SCRIPT = (
    Path(__file__).resolve().parents[1] / "scripts" / "decode_re_capture.py"
)


def _load_decoder():
    spec = importlib.util.spec_from_file_location("decode_re_capture", _SCRIPT)
    assert spec is not None and spec.loader is not None
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


# --- builders ---------------------------------------------------------------
def _nav_k1g(eta_fmt: int = 0x30, bottom: int = 0x04, seq: int = 1) -> bytes:
    return build_envelope(
        [
            Segment(0x05, 0x08, bytes.fromhex("0303")),
            Segment(0x05, 0x54, bytes([0x00, 0x01, eta_fmt])),
            Segment(0x05, 0x09, bytes.fromhex("0000115C")),
            Segment(0x05, 0x0C, bytes([bottom])),
        ],
        seq=seq,
    )


def _udp(sport: int, dport: int, payload: bytes) -> bytes:
    return struct.pack(">HHHH", sport, dport, 8 + len(payload), 0) + payload


def _ipv4(payload: bytes, src="192.168.1.50", dst="192.168.1.1") -> bytes:
    hdr = struct.pack(
        ">BBHHHBBH4s4s",
        0x45, 0, 20 + len(payload), 1, 0, 64, 17, 0,
        bytes(map(int, src.split("."))),
        bytes(map(int, dst.split("."))),
    )
    return hdr + payload


def _eth(payload: bytes) -> bytes:
    return b"\xaa" * 6 + b"\x11" * 6 + b"\x08\x00" + payload


def _classic_pcap(frames, little=True) -> bytes:
    magic = 0xA1B2C3D4
    end = "<" if little else ">"
    gh = struct.pack(end + "IHHiIII", magic, 2, 4, 0, 0, 65535, 1)  # linktype=1
    out = gh
    for f in frames:
        out += struct.pack(end + "IIII", 0, 0, len(f), len(f)) + f
    return out


def _pcapng(frames, little=True) -> bytes:
    end = "<" if little else ">"
    def shb():
        body = struct.pack(end + "IHHq", 0x1A2B3C4D, 1, 0, -1)
        blen = 12 + len(body)
        return struct.pack(end + "II", 0x0A0D0D0A, blen) + body + struct.pack(end + "I", blen)
    def idb():
        body = struct.pack(end + "HHI", 1, 0, 65535)
        blen = 12 + len(body)
        return struct.pack(end + "II", 0x00000001, blen) + body + struct.pack(end + "I", blen)
    def epb(data):
        pad = (4 - len(data) % 4) % 4
        body = struct.pack(end + "IIIII", 0, 0, 0, len(data), len(data)) + data + b"\x00" * pad
        blen = 12 + len(body)
        return struct.pack(end + "II", 0x00000006, blen) + body + struct.pack(end + "I", blen)
    out = shb() + idb()
    for f in frames:
        out += epb(f)
    return out


# --- tests ------------------------------------------------------------------
def test_extract_udp_ethernet():
    drc = _load_decoder()
    frame = _eth(_ipv4(_udp(2002, 2000, b"hello")))
    sport, dport, payload = drc.extract_udp(frame)
    assert (sport, dport, payload) == (2002, 2000, b"hello")


def test_extract_udp_raw_ip_rvi0():
    """rvictl's rvi0 has no Ethernet header — IP starts at offset 0."""
    drc = _load_decoder()
    frame = _ipv4(_udp(2000, 2002, b"\x01\x02"))
    sport, dport, payload = drc.extract_udp(frame)
    assert (sport, dport, payload) == (2000, 2002, b"\x01\x02")


@pytest.mark.parametrize("little", [True, False])
def test_classic_pcap_roundtrip(little):
    drc = _load_decoder()
    blob = _classic_pcap([_eth(_ipv4(_udp(2002, 2000, _nav_k1g())))], little=little)
    frames = list(drc.iter_raw_packets(blob))
    assert len(frames) == 1
    got = drc.extract_udp(frames[0])
    assert got is not None and (got[0], got[1]) == (2002, 2000)


@pytest.mark.parametrize("little", [True, False])
def test_pcapng_roundtrip_both_byte_orders(little):
    """The BOM bug only showed up in one endianness — pin both."""
    drc = _load_decoder()
    blob = _pcapng([_eth(_ipv4(_udp(2002, 2000, _nav_k1g())))], little=little)
    frames = list(drc.iter_raw_packets(blob))
    assert len(frames) == 1, f"pcapng (little={little}) yielded {len(frames)} frames, want 1"


def test_decodes_watched_eta_and_bottom_row_bytes():
    """End-to-end: the 05 54 ETA-format byte and 05 0C bottom-row suspect must
    survive pcap -> UDP -> K1G decode so the field investigation can read them."""
    from fake_dash.protocol import decode_packet

    drc = _load_decoder()
    blob = _pcapng([_eth(_ipv4(_udp(2002, 2000, _nav_k1g(eta_fmt=0x30, bottom=0x04))))])
    frame = next(iter(drc.iter_raw_packets(blob)))
    _, _, payload = drc.extract_udp(frame)
    segs = {
        f"{s.type:02X}{s.sub:02X}": s.payload.hex().upper()
        for s in decode_packet(payload)
    }
    assert segs["0554"] == "000130", "ETA-format byte 05 54 must decode to 0x30"
    assert segs["050C"] == "04", "bottom-row suspect 05 0C must decode"
