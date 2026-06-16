"""
K1G control-plane server — UDP/2002 listener that plays the *bike* side.

Responsibilities:
  - Listen on UDP/2002 for incoming phone packets
  - Track phone peers (by source IP) so we know where to send heartbeats
    and joystick events
  - On `q3c.e` ("request auth") respond with our RSA pubkey
  - On `q3c.d` (RSA-encrypted session key) decrypt → recover SSID + AES key
    → emit `07 01 01` auth-OK
  - On joystick CLI invocation, send `09 00 0001 XX` to every known peer
  - Periodically broadcast a "bike present" beacon so phones can discover us

Thread model:
  - One RX thread per port (blocking recvfrom in a loop)
  - One heartbeat thread for the 1 Hz beacon
  - Main thread blocks on signal/Event for graceful shutdown

This is deliberately single-process; the test harness only needs to talk
to one iPhone at a time. Multi-peer support is best-effort: we fan out
joystick events to all peers we've seen.
"""

from __future__ import annotations

import logging
import signal
import socket
import threading
import time
from dataclasses import dataclass, field
from pathlib import Path

from .buttons import Button, build_button_packet
from .protocol import (
    BIKE_ANNOUNCE_HEX,
    RollingSeq,
    Segment,
    build_envelope,
    decode_packet,
    patch_seq,
)
from .rsa_handshake import (
    DEFAULT_BIKE_SSID,
    HandshakeState,
    build_auth_status,
    build_pubkey_response,
    decrypt_session_key,
    load_or_generate_key,
)
from .rtp_sink import RtpSink

log = logging.getLogger("fake_dash.server")


DEFAULT_K1G_PORT = 2002
DEFAULT_RTP_PORT = 5000
BEACON_INTERVAL_SEC = 1.0


@dataclass
class PhonePeer:
    """One known phone peer we should fan messages out to."""

    addr: tuple[str, int]
    first_seen: float
    last_seen: float = field(default=0.0)
    authenticated: bool = False


class FakeDashServer:
    """
    Top-level coordinator: runs the K1G socket, the RTP sink, the
    heartbeat broadcaster, and exposes a small API for the CLI to inject
    button events.
    """

    def __init__(
        self,
        *,
        bind_addr: str = "0.0.0.0",
        k1g_port: int = DEFAULT_K1G_PORT,
        rtp_port: int = DEFAULT_RTP_PORT,
        keys_dir: str | Path = "/keys",
        captures_dir: str | Path = "/captures",
        bike_ssid: str = DEFAULT_BIKE_SSID,
        enable_beacon: bool = True,
    ) -> None:
        self.bind_addr = bind_addr
        self.k1g_port = k1g_port
        self.rtp_port = rtp_port
        self.bike_ssid = bike_ssid
        self.enable_beacon = enable_beacon

        self._private_key = load_or_generate_key(keys_dir)
        self._handshake = HandshakeState(expected_ssid=bike_ssid)
        self._seq = RollingSeq()
        self._peers: dict[tuple[str, int], PhonePeer] = {}
        self._peers_lock = threading.Lock()

        self._k1g_sock: socket.socket | None = None
        self._stop = threading.Event()
        self._threads: list[threading.Thread] = []

        self.rtp_sink = RtpSink(
            bind_addr=bind_addr,
            port=rtp_port,
            captures_dir=captures_dir,
        )

    # ------------------------------------------------------------------ lifecycle

    def start(self) -> None:
        self._k1g_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self._k1g_sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self._k1g_sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
        self._k1g_sock.bind((self.bind_addr, self.k1g_port))
        self._k1g_sock.settimeout(0.5)
        log.info(
            "K1G server listening on udp://%s:%d (bike SSID=%r)",
            self.bind_addr,
            self.k1g_port,
            self.bike_ssid,
        )

        self.rtp_sink.start()

        self._spawn(target=self._rx_loop, name="k1g-rx")
        if self.enable_beacon:
            self._spawn(target=self._beacon_loop, name="k1g-beacon")

    def stop(self) -> None:
        self._stop.set()
        if self._k1g_sock is not None:
            try:
                self._k1g_sock.close()
            except OSError:
                pass
        for t in self._threads:
            t.join(timeout=2.0)
        self.rtp_sink.stop()
        log.info("FakeDashServer stopped")

    def wait_forever(self) -> None:
        """Block until SIGINT/SIGTERM. Use in CLI entry point."""
        # Install signal handlers in the main thread.
        def _on_signal(signum, _frame):  # pragma: no cover — signal path
            log.info("Received signal %d, shutting down", signum)
            self._stop.set()

        signal.signal(signal.SIGINT, _on_signal)
        signal.signal(signal.SIGTERM, _on_signal)
        while not self._stop.is_set():
            self._stop.wait(timeout=1.0)

    def _spawn(self, target, name: str) -> None:
        t = threading.Thread(target=target, name=name, daemon=True)
        t.start()
        self._threads.append(t)

    # ------------------------------------------------------------------ peer registry

    def _record_peer(self, addr: tuple[str, int]) -> PhonePeer:
        now = time.time()
        with self._peers_lock:
            peer = self._peers.get(addr)
            if peer is None:
                peer = PhonePeer(addr=addr, first_seen=now, last_seen=now)
                self._peers[addr] = peer
                log.info("New phone peer: %s:%d", addr[0], addr[1])
            else:
                peer.last_seen = now
            return peer

    def known_peers(self) -> list[PhonePeer]:
        with self._peers_lock:
            return list(self._peers.values())

    # ------------------------------------------------------------------ send helpers

    def _send_to_peer(self, peer: PhonePeer, pkt: bytes) -> None:
        if self._k1g_sock is None:
            return
        # Patch seq + outer_len fresh per transmission so retransmits are
        # detectable on the wire.
        framed = patch_seq(pkt, self._seq.consume())
        try:
            self._k1g_sock.sendto(framed, peer.addr)
        except OSError as exc:
            log.warning("sendto %s failed: %s", peer.addr, exc)

    def _broadcast(self, pkt: bytes) -> None:
        """Send to broadcast address on K1G port (used for periodic beacon)."""
        if self._k1g_sock is None:
            return
        framed = patch_seq(pkt, self._seq.consume())
        try:
            self._k1g_sock.sendto(framed, ("255.255.255.255", self.k1g_port))
        except OSError as exc:
            # Broadcast may fail inside Docker bridge networks — log once and
            # move on; unicast to known peers still works.
            log.debug("broadcast failed: %s", exc)

    def send_button(self, button: Button) -> int:
        """
        Fan out a joystick event to every known peer.

        Returns the number of peers we sent to (0 means no phone has
        ever talked to us — wake the iPhone app first).
        """
        peers = self.known_peers()
        if not peers:
            log.warning(
                "send_button(%s): no known phone peers yet; bring the iOS app up first",
                button.name,
            )
            return 0
        pkt = build_button_packet(button)
        for peer in peers:
            self._send_to_peer(peer, pkt)
            log.info("→ %s:%d  button=%s", peer.addr[0], peer.addr[1], button.name)
        return len(peers)

    # ------------------------------------------------------------------ RX loop

    def _rx_loop(self) -> None:
        assert self._k1g_sock is not None
        while not self._stop.is_set():
            try:
                data, addr = self._k1g_sock.recvfrom(65535)
            except socket.timeout:
                continue
            except OSError:
                return
            peer = self._record_peer(addr)
            try:
                self._handle_packet(data, peer)
            except Exception:
                log.exception("Error handling packet from %s", addr)

    def _handle_packet(self, data: bytes, peer: PhonePeer) -> None:
        segs = decode_packet(data)
        if not segs:
            log.debug("RX %s: undecodable packet (%d bytes)", peer.addr, len(data))
            return
        for seg in segs:
            self._dispatch_segment(seg, peer)

    def _dispatch_segment(self, seg: Segment, peer: PhonePeer) -> None:
        # Type 0x08 sub 0x00 = q3c.d: phone shipping us the RSA-encrypted
        # session key. Decrypt it and ack with 07 01 01.
        if seg.type == 0x08 and seg.sub == 0x00:
            self._handle_session_key(seg.payload, peer)
            return

        # Type 0x07 sub 0x04 = q3c.e: phone is requesting our pubkey.
        # Better-dash sends this as "0804000101" which is type=0x08
        # sub=0x04 — but the actual q3c.e payload from a phone we
        # observed has type=0x08 sub=0x04 OR type=0x07 sub=0x04 depending
        # on firmware. Accept both.
        if (seg.type, seg.sub) in {(0x07, 0x04), (0x08, 0x04)}:
            self._handle_auth_request(peer)
            return

        # Type 0x06: route card / heartbeat from phone. We just log it
        # so the operator can see signs of life; no ACK required from
        # the bike side in normal operation.
        if seg.type == 0x06:
            log.debug(
                "RX %s: route/heartbeat seg sub=0x%02X len=%d",
                peer.addr,
                seg.sub,
                len(seg.payload),
            )
            return

        log.debug(
            "RX %s: unhandled seg type=0x%02X sub=0x%02X len=%d",
            peer.addr,
            seg.type,
            seg.sub,
            len(seg.payload),
        )

    def _handle_auth_request(self, peer: PhonePeer) -> None:
        log.info("AUTH ← %s: pubkey request, sending modulus + exponent", peer.addr)
        pkt = build_pubkey_response(self._private_key.public_key())
        self._send_to_peer(peer, pkt)

    def _handle_session_key(self, ciphertext: bytes, peer: PhonePeer) -> None:
        try:
            result = decrypt_session_key(self._private_key, ciphertext, self.bike_ssid)
        except Exception as exc:
            log.error("AUTH ← %s: session-key decrypt failed: %s", peer.addr, exc)
            self._send_to_peer(peer, build_auth_status(ok=False))
            return
        log.info(
            "AUTH ← %s: session key OK (SSID=%r, ssid_matched=%s)",
            peer.addr,
            result.decoded_ssid,
            result.ssid_matched,
        )
        self._handshake.last_result = result
        self._handshake.authenticated = True
        peer.authenticated = True
        self._send_to_peer(peer, build_auth_status(ok=True))
        log.info("AUTH → %s: 07 01 01 (auth OK)", peer.addr)

    # ------------------------------------------------------------------ beacon

    def _beacon_loop(self) -> None:
        """Periodic broadcast so phones can discover us when no unicast peer is known."""
        announce = bytes.fromhex(BIKE_ANNOUNCE_HEX)
        while not self._stop.wait(BEACON_INTERVAL_SEC):
            self._broadcast(announce)
