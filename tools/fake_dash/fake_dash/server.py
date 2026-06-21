"""
K1G control-plane server — UDP/2000 listener that plays the *bike* side.

Responsibilities:
  - Listen on UDP/2000 for incoming phone packets
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
from .control_socket import ControlServer, DEFAULT_SOCKET_PATH
from .protocol import (
    BIKE_ANNOUNCE_HEX,
    RollingSeq,
    Segment,
    build_envelope,
    decode_packet,
    is_valid_envelope,
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


DEFAULT_K1G_PORT = 2000
DEFAULT_RTP_PORT = 5000
BEACON_INTERVAL_SEC = 1.0


@dataclass
class PhonePeer:
    """One known phone peer we should fan messages out to."""

    addr: tuple[str, int]
    first_seen: float
    last_seen: float = field(default=0.0)
    authenticated: bool = False
    # Set after the first 0x06 (heartbeat / route card) is logged at INFO.
    # Subsequent 0x06 segments drop to DEBUG so the log doesn't drown.
    heartbeat_logged: bool = False
    # Set after the first packet (any type) is logged at INFO. Same idea —
    # we want one "phone is alive" line, then quiet.
    rx_logged: bool = False
    # Set after the first empty K1G envelope (heartbeat) is logged at INFO.
    # Subsequent ones drop to DEBUG.
    empty_envelope_logged: bool = False


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
        control_socket_path: str | Path = DEFAULT_SOCKET_PATH,
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

        # CLI ↔ server IPC. The control server fans out injected button
        # events to known peers — without it, `fake-dash button right`
        # would only register the CLI's own loopback socket as a peer
        # and the bytes would never reach the real iPhone.
        self._control = ControlServer(
            socket_path=control_socket_path,
            on_button=self.send_button,
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
        self._control.start()

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
        self._control.stop()
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
            # Filter out our own broadcast that the OS / Docker bridge
            # loops back to the listening socket. The bike announce we
            # send out has source port == bind port (2000, the K1G dash
            # port), and a real phone would never use that as its
            # ephemeral source port — phones bind 2002 locally per the
            # K1G protocol.
            if addr[1] == self.k1g_port:
                continue
            peer = self._record_peer(addr)
            try:
                self._handle_packet(data, peer)
            except Exception:
                log.exception("Error handling packet from %s", addr)

    def _handle_packet(self, data: bytes, peer: PhonePeer) -> None:
        if not peer.rx_logged:
            log.info(
                "RX %s: first packet (%d B) — phone is talking to us",
                peer.addr,
                len(data),
            )
            peer.rx_logged = True
        segs = decode_packet(data)
        if not segs:
            # Empty K1G envelope (17-byte header, no TLVs) is the standard
            # heartbeat from the phone side — better-dash captures confirm
            # this is normal. Only log louder if the magic / framing is
            # actually corrupt.
            if is_valid_envelope(data):
                if not peer.empty_envelope_logged:
                    log.info(
                        "RX %s: empty K1G envelope (heartbeat, %d B) — "
                        "will not log subsequent ones",
                        peer.addr,
                        len(data),
                    )
                    peer.empty_envelope_logged = True
                else:
                    log.debug("RX %s: empty K1G envelope (%d B)", peer.addr, len(data))
            else:
                log.warning(
                    "RX %s: malformed packet (%d B) — no K1G magic or "
                    "bad outer_len; first bytes: %s",
                    peer.addr,
                    len(data),
                    data[:24].hex(),
                )
            return
        for seg in segs:
            self._dispatch_segment(seg, peer)

    def _dispatch_segment(self, seg: Segment, peer: PhonePeer) -> None:
        # Type 0x08 sub 0x00 = q3c.d: phone shipping us the RSA-encrypted
        # session key. Decrypt it and ack with 07 01 01.
        if seg.type == 0x08 and seg.sub == 0x00:
            self._handle_session_key(seg.payload, peer)
            return

        # Type 0x08 sub 0x04 = q3c.e: phone requesting our RSA pubkey.
        # Better-dash + the real Tripper Android app both send this as
        # `08 04 00 01 01`. The earlier loose `{(0x07, 0x04), (0x08, 0x04)}`
        # match was kept while we figured out which type byte was correct;
        # confirmed via better-dash that 0x07 is INBOUND-ONLY (bike → phone)
        # so the phone never legitimately sends 0x07. Stay strict — that
        # way a regression in the Swift client surfaces immediately as
        # "auth request dropped" instead of being silently accepted.
        if seg.type == 0x08 and seg.sub == 0x04:
            self._handle_auth_request(peer)
            return

        # Type 0x06: route card / heartbeat from phone. First one per peer
        # is logged at INFO so the operator can see signs of life;
        # subsequent ones drop to DEBUG to avoid spam.
        if seg.type == 0x06:
            if not peer.heartbeat_logged:
                log.info(
                    "RX %s: first 0x06 (heartbeat/route) seg sub=0x%02X len=%d",
                    peer.addr,
                    seg.sub,
                    len(seg.payload),
                )
                peer.heartbeat_logged = True
            else:
                log.debug(
                    "RX %s: route/heartbeat seg sub=0x%02X len=%d",
                    peer.addr,
                    seg.sub,
                    len(seg.payload),
                )
            return

        log.info(
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
