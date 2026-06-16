"""End-to-end smoke test — boot server, drive a handshake from a fake phone."""

import socket
import threading
import time
from pathlib import Path

import pytest
from cryptography.hazmat.primitives.asymmetric import padding, rsa
from cryptography.hazmat.primitives import serialization

from fake_dash.protocol import (
    RollingSeq,
    Segment,
    build_envelope,
    decode_packet,
    patch_seq,
)
from fake_dash.rsa_handshake import RSA_CIPHERTEXT_LEN, load_or_generate_key
from fake_dash.server import FakeDashServer


def _wait_for(predicate, timeout: float = 3.0, interval: float = 0.05) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        if predicate():
            return True
        time.sleep(interval)
    return False


@pytest.fixture
def server(tmp_path: Path):
    s = FakeDashServer(
        bind_addr="127.0.0.1",
        k1g_port=0,           # ephemeral
        rtp_port=0,
        keys_dir=str(tmp_path / "keys"),
        captures_dir=str(tmp_path / "captures"),
        bike_ssid="RE_TEST_000000",
        enable_beacon=False,  # broadcast loops are noisy in tests
    )
    # Bind manually so we can capture the actual ephemeral ports.
    s._k1g_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s._k1g_sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s._k1g_sock.bind(("127.0.0.1", 0))
    s._k1g_sock.settimeout(0.5)
    s.k1g_port = s._k1g_sock.getsockname()[1]
    s.rtp_sink.port = 0  # disable real RTP bind for this test
    s._spawn(target=s._rx_loop, name="k1g-rx-test")
    yield s
    s.stop()


def test_handshake_end_to_end(server, tmp_path):
    # Build a fake phone that drives one full auth exchange.
    bike_pub = load_or_generate_key(tmp_path / "keys").public_key()
    # The server already loaded its key — we need to grab IT, not regen.
    bike_pub = server._private_key.public_key()

    phone_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    phone_sock.settimeout(2.0)

    # 1) Phone → bike: request pubkey (q3c.e shape).
    request = build_envelope([Segment(type=0x07, sub=0x04, payload=b"\x01")])
    phone_sock.sendto(patch_seq(request, 0), ("127.0.0.1", server.k1g_port))

    # 2) Receive modulus + exponent.
    data, _ = phone_sock.recvfrom(4096)
    segs = decode_packet(data)
    types = [(s.type, s.sub) for s in segs]
    assert (0x07, 0x00) in types and (0x07, 0x03) in types
    modulus = next(s.payload for s in segs if (s.type, s.sub) == (0x07, 0x00))
    assert len(modulus) == RSA_CIPHERTEXT_LEN

    # 3) Build encrypted session key and ship it as q3c.d (08 00).
    ssid = "RE_TEST_000000"
    aes_key = b"\x37" * 32
    plaintext = ssid.encode("utf-8") + aes_key
    ciphertext = bike_pub.encrypt(plaintext, padding.PKCS1v15())
    session_pkt = build_envelope([Segment(type=0x08, sub=0x00, payload=ciphertext)])
    phone_sock.sendto(patch_seq(session_pkt, 1), ("127.0.0.1", server.k1g_port))

    # 4) Expect auth-OK back (07 01 01).
    data, _ = phone_sock.recvfrom(4096)
    segs = decode_packet(data)
    assert any(s.type == 0x07 and s.sub == 0x01 and s.payload == b"\x01" for s in segs)

    # 5) Server should now have an authenticated peer.
    assert _wait_for(lambda: any(p.authenticated for p in server.known_peers()), 1.0)

    phone_sock.close()
