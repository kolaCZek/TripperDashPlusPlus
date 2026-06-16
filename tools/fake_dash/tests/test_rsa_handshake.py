"""Unit tests for the RSA handshake — generation, encode/decode, decrypt."""

from pathlib import Path

import pytest
from cryptography.hazmat.primitives.asymmetric import padding

from fake_dash.protocol import decode_packet
from fake_dash.rsa_handshake import (
    DEFAULT_BIKE_SSID,
    RSA_CIPHERTEXT_LEN,
    build_pubkey_response,
    decrypt_session_key,
    load_or_generate_key,
    public_key_bytes,
)


@pytest.fixture
def bike_key(tmp_path: Path):
    return load_or_generate_key(tmp_path)


def test_key_persists_across_calls(tmp_path: Path):
    k1 = load_or_generate_key(tmp_path)
    k2 = load_or_generate_key(tmp_path)
    assert k1.private_numbers().d == k2.private_numbers().d


def test_pubkey_bytes_shape(bike_key):
    mod, exp = public_key_bytes(bike_key.public_key())
    assert len(mod) == RSA_CIPHERTEXT_LEN  # exactly 128 B for 1024-bit
    # F4 = 65537 = 0x010001 — 3 bytes natural, padded to 4 if you want;
    # we keep the natural width.
    assert exp == b"\x01\x00\x01"


def test_pubkey_response_envelope_has_two_segments(bike_key):
    pkt = build_pubkey_response(bike_key.public_key())
    segs = decode_packet(pkt)
    assert [(s.type, s.sub) for s in segs] == [(0x07, 0x00), (0x07, 0x03)]
    assert len(segs[0].payload) == RSA_CIPHERTEXT_LEN


def test_decrypt_roundtrip_with_matching_ssid(bike_key):
    ssid = DEFAULT_BIKE_SSID
    aes_key = b"\x42" * 32
    plaintext = ssid.encode("utf-8") + aes_key
    ciphertext = bike_key.public_key().encrypt(plaintext, padding.PKCS1v15())
    assert len(ciphertext) == RSA_CIPHERTEXT_LEN

    result = decrypt_session_key(bike_key, ciphertext, expected_ssid=ssid)
    assert result.aes_key == aes_key
    assert result.decoded_ssid == ssid
    assert result.ssid_matched is True


def test_decrypt_roundtrip_with_mismatched_ssid_still_succeeds(bike_key):
    aes_key = b"\xAB" * 32
    plaintext = b"RE_OTHER_BIKE_000000" + aes_key
    ciphertext = bike_key.public_key().encrypt(plaintext, padding.PKCS1v15())
    result = decrypt_session_key(bike_key, ciphertext, expected_ssid="RE_FAKE_260616")
    assert result.aes_key == aes_key
    assert result.ssid_matched is False  # but we don't reject — fake_dash is lenient


def test_decrypt_rejects_wrong_size():
    # We never decrypt — error is raised before key use, so a junk key is fine.
    from cryptography.hazmat.primitives.asymmetric import rsa
    k = rsa.generate_private_key(public_exponent=65537, key_size=1024)
    with pytest.raises(ValueError, match="128-byte"):
        decrypt_session_key(k, b"\x00" * 127, expected_ssid="x")
