"""
Field-level AES decryption for K1G message/caller-name TLVs.

The stock Royal Enfield app encrypts the message content / sender / timestamp
fields (and the caller-name `05 22` card) with `edk.g()` before putting them
on the K1G wire. This module is the INVERSE — what the dash does to recover
the plaintext — so `fake_dash` can assert that TripperDash++'s
`K1GCrypto.encryptField` produced bytes the real dash would decrypt correctly.

`edk.g()` recipe (decompiled `edk.java:108-138`, 2026-06-27):
  1. Each UTF-16 code unit of the string → one byte (unit < 255 → that byte,
     else 0xFF), then append a single 0x00 terminator.
  2. AES-256/CBC/PKCS7 encrypt under the session key, random 16-byte IV.
  3. Wire payload = IV(16) ‖ ciphertext.

The session key is the SAME 32-byte AES key recovered from the RSA handshake
(`decrypt_session_key().aes_key`) — the phone generates it and RSA-ships it to
the dash in the `08 00` packet, so the dash (and therefore this decryptor)
holds exactly the key the phone encrypted with.
"""

from __future__ import annotations

from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

IV_LEN = 16
AES256_KEY_LEN = 32


def decrypt_field(payload: bytes, aes_key: bytes) -> str:
    """
    Inverse of `K1GCrypto.encryptField` / stock `edk.g()`.

    Takes the on-wire `IV(16) ‖ ciphertext` blob and the 32-byte session key,
    returns the original string.

    Raises ValueError on a malformed payload (too short, key wrong length,
    bad padding, or ciphertext not a block multiple).
    """
    if len(aes_key) != AES256_KEY_LEN:
        raise ValueError(f"AES key must be {AES256_KEY_LEN} bytes, got {len(aes_key)}")
    if len(payload) < IV_LEN + 16:
        raise ValueError(
            f"payload too short ({len(payload)} B): need IV(16) + >=1 cipher block"
        )
    iv = payload[:IV_LEN]
    ciphertext = payload[IV_LEN:]
    if len(ciphertext) % 16 != 0:
        raise ValueError(
            f"ciphertext length {len(ciphertext)} is not a 16-byte block multiple"
        )

    decryptor = Cipher(algorithms.AES(aes_key), modes.CBC(iv)).decryptor()
    padded = decryptor.update(ciphertext) + decryptor.finalize()

    # Strip PKCS7 padding manually (cryptography's unpadder also works, but
    # doing it here keeps the failure modes explicit for the test).
    pad_len = padded[-1]
    if pad_len < 1 or pad_len > 16 or pad_len > len(padded):
        raise ValueError(f"invalid PKCS7 padding byte {pad_len}")
    if padded[-pad_len:] != bytes([pad_len]) * pad_len:
        raise ValueError("inconsistent PKCS7 padding")
    plaintext_bytes = padded[:-pad_len]

    # edk.g() appended a single 0x00 terminator before encrypting; drop it.
    if plaintext_bytes and plaintext_bytes[-1] == 0x00:
        plaintext_bytes = plaintext_bytes[:-1]

    # Each byte is a clamped UTF-16 code unit (Latin-1 range, since >=255
    # collapses to 0xFF). Decode as latin-1 to round-trip the byte values.
    return plaintext_bytes.decode("latin-1")


def encode_plaintext_bytes(s: str) -> bytes:
    """
    Mirror of `K1GCrypto.encodePlaintext` (the pre-encryption byte form):
    one byte per UTF-16 code unit clamped to 0xFF, plus a trailing 0x00.

    Exposed so tests can assert the byte mapping independent of AES (e.g.
    that a diacritic above U+00FE collapses to 0xFF exactly like the stock
    app's `edk.g()` does).
    """
    out = bytearray()
    # Iterate UTF-16 code units (2-byte big-endian groups) so this matches
    # Swift's `String.utf16` exactly, including surrogate pairs for emoji.
    u16 = s.encode("utf-16-be")
    for i in range(0, len(u16), 2):
        code_unit = (u16[i] << 8) | u16[i + 1]
        out.append(code_unit if code_unit < 255 else 0xFF)
    out.append(0x00)
    return bytes(out)
