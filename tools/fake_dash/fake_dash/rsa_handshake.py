"""
RSA-1024 handshake state machine for the bike side.

In the real protocol the bike (Tripper TFT) holds a long-lived RSA-1024
key pair. After the phone sends `q3c.e` ("request auth / give me your
pubkey"), the bike answers with two K1G segments:

    07 00  <modulus, 128 B big-endian>
    07 03  <exponent, typically 00 01 00 01>

The phone derives a payload `ssid_bytes ‖ aes_key_bytes` (see
NavigationRootFragment.R0 in the decompiled app), encrypts it with
RSA-PKCS1v1.5 under the public key, and ships it back inside a single
`q3c.d` segment of type=0x08 sub=0x00. The bike decrypts with its
private key, recovers `ssid + aes_key`, validates the SSID, and replies
with `07 01 01` (auth OK).

We mirror that exact flow here, with one ergonomic addition: on first
run we generate a fresh RSA-1024 keypair and persist it to disk in
`<keys_dir>/bike_rsa.pem` so subsequent runs reuse the same identity
(handy when a captured handshake needs to be reproducible).

References:
- better-dash/tripper_app_like_nav.py — `AuthState`, `_rsa_encrypt_session_key`
- better-dash/tripper_app_like_nav.py:158-200 — auth state machine
"""

from __future__ import annotations

import logging
import os
import struct
import threading
from dataclasses import dataclass, field
from pathlib import Path

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import padding, rsa
from cryptography.hazmat.primitives.asymmetric.rsa import (
    RSAPrivateKey,
    RSAPublicKey,
)

from .protocol import (
    AUTH_OK_SEGMENT,
    AUTH_FAIL_SEGMENT,
    Segment,
    build_auth_exponent_segment,
    build_auth_modulus_segment,
    build_envelope,
)

log = logging.getLogger("fake_dash.rsa")


# RSA-1024 is hardcoded into the real q3c.d packet (outer_len=0x95,
# seg_len=0x80 = 128B ciphertext). Anything else would not fit.
RSA_KEY_BITS = 1024
RSA_CIPHERTEXT_LEN = 128

# Default SSID we expect the phone to embed in the encrypted payload.
# The real dash compares this against the AP SSID it announces, but for
# our test harness we keep it loose and just log mismatches.
DEFAULT_BIKE_SSID = "RE_FAKE_260616"


@dataclass
class HandshakeResult:
    """Outcome of a single auth exchange — useful for tests/inspection."""

    aes_key: bytes
    decoded_ssid: str
    ssid_matched: bool


@dataclass
class HandshakeState:
    """Tracks one logical auth session with a remote phone peer."""

    expected_ssid: str = DEFAULT_BIKE_SSID
    last_result: HandshakeResult | None = None
    authenticated: bool = False
    _lock: threading.Lock = field(default_factory=threading.Lock)

    def reset(self) -> None:
        with self._lock:
            self.last_result = None
            self.authenticated = False


def _key_path(keys_dir: Path | str) -> Path:
    return Path(keys_dir) / "bike_rsa.pem"


def load_or_generate_key(keys_dir: Path | str) -> RSAPrivateKey:
    """
    Return the bike's RSA-1024 private key, generating + persisting it on
    first run. The key lives at `<keys_dir>/bike_rsa.pem` as an
    unencrypted PEM (TRADITIONAL_OPENSSL format) — fine for a test
    harness; not for production.
    """
    path = _key_path(keys_dir)
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists():
        with path.open("rb") as f:
            key = serialization.load_pem_private_key(f.read(), password=None)
        if not isinstance(key, RSAPrivateKey):
            raise RuntimeError(f"{path} is not an RSA private key")
        if key.key_size != RSA_KEY_BITS:
            log.warning(
                "Persisted key is %d-bit, regenerating to required %d-bit",
                key.key_size,
                RSA_KEY_BITS,
            )
        else:
            log.info("Loaded existing bike RSA key from %s", path)
            return key
    # Fresh key — either no file or wrong size.
    log.info("Generating new %d-bit RSA keypair for bike identity", RSA_KEY_BITS)
    key = rsa.generate_private_key(public_exponent=65537, key_size=RSA_KEY_BITS)
    with path.open("wb") as f:
        f.write(
            key.private_bytes(
                encoding=serialization.Encoding.PEM,
                format=serialization.PrivateFormat.TraditionalOpenSSL,
                encryption_algorithm=serialization.NoEncryption(),
            )
        )
    os.chmod(path, 0o600)
    log.info("Wrote bike RSA key to %s (0600)", path)
    return key


def public_key_bytes(pub: RSAPublicKey) -> tuple[bytes, bytes]:
    """
    Return (modulus_be, exponent_be) as the on-wire byte strings the
    phone expects in `07 00` and `07 03` segments.

    Modulus is padded to exactly 128 B for RSA-1024 (the dash assumes
    this width when sizing q3c.d). Exponent is the natural big-endian
    byte form, typically `00 01 00 01` for the standard F4 = 65537.
    """
    numbers = pub.public_numbers()
    mod_bytes = numbers.n.to_bytes(RSA_CIPHERTEXT_LEN, "big")
    e = numbers.e
    e_len = (e.bit_length() + 7) // 8 or 1
    exp_bytes = e.to_bytes(e_len, "big")
    return mod_bytes, exp_bytes


def build_pubkey_response(pub: RSAPublicKey, seq: int = 0) -> bytes:
    """
    Build the K1G envelope the bike sends in response to `q3c.e`,
    carrying modulus + exponent in two segments.
    """
    modulus, exponent = public_key_bytes(pub)
    return build_envelope(
        [
            build_auth_modulus_segment(modulus),
            build_auth_exponent_segment(exponent),
        ],
        seq=seq,
    )


def decrypt_session_key(
    private_key: RSAPrivateKey,
    ciphertext: bytes,
    expected_ssid: str,
) -> HandshakeResult:
    """
    Decrypt a `q3c.d` payload (the 128 B RSA-PKCS1v1.5 ciphertext) and
    split it into SSID + AES session key.

    Layout produced by `NavigationRootFragment.R0`:
        plaintext = ssid_utf8_bytes ‖ aes_key_bytes

    The Royal Enfield app uses AES-256 (32-byte key), so we slice from
    the end: last 32 B = AES key, prefix = SSID.

    Raises ValueError if the ciphertext length is wrong or PKCS1v1.5
    padding fails (typically: wrong RSA key, garbled packet).
    """
    if len(ciphertext) != RSA_CIPHERTEXT_LEN:
        raise ValueError(
            f"expected {RSA_CIPHERTEXT_LEN}-byte RSA-1024 ciphertext, got {len(ciphertext)}"
        )
    plaintext = private_key.decrypt(ciphertext, padding.PKCS1v15())
    if len(plaintext) <= 32:
        raise ValueError(
            f"plaintext too short ({len(plaintext)} B) to hold SSID + 32B AES key"
        )
    aes_key = plaintext[-32:]
    ssid_bytes = plaintext[:-32]
    # SSID is UTF-8 in the wild; tolerate latin-1 fallback for robustness
    # against malformed phone payloads.
    try:
        ssid = ssid_bytes.decode("utf-8")
    except UnicodeDecodeError:
        ssid = ssid_bytes.decode("latin-1")
    matched = ssid == expected_ssid
    if not matched:
        log.warning(
            "SSID mismatch: phone sent %r, bike expected %r (continuing anyway in fake_dash)",
            ssid,
            expected_ssid,
        )
    return HandshakeResult(aes_key=aes_key, decoded_ssid=ssid, ssid_matched=matched)


def build_auth_status(ok: bool, seq: int = 0) -> bytes:
    """K1G envelope carrying `07 01 01` (OK) or `07 01 00` (fail)."""
    return build_envelope(
        [AUTH_OK_SEGMENT if ok else AUTH_FAIL_SEGMENT],
        seq=seq,
    )
