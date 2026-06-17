"""
Control-plane IPC between the `fake_dash button …` CLI and the running
server process.

Why: the CLI runs in a *separate* process (`docker compose exec`) so it
can't reach the server's in-memory peer registry directly. Before this
module, the CLI just sent the raw button packet to `127.0.0.1:2002` and
ended up registered as a fake phone peer — the bytes never reached the
real iPhone. Now the CLI talks to the server over a tiny line-oriented
Unix-domain protocol and the server fans the event out to every known
peer (which is what the real bike does).

Protocol (one command per connection, newline-terminated):

    BUTTON <left|right|down|click>\n        → "OK n_peers\n"
    BUTTON <name>\n                          → "ERR no peers\n"  (warn-only)
    PING\n                                   → "PONG\n"

The socket path defaults to /run/fake_dash.sock inside the container.
Override with FAKE_DASH_CONTROL_SOCKET env var. A short-lived ControlClient
in the CLI does connect/send/recv/close — no persistent state on either side.
"""

from __future__ import annotations

import logging
import os
import socket
import threading
from pathlib import Path
from typing import Callable

from .buttons import Button

log = logging.getLogger("fake_dash.control")

DEFAULT_SOCKET_PATH = os.environ.get(
    "FAKE_DASH_CONTROL_SOCKET", "/run/fake_dash.sock"
)


# ---------------------------------------------------------------------------- server


class ControlServer:
    """
    Accepts short-lived connections on a Unix-domain socket and dispatches
    commands to callbacks supplied by the running FakeDashServer.

    Designed to be stoppable from the outside via `stop()` — the accept
    loop polls a stop Event and is bounded by SO_RCVTIMEO so shutdown is
    snappy without a separate wakeup pipe.
    """

    def __init__(
        self,
        *,
        socket_path: str | Path = DEFAULT_SOCKET_PATH,
        on_button: Callable[[Button], int],
    ) -> None:
        self.socket_path = str(socket_path)
        self._on_button = on_button
        self._sock: socket.socket | None = None
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None

    def start(self) -> None:
        # Make sure the dir exists and any stale socket is gone — otherwise
        # bind() fails with EADDRINUSE on restart.
        Path(self.socket_path).parent.mkdir(parents=True, exist_ok=True)
        try:
            os.unlink(self.socket_path)
        except FileNotFoundError:
            pass

        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.bind(self.socket_path)
        # World-writable so non-root CLI invocations work too (the docker
        # exec is root by default, but tests run as the caller's UID).
        os.chmod(self.socket_path, 0o666)
        sock.listen(8)
        sock.settimeout(0.5)
        self._sock = sock
        log.info("Control socket listening on %s", self.socket_path)

        self._thread = threading.Thread(
            target=self._accept_loop, name="fake-dash-control", daemon=True
        )
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        if self._thread is not None:
            self._thread.join(timeout=2.0)
            self._thread = None
        if self._sock is not None:
            try:
                self._sock.close()
            except OSError:
                pass
            self._sock = None
        try:
            os.unlink(self.socket_path)
        except FileNotFoundError:
            pass

    # ------------------------------------------------------------------ internals

    def _accept_loop(self) -> None:
        assert self._sock is not None
        while not self._stop.is_set():
            try:
                conn, _ = self._sock.accept()
            except socket.timeout:
                continue
            except OSError:
                return
            with conn:
                try:
                    self._handle_one(conn)
                except Exception:
                    log.exception("Control connection failed")

    def _handle_one(self, conn: socket.socket) -> None:
        conn.settimeout(2.0)
        data = b""
        # Read up to newline — commands are tiny so 256 B is plenty.
        while b"\n" not in data and len(data) < 256:
            chunk = conn.recv(256)
            if not chunk:
                break
            data += chunk
        line = data.split(b"\n", 1)[0].decode("utf-8", errors="replace").strip()
        if not line:
            conn.sendall(b"ERR empty\n")
            return

        parts = line.split()
        cmd = parts[0].upper()
        if cmd == "PING":
            conn.sendall(b"PONG\n")
            return
        if cmd == "BUTTON" and len(parts) == 2:
            try:
                btn = Button.from_name(parts[1])
            except ValueError as exc:
                conn.sendall(f"ERR {exc}\n".encode("utf-8"))
                return
            n = self._on_button(btn)
            if n == 0:
                conn.sendall(b"ERR no peers (bring the iOS app up first)\n")
            else:
                conn.sendall(f"OK {n}\n".encode("utf-8"))
            return

        conn.sendall(f"ERR unknown command {cmd!r}\n".encode("utf-8"))


# ---------------------------------------------------------------------------- client


class ControlClient:
    """One-shot client used by the `fake-dash button` CLI."""

    def __init__(self, socket_path: str | Path = DEFAULT_SOCKET_PATH) -> None:
        self.socket_path = str(socket_path)

    def send_button(self, button: Button, timeout: float = 3.0) -> str:
        return self._roundtrip(f"BUTTON {button.name.lower()}\n", timeout)

    def ping(self, timeout: float = 1.0) -> str:
        return self._roundtrip("PING\n", timeout)

    # ------------------------------------------------------------------ internals

    def _roundtrip(self, line: str, timeout: float) -> str:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
            s.settimeout(timeout)
            s.connect(self.socket_path)
            s.sendall(line.encode("utf-8"))
            s.shutdown(socket.SHUT_WR)
            buf = b""
            while True:
                chunk = s.recv(256)
                if not chunk:
                    break
                buf += chunk
                if b"\n" in buf:
                    break
        return buf.decode("utf-8", errors="replace").strip()
