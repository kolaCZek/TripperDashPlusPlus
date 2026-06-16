"""
K1G wire-format helpers.

K1G is the protocol Royal Enfield uses between the Tripper TFT dash and
the companion smartphone app over UDP/2002. Every K1G packet has the
shape:

    [outer_len: u16 BE] [seg_count: u16 BE] [pad: 4 bytes] [segments…]

Each segment is a TLV chunk:

    [type: u8] [sub: u8] [seg_len: u16 BE] [payload…]

The 4-byte pad between seg_count and segments is constant (`0x02 0x01 0x00
0x05`) followed by a 4-byte `K1G ` magic + 1-byte rolling sequence number,
which lives at offset 8 in the framed packet. The phone (or this fake_dash)
patches that sequence byte just before each transmission so the dash can
detect retransmits.

References: better-dash/tripper_app_like_nav.py (functions
`decode_ic_to_app_segments`, `patch_k1g_seq`).
"""

from __future__ import annotations

import struct
from dataclasses import dataclass
from typing import Iterable


# Constant prefix every K1G envelope shares before the per-message segment
# bytes. Layout (after the leading 2-byte outer_len that we patch at send
# time):
#
#   00 02      seg_count = always 2 in the templates we use
#   00 00 00 00   pad
#   02 01 00 05   IC header marker
#   4B 31 47 20   ASCII "K1G "
#   <seq>      rolling sequence byte, patched per-transmission
#
# The "0016 0002 …" prefix at the start of every Q3C_* hex string in
# better-dash bakes in outer_len=0x16 for a single-segment ack; the
# patch_k1g_seq() helper recomputes outer_len for variable-length packets.
K1G_MAGIC = b"K1G "
K1G_SEQ_OFFSET_FROM_MAGIC = 4  # seq byte sits immediately after "K1G "


@dataclass(frozen=True)
class Segment:
    """One TLV chunk inside a K1G packet."""

    type: int          # high-level message family (0x07 = auth, 0x09 = button, …)
    sub: int           # sub-type within family
    payload: bytes     # raw bytes after the 4-byte TLV header

    @property
    def hex(self) -> str:
        """Uppercase hex of the full segment (header + payload).

        Same format better-dash uses to dispatch handlers via prefix match.
        """
        return (
            bytes([self.type, self.sub, (len(self.payload) >> 8) & 0xFF, len(self.payload) & 0xFF]).hex().upper()
            + self.payload.hex().upper()
        )


def decode_packet(data: bytes) -> list[Segment]:
    """
    Split a wire-format K1G packet into its TLV segments.

    The wire layout is:

        [outer_len: u16 BE]
        [seg_count_hint: u16 BE]    # informational; we trust the trailing data
        [pad: 4 bytes]
        [marker: 02 01 00 05]
        [K1G magic: 4B 31 47 20]
        [seq: u8]
        [segments…]

    Real segments begin immediately after the seq byte (offset 17 from
    packet start, give or take if the IC header marker is absent).
    Each TLV chunk is:

        [type: u8] [sub: u8] [len: u16 BE] [payload…]

    We walk from `K1G ` + 5 to the end of the buffer, decoding as many
    TLVs as we can. Returns empty list on a packet too short or missing
    the magic.
    """
    if len(data) < 8:
        return []
    k = data.find(K1G_MAGIC)
    if k == -1:
        return []
    off = k + 4 + 1  # past "K1G " + seq byte
    out: list[Segment] = []
    while off + 4 <= len(data):
        t = data[off]
        sub = data[off + 1]
        seg_len = (data[off + 2] << 8) | data[off + 3]
        off += 4
        end = min(off + seg_len, len(data))
        out.append(Segment(type=t, sub=sub, payload=data[off:end]))
        off = end
    return out


def patch_seq(pkt: bytes, seq: int) -> bytes:
    """
    Patch the rolling sequence byte (the one right after the K1G magic) and
    refresh the outer length field. Returns a new bytes object — does not
    mutate the input.
    """
    b = bytearray(pkt)
    k = b.find(K1G_MAGIC)
    if k == -1:
        raise ValueError("K1G magic not found in packet")
    b[k + K1G_SEQ_OFFSET_FROM_MAGIC] = seq & 0xFF
    struct.pack_into(">H", b, 0, len(b))
    return bytes(b)


class RollingSeq:
    """Thread-unsafe monotonic 0..255 counter. Wrap whenever, dash doesn't care."""

    __slots__ = ("_v",)

    def __init__(self, start: int = 0) -> None:
        self._v = start & 0xFF

    def consume(self) -> int:
        x = self._v
        self._v = (self._v + 1) & 0xFF
        return x


# ---------------------------------------------------------------------------
# Well-known K1G messages the *bike* (this fake_dash) sends to the phone.
# These are observed in real Tripper traffic captures and mirrored from
# better-dash's outbound-from-phone templates with the direction inverted
# where it matters.
# ---------------------------------------------------------------------------

# When the bike comes up, it broadcasts a periodic "BLE-style" announce on
# UDP/2002. Phones snoop these to discover the dash IP. We replay one of
# the two announce shapes the better-dash project captured in the wild.
BIKE_ANNOUNCE_HEX = "0018000200000000020100054B31472002060600030E3334"

# Auth status segment templates. These are wrapped in the outer K1G frame
# at send time by `build_envelope()`.
AUTH_OK_SEGMENT = Segment(type=0x07, sub=0x01, payload=b"\x01")
AUTH_FAIL_SEGMENT = Segment(type=0x07, sub=0x01, payload=b"\x00")


def build_envelope(segments: Iterable[Segment], seq: int = 0) -> bytes:
    """
    Build a complete K1G wire packet from one or more segments.

    Layout produced (matching the templates baked into better-dash's
    Q3C_* hex constants):

        [len: u16 BE = 0]           # patched after assembly
        [seg_count: u16 BE]
        [pad: 4 bytes of 0x00]
        [marker: 02 01 00 05]
        [K1G magic: "K1G "]
        [seq: u8]
        [segments…]

    The leading outer_len is patched via `patch_seq` at the end.
    """
    segs = list(segments)
    body = bytearray()
    body.extend(b"\x00\x00")                          # outer_len placeholder
    body.extend(struct.pack(">H", len(segs)))         # seg_count
    body.extend(b"\x00\x00\x00\x00")                  # pad
    body.extend(b"\x02\x01\x00\x05")                  # IC header marker
    body.extend(K1G_MAGIC)
    body.append(seq & 0xFF)
    for seg in segs:
        body.append(seg.type)
        body.append(seg.sub)
        body.extend(struct.pack(">H", len(seg.payload)))
        body.extend(seg.payload)
    # Patch outer_len now that body is complete.
    struct.pack_into(">H", body, 0, len(body))
    return bytes(body)


def build_auth_modulus_segment(modulus_bytes: bytes) -> Segment:
    """Bike → phone: 07 00 + RSA public-key modulus (big-endian, typically 128 B for RSA-1024)."""
    return Segment(type=0x07, sub=0x00, payload=modulus_bytes)


def build_auth_exponent_segment(exponent_bytes: bytes) -> Segment:
    """Bike → phone: 07 03 + RSA public-key exponent (typically `00 01 00 01`)."""
    return Segment(type=0x07, sub=0x03, payload=exponent_bytes)
