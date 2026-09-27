"""The dash heartbeat must not run on the main actor.

With SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor + approachable concurrency,
a plain `func run() async` on HeartbeatLoop runs on the caller's actor —
the main actor, which also bakes map tiles and renders the RTP stream. A
long bake then delays the 1 Hz heartbeat and the dash drops the link
(house icon). Swift can't be compiled on Linux, so pin the isolation in
source.
"""

from __future__ import annotations

import pathlib

from tests.swift_source import decl_body, strip_comments

APP = pathlib.Path(__file__).resolve().parents[3] / "TripperDashPP"


def _src(rel: str) -> str:
    return strip_comments((APP / rel).read_text(encoding="utf-8"))


def test_heartbeat_loop_runs_off_main_actor():
    src = _src("Tripper/HeartbeatLoop.swift")
    assert "nonisolated struct HeartbeatLoop: Sendable {" in src
    assert "@concurrent func run() async" in src


def test_heartbeat_only_waits_for_main_actor_on_first_tick():
    """After tick 0 the loop sends the latest snapshot and refreshes it in
    a background task — a busy main actor must not hold the send."""
    body = decl_body(_src("Tripper/HeartbeatLoop.swift"), "@concurrent func run() async")
    first, rest = body.split("} else if latest.beginRefresh() {", 1)
    assert "if tick == 0 {" in first
    assert "await telemetryProvider()" in first
    refresh, after = rest.split("let t = latest.get()", 1)
    assert "Task { box.finish(await provider()) }" in refresh
    assert "telemetryProvider()" not in after


def test_heartbeat_dependencies_are_nonisolated():
    """Everything the off-main loop calls synchronously must be callable
    off the main actor, or the compiler forces a hop back to main."""
    pkt = _src("Tripper/K1GPacket.swift")
    for sig in (
        "nonisolated static func makeHeartbeat0044(",
        "nonisolated static func makeMetadata0030(",
        "nonisolated static func musicVolumeTLV(",
        "nonisolated static func alarmVolumeTLV(",
        "nonisolated final class RollingSeq: @unchecked Sendable {",
    ):
        assert sig in pkt, sig
    assert "nonisolated struct PhoneTelemetry: Sendable, Equatable {" in _src(
        "Tripper/DeviceTelemetry.swift"
    )
    assert "nonisolated enum K1G {" in _src("Tripper/K1GConstants.swift")
