"""
DashSocket drops datagrams that don't come from the dash.

Every Tripper shares one Wi-Fi password, so anyone nearby can join the
bike's network and send spoofed K1G datagrams to :2002 (joystick events
such as `exitNav` are not encrypted). `drainAllPendingOnActor` must drop
anything whose source address isn't the host we send to (`dest`), and do
so BEFORE the datagram counts as RX: a spoofer must neither reach
`inbound` nor refresh `lastRxUptime` (that would keep a dead link
looking alive to the heartbeat's silence check).

Suggested by Eduardo (Himalayan 450 rider, Brazil).
"""
from __future__ import annotations

from pathlib import Path

from tests.swift_source import decl_body, strip_comments

ROOT = Path(__file__).resolve().parents[3] / "TripperDashPP"
SOCK = strip_comments((ROOT / "Tripper/DashSocket.swift").read_text(encoding="utf-8"))
DRAIN = decl_body(SOCK, "private func drainAllPendingOnActor")

FILTER = "if n > 0, fromAddr.sin_addr.s_addr != dest.sin_addr.s_addr {"


def test_filter_compares_source_to_the_send_destination() -> None:
    assert FILTER in DRAIN
    # `dest` is the inet_pton'd host (192.168.1.1, or fake_dash's address).
    assert "if inet_pton(AF_INET, host, &destAddr.sin_addr) != 1 {" in SOCK
    assert "self.dest = destAddr" in SOCK


def test_dropped_before_it_counts_as_rx() -> None:
    f = DRAIN.index(FILTER)
    # The drop branch ends in `continue`, before any RX bookkeeping.
    branch = DRAIN[f: DRAIN.index("continue", f)]
    for rx in ("rxDatagramCount &+= 1", "lastRxUptime = now", "inboundContinuation.yield(payload)"):
        assert rx not in branch
        assert DRAIN.index(rx) > DRAIN.index("continue", f), rx


def test_drop_is_logged_once_and_counted() -> None:
    assert "rxRejectedCount &+= 1" in DRAIN
    assert "if rxRejectedCount == 1 {" in DRAIN
    assert "dropped=\\(self.rxRejectedCount)" in SOCK
