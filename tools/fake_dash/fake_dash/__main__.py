"""
CLI entry point — `python -m fake_dash` or the `fake-dash` console script.

Subcommands:
  server          Start the bike emulator (K1G + RTP). Default for Docker.
  button <name>   Send one joystick event to the running server (over IPC).
                  Names: left, right, down, click.

Configuration via env vars (overridable on the CLI):
  FAKE_DASH_BIND            (default: 0.0.0.0)
  FAKE_DASH_K1G_PORT        (default: 2002)
  FAKE_DASH_RTP_PORT        (default: 5000)
  FAKE_DASH_CAPTURES_DIR    (default: /captures)
  FAKE_DASH_KEYS_DIR        (default: /keys)
  FAKE_DASH_SSID            (default: RE_FAKE_260616)
  FAKE_DASH_LOG_LEVEL       (default: INFO)
  FAKE_DASH_NO_BEACON       (default: unset; set to anything to disable beacon)
"""

from __future__ import annotations

import argparse
import logging
import os
import socket
import sys

from . import __version__
from .buttons import Button, build_button_packet
from .protocol import patch_seq
from .server import (
    DEFAULT_K1G_PORT,
    DEFAULT_RTP_PORT,
    FakeDashServer,
)


def _setup_logging(level_name: str) -> None:
    level = getattr(logging, level_name.upper(), logging.INFO)
    logging.basicConfig(
        level=level,
        format="%(asctime)s %(levelname)-5s %(name)-18s %(message)s",
        datefmt="%H:%M:%S",
    )


def _make_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="fake-dash",
        description="Royal Enfield Tripper TFT emulator — test harness for TripperDash++",
    )
    p.add_argument("--version", action="version", version=f"fake-dash {__version__}")

    sub = p.add_subparsers(dest="command", required=False)

    # server -----------------------------------------------------------
    srv = sub.add_parser("server", help="Run the bike emulator (default).")
    srv.add_argument(
        "--bind",
        default=os.environ.get("FAKE_DASH_BIND", "0.0.0.0"),
        help="Bind address for K1G + RTP sockets (default: 0.0.0.0)",
    )
    srv.add_argument(
        "--k1g-port",
        type=int,
        default=int(os.environ.get("FAKE_DASH_K1G_PORT", DEFAULT_K1G_PORT)),
        help=f"K1G control-plane UDP port (default: {DEFAULT_K1G_PORT})",
    )
    srv.add_argument(
        "--rtp-port",
        type=int,
        default=int(os.environ.get("FAKE_DASH_RTP_PORT", DEFAULT_RTP_PORT)),
        help=f"RTP H.264 sink UDP port (default: {DEFAULT_RTP_PORT})",
    )
    srv.add_argument(
        "--captures-dir",
        default=os.environ.get("FAKE_DASH_CAPTURES_DIR", "/captures"),
        help="Directory where captured H.264 streams are written",
    )
    srv.add_argument(
        "--keys-dir",
        default=os.environ.get("FAKE_DASH_KEYS_DIR", "/keys"),
        help="Directory for persistent RSA keypair",
    )
    srv.add_argument(
        "--ssid",
        default=os.environ.get("FAKE_DASH_SSID", "RE_FAKE_260616"),
        help="Bike SSID expected in the encrypted session-key payload",
    )
    srv.add_argument(
        "--no-beacon",
        action="store_true",
        default=bool(os.environ.get("FAKE_DASH_NO_BEACON")),
        help="Disable the 1 Hz UDP broadcast beacon",
    )
    srv.add_argument(
        "--log-level",
        default=os.environ.get("FAKE_DASH_LOG_LEVEL", "INFO"),
        help="DEBUG, INFO, WARNING, ERROR (default: INFO)",
    )

    # button -----------------------------------------------------------
    btn = sub.add_parser(
        "button",
        help="Send a joystick event to the running server (via UDP loopback).",
    )
    btn.add_argument(
        "name",
        choices=[b.name.lower() for b in Button],
        help="Button to inject",
    )
    btn.add_argument(
        "--target",
        default=os.environ.get("FAKE_DASH_BUTTON_TARGET", "127.0.0.1"),
        help="Where to send the button packet (default: 127.0.0.1 — assumes "
        "you've forwarded UDP/2002 back to your iOS app's listener; for "
        "production-style use, this is wired through the running server "
        "via `docker exec`)",
    )
    btn.add_argument(
        "--port",
        type=int,
        default=int(os.environ.get("FAKE_DASH_K1G_PORT", DEFAULT_K1G_PORT)),
        help=f"Target K1G port (default: {DEFAULT_K1G_PORT})",
    )

    return p


def _run_server(args: argparse.Namespace) -> int:
    _setup_logging(args.log_level)
    log = logging.getLogger("fake_dash.cli")
    log.info("Starting fake_dash %s", __version__)
    server = FakeDashServer(
        bind_addr=args.bind,
        k1g_port=args.k1g_port,
        rtp_port=args.rtp_port,
        keys_dir=args.keys_dir,
        captures_dir=args.captures_dir,
        bike_ssid=args.ssid,
        enable_beacon=not args.no_beacon,
    )
    server.start()
    try:
        server.wait_forever()
    finally:
        server.stop()
    return 0


def _run_button(args: argparse.Namespace) -> int:
    """
    One-shot button sender.

    NOTE: This sends the raw K1G button packet to <target>:<port>. In the
    standard Docker setup you'd run this from *inside* the container via
    `docker compose exec fake_dash python -m fake_dash button left`,
    which puts the packet on the local network namespace so the iPhone
    receives it. For now we emit straight to UDP — a follow-up commit
    will wire it through a Unix socket to the running server so the
    server can fan it out to all known peers.
    """
    _setup_logging("INFO")
    log = logging.getLogger("fake_dash.cli")
    button = Button.from_name(args.name)
    pkt = patch_seq(build_button_packet(button), seq=0)
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.sendto(pkt, (args.target, args.port))
    log.info("Sent %s (%d bytes) → %s:%d", button.name, len(pkt), args.target, args.port)
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = _make_parser()
    args = parser.parse_args(argv)
    cmd = args.command or "server"
    if cmd == "server":
        return _run_server(args)
    if cmd == "button":
        return _run_button(args)
    parser.error(f"unknown command {cmd!r}")
    return 2  # unreachable


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main())
