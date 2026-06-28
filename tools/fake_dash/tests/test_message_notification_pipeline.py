"""
Tests for the incoming-MESSAGE notification pipeline (message cards on the
Tripper TFT) — the AES-encrypted `km3.z()` burst.

Reverse-engineered 2026-06 from the stock Royal Enfield app
(`com.royalenfield.reprime`):

    SmsReceiver → NavigationRootFragment.B1(body, sender, time)
        → km3.z(messages, unread)

`km3.z()` rides the SAME K1G/UDP-2000 control plane as nav + call-state
(NOT a separate transport, NOT the BLE `q12` path). For each arrival it emits:

  1. one PLAINTEXT unread count   `06 09 0002 <count_BE>`   (km3.e)
  2. then, per populated slot (newest first, up to 5), THREE packets, each a
     single AES-encrypted field:
        content   `05 <contentSub> <encLen> <IV‖ct>`   (km3.c)
        sender    `05 <senderSub>  <encLen> <IV‖ct>`   (km3.d/h)
        timestamp `05 <tsSub>      <encLen> <IV‖ct>`   (km3.f)

Slot/sub tags, byte-verified against `km3.java:9-25`:

  slot 0:  content 0524  sender 0527  ts 052A
  slot 1:  content 0525  sender 0528  ts 052B
  slot 2:  content 0526  sender 0529  ts 052C
  slot 3:  content 054E  sender 0550  ts 0552
  slot 4:  content 054F  sender 0551  ts 0553

Each field is AES-256/CBC/PKCS7, random 16-byte IV, wire payload = IV‖ct,
keyed on the session AES key the phone RSA-ships to the dash in the `08 00`
packet (`edk.g()` ⇄ `K1GCrypto.encryptField`). Because that key is recovered
by `decrypt_session_key()`, this test does a FULL ROUND TRIP: encrypt as the
phone, frame on the wire, decode + decrypt as the dash, assert the plaintext.

Swift side: `K1GPacket.make{MessageCount,MessageField}` + `K1GCrypto` +
`MessageNotification` + `BikeLink.sendMessageNotification`.

Authoritative writeup: the `royal-enfield-tripper-dash` skill reference
`message-notification-wire-protocol.md`.
"""

from __future__ import annotations

import os
import struct

import pytest
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

from fake_dash.protocol import Segment, build_envelope, decode_packet
from fake_dash.field_crypto import decrypt_field, encode_plaintext_bytes


# --- Python mirror of the Swift message builders -----------------------------

# K1GPacket.MessageSlot.all — (contentSub, senderSub, timestampSub) per slot.
SLOTS = [
    (0x24, 0x27, 0x2A),  # slot 0  → 0524 / 0527 / 052A
    (0x25, 0x28, 0x2B),  # slot 1  → 0525 / 0528 / 052B
    (0x26, 0x29, 0x2C),  # slot 2  → 0526 / 0529 / 052C
    (0x4E, 0x50, 0x52),  # slot 3  → 054E / 0550 / 0552
    (0x4F, 0x51, 0x53),  # slot 4  → 054F / 0551 / 0553
]

CONTENT_MAX = 79
SENDER_MAX = 19


def aes_encrypt_field(s: str, key: bytes, iv: bytes | None = None) -> bytes:
    """
    Mirror of `K1GCrypto.encryptField` (stock `edk.g()`): encode the string
    to clamped-UTF-16 bytes + 0x00, AES-256/CBC/PKCS7 with a random IV,
    return IV‖ciphertext.
    """
    if iv is None:
        iv = os.urandom(16)
    plaintext = encode_plaintext_bytes(s)
    # PKCS7 pad to a 16-byte block multiple.
    pad_len = 16 - (len(plaintext) % 16)
    padded = plaintext + bytes([pad_len]) * pad_len
    encryptor = Cipher(algorithms.AES(key), modes.CBC(iv)).encryptor()
    ct = encryptor.update(padded) + encryptor.finalize()
    return iv + ct


def tlv_message_count(count: int) -> Segment:
    """`06 09 0002 <count_BE>` — plaintext unread count (km3.e)."""
    return Segment(type=0x06, sub=0x09, payload=struct.pack(">H", count))


def tlv_message_field(sub: int, encrypted: bytes) -> Segment:
    """`05 <sub> <encLen> <IV‖ct>` — one encrypted field (km3.c/d/f)."""
    return Segment(type=0x05, sub=sub, payload=encrypted)


def cap_content(s: str) -> str:
    return s.strip()[:CONTENT_MAX]


def cap_sender(name: str, number: str) -> str:
    base = name if name else number
    return base[:SENDER_MAX]


@pytest.fixture
def key() -> bytes:
    """A deterministic 32-byte AES-256 session key for the tests."""
    return bytes(range(32))  # 00 01 02 … 1F


# --- Wire-shape / byte-pinning tests -----------------------------------------

def test_count_is_plaintext_and_big_endian():
    seg = tlv_message_count(0x1234)
    assert seg.type == 0x06
    assert seg.sub == 0x09
    assert seg.payload == b"\x12\x34"  # NOT encrypted, BE u16


def test_count_envelope_roundtrips():
    pkt = build_envelope([tlv_message_count(7)], seq=0)
    segs = decode_packet(pkt)
    assert len(segs) == 1
    assert segs[0].type == 0x06 and segs[0].sub == 0x09
    assert struct.unpack(">H", segs[0].payload)[0] == 7


@pytest.mark.parametrize("slot_index,subs", list(enumerate(SLOTS)))
def test_slot_sub_tags_are_byte_exact(slot_index, subs):
    """Pin each slot's content/sender/timestamp sub-bytes to the OEM table."""
    expected = [
        (0x24, 0x27, 0x2A),
        (0x25, 0x28, 0x2B),
        (0x26, 0x29, 0x2C),
        (0x4E, 0x50, 0x52),
        (0x4F, 0x51, 0x53),
    ][slot_index]
    assert subs == expected


def test_field_segment_shape(key):
    enc = aes_encrypt_field("Hi", key)
    seg = tlv_message_field(0x24, enc)
    assert seg.type == 0x05
    assert seg.sub == 0x24
    assert seg.payload == enc
    # payload = IV(16) + at least one 16-byte cipher block
    assert len(seg.payload) >= 32
    assert len(seg.payload) % 16 == 0


# --- FULL round-trip: encrypt as phone → decode + decrypt as dash ------------

def test_roundtrip_simple_ascii(key):
    msg = "Dinner at 7?"
    enc = aes_encrypt_field(msg, key)
    pkt = build_envelope([tlv_message_field(0x24, enc)], seq=3)
    segs = decode_packet(pkt)
    assert len(segs) == 1
    recovered = decrypt_field(segs[0].payload, key)
    assert recovered == msg


def test_roundtrip_full_message_card(key):
    """A complete slot-0 card: count + content + sender + timestamp, all
    framed, decoded, and (for the encrypted three) decrypted back."""
    content = "On my way, 10 min"
    sender = "Marketa"
    timestamp = "0627183205"  # MMddhhmmss

    packets = [
        build_envelope([tlv_message_count(1)], seq=0),
        build_envelope([tlv_message_field(SLOTS[0][0], aes_encrypt_field(content, key))], seq=1),
        build_envelope([tlv_message_field(SLOTS[0][1], aes_encrypt_field(sender, key))], seq=2),
        build_envelope([tlv_message_field(SLOTS[0][2], aes_encrypt_field(timestamp, key))], seq=3),
    ]

    # Dash side: count is plaintext, the rest decrypt with the session key.
    count_seg = decode_packet(packets[0])[0]
    assert struct.unpack(">H", count_seg.payload)[0] == 1

    got_content = decrypt_field(decode_packet(packets[1])[0].payload, key)
    got_sender = decrypt_field(decode_packet(packets[2])[0].payload, key)
    got_ts = decrypt_field(decode_packet(packets[3])[0].payload, key)

    assert got_content == content
    assert got_sender == sender
    assert got_ts == timestamp


def test_roundtrip_czech_diacritics_below_ff(key):
    """Latin-1-range diacritics (é, á, í … all < U+00FF) must survive the
    round trip byte-exact — they're representable in the stock app's
    one-byte-per-code-unit scheme."""
    msg = "Ahoj, jedu dom\u016f"  # 'ů' is U+016F → ABOVE 0xFF, see next test
    # Keep only the <0xFF part for this exact-survival assertion:
    msg = "Ciao, c'est déjà prêt"  # é, à, ê all < 0x100
    enc = aes_encrypt_field(msg, key)
    recovered = decrypt_field(enc, key)
    assert recovered == msg


def test_diacritic_above_ff_collapses_to_0xff(key):
    """The stock `edk.g()` clamps any UTF-16 unit >= 255 to 0xFF. Czech 'ů'
    (U+016F) is above 0xFF, so it must collapse — we reproduce the quirk
    rather than 'fixing' it, or our bytes diverge from the OEM app."""
    s = "d\u016f"  # "dů"
    enc = encode_plaintext_bytes(s)
    # 'd' = 0x64, 'ů' (U+016F) → 0xFF, then 0x00 terminator
    assert enc == bytes([0x64, 0xFF, 0x00])


def test_emoji_surrogate_pair_each_unit_clamped(key):
    """An emoji is two UTF-16 surrogate code units, each >= 0xD800 → both
    clamp to 0xFF. Pins that we iterate code UNITS, not Unicode scalars."""
    enc = encode_plaintext_bytes("\U0001F600")  # 😀, surrogate pair
    assert enc == bytes([0xFF, 0xFF, 0x00])


# --- Truncation rules (km3.c / km3.h) ----------------------------------------

def test_content_capped_at_79_then_encrypted(key):
    long = "x" * 200
    capped = cap_content(long)
    assert len(capped) == 79
    enc = aes_encrypt_field(capped, key)
    assert decrypt_field(enc, key) == "x" * 79


def test_content_is_trimmed_before_cap():
    assert cap_content("   hello   ") == "hello"


def test_sender_capped_at_19(key):
    name = "A Very Long Contact Name Indeed"
    capped = cap_sender(name, "+420777123456")
    assert len(capped) == 19
    assert capped == name[:19]


def test_sender_falls_back_to_number_when_name_empty():
    assert cap_sender("", "+420777123456") == "+420777123456"[:19]


def test_sender_prefers_name_when_present():
    assert cap_sender("Maty", "+420732795887") == "Maty"


# --- Negative / robustness ---------------------------------------------------

def test_decrypt_rejects_short_payload(key):
    with pytest.raises(ValueError):
        decrypt_field(b"\x00" * 10, key)  # < IV + one block


def test_decrypt_rejects_wrong_key_length():
    with pytest.raises(ValueError):
        decrypt_field(b"\x00" * 48, b"shortkey")


def test_wrong_key_produces_garbage_not_original(key):
    """Decrypting with the wrong key must NOT yield the plaintext (sanity
    that the round trip actually depends on the shared session key)."""
    enc = aes_encrypt_field("secret", key)
    wrong = bytes((b + 1) & 0xFF for b in key)
    try:
        out = decrypt_field(enc, wrong)
    except ValueError:
        return  # padding check tripped — also acceptable
    assert out != "secret"
