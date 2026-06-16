"""
RTP H.264 sink — receive video from the iPhone and dump Annex-B to disk.

The Tripper expects RTP payload-type 96 on UDP/5000 with:
  - Single-NAL packets for small NALs
  - FU-A fragmentation (NAL type 28) for everything else
  - SPS/PPS/IDR bundled with embedded Annex-B start codes (see
    better-dash/dash_ui/rtp.py `_bundle_sps_pps_idr`).

We mirror that and reverse it: parse the RTP header, reassemble FU-A
fragments by their (timestamp, NAL-type) tuple, and write each complete
NAL prefixed with `00 00 00 01` into a `.h264` file that ffmpeg/VLC can
open directly.

The output file is named `dash_capture_<ISO timestamp>.h264` inside the
configured captures directory, with one file per server lifetime. Stats
(packet count, bytes received, dropped fragments, framerate estimate)
are exposed via `RtpSink.stats()` and logged every 5 s.
"""

from __future__ import annotations

import logging
import socket
import struct
import threading
import time
from dataclasses import dataclass, field
from pathlib import Path

log = logging.getLogger("fake_dash.rtp")


ANNEXB_START_CODE = b"\x00\x00\x00\x01"

# RTP header is at least 12 bytes; FU indicator + FU header add 2 more.
RTP_HEADER_LEN = 12
FU_HEADER_LEN = 2


@dataclass
class RtpStats:
    packets_total: int = 0
    bytes_total: int = 0
    nals_completed: int = 0
    idr_count: int = 0
    fragments_dropped: int = 0
    last_packet_ts: float = 0.0
    last_idr_ts: float = 0.0
    first_packet_ts: float = 0.0


@dataclass
class _FragmentBuffer:
    """In-flight FU-A reassembly state for a single RTP timestamp.

    The dash sends one access unit per RTP timestamp; we track only one
    at a time and drop anything that arrives out-of-order from a stale
    timestamp.
    """

    timestamp: int
    nal_type: int
    f_nri: int
    data: bytearray = field(default_factory=bytearray)
    started: bool = False
    expected_seq: int | None = None


class RtpSink:
    """
    UDP server bound on `bind_addr:port`, dumping reassembled NALs as
    Annex-B to a single growing `.h264` file in `captures_dir`.

    Thread model: one worker thread runs `_serve()`. Call `start()` /
    `stop()` to manage its lifecycle; both are idempotent.
    """

    def __init__(
        self,
        bind_addr: str,
        port: int,
        captures_dir: str | Path,
        *,
        capture_filename: str | None = None,
    ) -> None:
        self.bind_addr = bind_addr
        self.port = port
        self.captures_dir = Path(captures_dir)
        self.captures_dir.mkdir(parents=True, exist_ok=True)
        # Sanitize a per-run filename so multiple `docker compose up` cycles
        # don't clobber each other.
        if capture_filename is None:
            ts = time.strftime("%Y%m%d_%H%M%S")
            capture_filename = f"dash_capture_{ts}.h264"
        self.capture_path = self.captures_dir / capture_filename
        self.stats = RtpStats()

        self._sock: socket.socket | None = None
        self._thread: threading.Thread | None = None
        self._stop = threading.Event()
        self._fh = None
        self._frag: _FragmentBuffer | None = None
        self._stats_thread: threading.Thread | None = None

    # ------------------------------------------------------------------ lifecycle

    def start(self) -> None:
        if self._thread is not None and self._thread.is_alive():
            return
        self._stop.clear()
        self._sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        # Generous recv buffer — RTP bursts at IDR boundaries can stack up.
        self._sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 1 << 20)
        self._sock.bind((self.bind_addr, self.port))
        self._sock.settimeout(0.5)
        self._fh = self.capture_path.open("wb")
        log.info(
            "RTP sink listening on udp://%s:%d, writing %s",
            self.bind_addr,
            self.port,
            self.capture_path,
        )
        self._thread = threading.Thread(target=self._serve, name="rtp-sink", daemon=True)
        self._thread.start()
        self._stats_thread = threading.Thread(
            target=self._stats_loop, name="rtp-stats", daemon=True
        )
        self._stats_thread.start()

    def stop(self) -> None:
        self._stop.set()
        if self._sock is not None:
            try:
                self._sock.close()
            except OSError:
                pass
        if self._thread is not None:
            self._thread.join(timeout=2.0)
        if self._fh is not None:
            self._fh.flush()
            self._fh.close()
            self._fh = None
        log.info(
            "RTP sink stopped — wrote %d NALs (%d IDR) across %d packets to %s",
            self.stats.nals_completed,
            self.stats.idr_count,
            self.stats.packets_total,
            self.capture_path,
        )

    # ------------------------------------------------------------------ workers

    def _serve(self) -> None:
        assert self._sock is not None
        while not self._stop.is_set():
            try:
                data, _addr = self._sock.recvfrom(65535)
            except socket.timeout:
                continue
            except OSError:
                return
            self._handle_packet(data)

    def _stats_loop(self) -> None:
        """Emit periodic throughput stats so the operator can see flow."""
        prev_pkts = 0
        prev_bytes = 0
        prev_t = time.time()
        while not self._stop.wait(5.0):
            now = time.time()
            dt = max(now - prev_t, 0.001)
            d_pkts = self.stats.packets_total - prev_pkts
            d_bytes = self.stats.bytes_total - prev_bytes
            if d_pkts > 0:
                log.info(
                    "RTP: %d pkt/s, %.0f kB/s, %d NALs total (%d IDR), %d drops",
                    int(d_pkts / dt),
                    d_bytes / dt / 1024,
                    self.stats.nals_completed,
                    self.stats.idr_count,
                    self.stats.fragments_dropped,
                )
            prev_pkts = self.stats.packets_total
            prev_bytes = self.stats.bytes_total
            prev_t = now

    # ------------------------------------------------------------------ RTP parsing

    def _handle_packet(self, data: bytes) -> None:
        if len(data) < RTP_HEADER_LEN + 1:
            return  # bogus
        # RTP fixed header. We don't care about CSRC list / extensions for
        # the Tripper's traffic shape — bail if either is set (unexpected).
        v_p_x_cc = data[0]
        version = v_p_x_cc >> 6
        if version != 2:
            return
        cc = v_p_x_cc & 0x0F
        ext = (v_p_x_cc >> 4) & 0x01
        header_len = RTP_HEADER_LEN + 4 * cc
        if ext:
            # Skip RTP header extension if present (rare here).
            if len(data) < header_len + 4:
                return
            ext_words = struct.unpack(">H", data[header_len + 2 : header_len + 4])[0]
            header_len += 4 + 4 * ext_words
        if len(data) <= header_len:
            return
        seq = struct.unpack(">H", data[2:4])[0]
        ts = struct.unpack(">I", data[4:8])[0]
        payload = data[header_len:]
        now = time.time()
        if self.stats.first_packet_ts == 0.0:
            self.stats.first_packet_ts = now
        self.stats.last_packet_ts = now
        self.stats.packets_total += 1
        self.stats.bytes_total += len(data)

        nal_hdr = payload[0]
        nal_type = nal_hdr & 0x1F

        if nal_type == 28:
            # FU-A fragmented NAL
            self._handle_fu_a(payload, ts, seq)
        elif nal_type == 24:
            # STAP-A — Tripper drops these but log if we ever see one
            # (the iPhone shouldn't be sending STAP-A by the time we get here).
            log.warning("STAP-A packet received unexpectedly (Tripper rejects these)")
            return
        else:
            # Single-NAL packet — emit as-is.
            self._emit_nal(payload)

    def _handle_fu_a(self, payload: bytes, ts: int, seq: int) -> None:
        if len(payload) < FU_HEADER_LEN:
            return
        fu_indicator = payload[0]
        fu_header = payload[1]
        f_nri = fu_indicator & 0xE0
        start = bool(fu_header & 0x80)
        end = bool(fu_header & 0x40)
        nal_type = fu_header & 0x1F
        body = payload[FU_HEADER_LEN:]

        if start:
            # New fragmented NAL — drop any in-flight buffer we never finished.
            if self._frag is not None and self._frag.started:
                self.stats.fragments_dropped += 1
                log.debug(
                    "Dropped incomplete fragmented NAL (type=%d, %d bytes) at new START",
                    self._frag.nal_type,
                    len(self._frag.data),
                )
            self._frag = _FragmentBuffer(
                timestamp=ts,
                nal_type=nal_type,
                f_nri=f_nri,
                data=bytearray([f_nri | nal_type]),  # reconstructed NAL header
                started=True,
                expected_seq=(seq + 1) & 0xFFFF,
            )
            self._frag.data.extend(body)
            # Degenerate case: START + END set together means the whole
            # NAL fits in one fragment — emit immediately.
            if end:
                self._emit_nal(bytes(self._frag.data))
                self._frag = None
            return

        # Continuation or END fragment.
        if self._frag is None or not self._frag.started or self._frag.timestamp != ts:
            self.stats.fragments_dropped += 1
            return
        if self._frag.expected_seq is not None and seq != self._frag.expected_seq:
            # Out-of-order fragment — abandon the NAL; the dash would
            # do the same. Don't try to reorder; that would mask real
            # network problems we want to surface.
            self.stats.fragments_dropped += 1
            self._frag = None
            return
        self._frag.expected_seq = (seq + 1) & 0xFFFF
        self._frag.data.extend(body)
        if end:
            self._emit_nal(bytes(self._frag.data))
            self._frag = None

    def _emit_nal(self, nal: bytes) -> None:
        if not nal or self._fh is None:
            return
        nal_type = nal[0] & 0x1F
        if nal_type == 5:
            self.stats.idr_count += 1
            self.stats.last_idr_ts = time.time()
        self.stats.nals_completed += 1
        self._fh.write(ANNEXB_START_CODE)
        self._fh.write(nal)
        # Flush on every IDR and every 30 NALs so a `tail -f` / `ffprobe`
        # mid-run sees data. IDR flushes also keep small bursts (smoke
        # tests, very short clips) durable on disk immediately.
        if nal_type == 5 or self.stats.nals_completed % 30 == 0:
            self._fh.flush()
