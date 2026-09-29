"""Reconnect without dash Wi-Fi, and the RX-cadence measurement line.

1. With the bike off / out of range, en0 has no 192.168.1.x address, so the
   unpinned socket would send the reconnect burst over cellular. The rx=0
   that followed counted as a silent dash (`consecutiveSilentAttempts`) and
   the HUD told the rider to "try the ignition". The reconnect path must now
   bail out BEFORE opening a DashSocket, with a result that isn't
   `bootRaceMissingReply`. A fresh connect still proceeds (the probe can lag
   right after a join).

2. `startInboundLoop` logs one RX max-gap summary per minute (measurement
   only, to decide later whether an RX watchdog is safe) — never per packet.
"""

from __future__ import annotations

from pathlib import Path

from tests.swift_source import decl_body, strip_comments

BIKE_LINK = (
    Path(__file__).resolve().parents[3] / "TripperDashPP" / "Tripper" / "BikeLink.swift"
)


def _flow(src: str | None = None) -> str:
    src = BIKE_LINK.read_text(encoding="utf-8") if src is None else src
    return strip_comments(decl_body(src, "private func runConnectFlow"))


def _inbound(src: str | None = None) -> str:
    src = BIKE_LINK.read_text(encoding="utf-8") if src is None else src
    return strip_comments(decl_body(src, "private func startInboundLoop"))


def test_reconnect_without_dash_subnet_skips_socket_as_non_silent() -> None:
    body = _flow()
    guard = "if isReconnect, !Self.wifiHasDashSubnetIPv4() {"
    assert guard in body
    branch = decl_body(body, guard)
    # Returns a non-silent failure, so consecutiveSilentAttempts can't grow.
    assert "return .otherFailure(" in branch
    assert "bootRaceMissingReply" not in branch
    # ...and it does so before any socket exists.
    assert body.index(guard) < body.index("DashSocket(host:")
    assert body.index("await waitForWifiReady(") < body.index(guard)


def test_fresh_connect_still_opens_socket_without_subnet_check() -> None:
    body = _flow()
    # The only subnet gate in the flow is the reconnect-only one.
    assert body.count("wifiHasDashSubnetIPv4()") == 1
    assert "if isReconnect, !Self.wifiHasDashSubnetIPv4()" in body


def test_other_failure_does_not_count_as_silent_attempt() -> None:
    loop = strip_comments(
        decl_body(BIKE_LINK.read_text(encoding="utf-8"), "private func startReconnectLoop")
    )
    case = loop[loop.index("case .cancelled, .otherFailure:"):]
    case = case[: case.index("}")]
    assert "consecutiveSilentAttempts = 0" in case
    assert "consecutiveSilentAttempts += 1" not in case


def test_inbound_loop_logs_rx_gap_once_per_minute() -> None:
    body = _inbound()
    loop = decl_body(body, "for await packet in socket.inbound")
    assert "max-gap=" in loop
    assert "if now - windowStart >= 60 {" in loop
    # The summary line sits inside the per-minute branch, not per packet.
    minute = decl_body(loop, "if now - windowStart >= 60 {")
    assert "max-gap=" in minute
    assert loop.count("max-gap=") == 1
    # Visible in Release: not .debug, not DEBUG-only.
    assert "self.log.notice(\"RX cadence: max-gap=" in minute
