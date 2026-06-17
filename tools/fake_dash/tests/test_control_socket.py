"""
Control-socket round-trip tests.

These exercise the `BUTTON` IPC end-to-end: a running FakeDashServer with
a fake "phone peer" pre-registered, a ControlClient firing button events,
and a test-side UDP listener catching what the server fan-outs.

We don't go through the real Docker setup — the server binds K1G on an
ephemeral port and the control socket lives in a temp dir, so the test
is hermetic and runs in milliseconds.
"""

from __future__ import annotations

import os
import socket
import tempfile
import threading
import time
from pathlib import Path

import pytest

from fake_dash.buttons import Button
from fake_dash.control_socket import ControlClient
from fake_dash.protocol import decode_packet
from fake_dash.server import FakeDashServer


def _free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def _wait_for(predicate, timeout: float = 2.0, interval: float = 0.02) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        if predicate():
            return True
        time.sleep(interval)
    return False


@pytest.fixture
def running_server(tmp_path):
    """Spin up a server on a free K1G port with control socket in tmp_path."""
    k1g_port = _free_port()
    rtp_port = _free_port()
    sock_path = tmp_path / "fake_dash.sock"
    server = FakeDashServer(
        bind_addr="127.0.0.1",
        k1g_port=k1g_port,
        rtp_port=rtp_port,
        keys_dir=tmp_path / "keys",
        captures_dir=tmp_path / "captures",
        enable_beacon=False,
        control_socket_path=sock_path,
    )
    server.start()
    # Give the threads a moment to actually bind their sockets.
    assert _wait_for(lambda: sock_path.exists()), "control socket never appeared"
    try:
        yield server, sock_path, k1g_port
    finally:
        server.stop()


def test_ping_round_trip(running_server):
    _, sock_path, _ = running_server
    client = ControlClient(socket_path=sock_path)
    assert client.ping() == "PONG"


def test_button_with_no_peers_returns_err(running_server):
    _, sock_path, _ = running_server
    client = ControlClient(socket_path=sock_path)
    reply = client.send_button(Button.RIGHT)
    assert reply.startswith("ERR"), f"expected ERR (no peers), got {reply!r}"
    assert "no peers" in reply.lower()


def test_button_fans_out_to_registered_peer(running_server):
    """
    Simulate a phone: open a UDP socket, send a single 'wake' packet
    so the server registers us as a peer, then ask via the control
    socket to fire a RIGHT button. We should receive a K1G envelope
    containing segment type=0x09 sub=0x00 payload=00 01 13.
    """
    server, sock_path, k1g_port = running_server

    # Phone-side UDP socket bound to a known port.
    phone_port = _free_port()
    phone_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    phone_sock.bind(("127.0.0.1", phone_port))
    phone_sock.settimeout(2.0)

    try:
        # Wake the server so it registers us as a peer.
        phone_sock.sendto(b"hello", ("127.0.0.1", k1g_port))
        assert _wait_for(
            lambda: any(p.addr[1] == phone_port for p in server.known_peers())
        ), "server never saw our wake packet"

        # Fire the button via the control socket.
        client = ControlClient(socket_path=sock_path)
        reply = client.send_button(Button.RIGHT)
        assert reply.startswith("OK"), f"expected OK, got {reply!r}"

        # Receive the fan-out. There may be a stray broadcast in flight
        # (if enable_beacon were on), but we explicitly disabled it.
        data, addr = phone_sock.recvfrom(65535)
        assert addr == ("127.0.0.1", k1g_port)

        segs = decode_packet(data)
        assert any(
            s.type == 0x09 and s.sub == 0x00 and len(s.payload) == 3 and s.payload[2] == int(Button.RIGHT)
            for s in segs
        ), f"no RIGHT button segment in {[(s.type, s.sub, s.payload.hex()) for s in segs]}"
    finally:
        phone_sock.close()


def test_unknown_command_returns_err(running_server):
    _, sock_path, _ = running_server
    client = ControlClient(socket_path=sock_path)
    reply = client._roundtrip("FROBNICATE foo\n", timeout=1.0)
    assert reply.startswith("ERR")


def test_socket_is_cleaned_up_on_stop(tmp_path):
    sock_path = tmp_path / "fake_dash.sock"
    server = FakeDashServer(
        bind_addr="127.0.0.1",
        k1g_port=_free_port(),
        rtp_port=_free_port(),
        keys_dir=tmp_path / "keys",
        captures_dir=tmp_path / "captures",
        enable_beacon=False,
        control_socket_path=sock_path,
    )
    server.start()
    assert _wait_for(lambda: sock_path.exists())
    server.stop()
    assert _wait_for(lambda: not sock_path.exists(), timeout=2.0), \
        "socket file should be unlinked on stop"
