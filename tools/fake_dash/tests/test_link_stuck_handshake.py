"""
Drift guards for "a reconnect must never hang forever" (connection audit, PR E).

1. Handshake step 3 (wait for auth-OK) used a `for await socket.inbound` with
   an in-loop `Date() > okDeadline` check. If the dash goes silent after
   step 1 (ignition off mid-reconnect) no packet ever arrives, the check never
   runs, and the link sits in `.reconnecting` forever holding the wakelock.
   Step 3 must use the same wall-clock task-group race as step 1.

2. Stopping navigation while `.reconnecting` (`isStreaming == false`) never
   re-ran `applyKeepAwake()`, so the location wakelock stayed held. AppStatus
   must observe `hasStreamingIntent` and re-evaluate the gate on every flip.

3. `DashSocket.cancel()` must invalidate `fd` before cancelling the read
   source, whose handler closes the descriptor asynchronously on ioQueue.

We can't run Swift here; these source guards are the standard substitute.
"""

from __future__ import annotations

from pathlib import Path

from tests.swift_source import decl_body, strip_comments

_APP = Path(__file__).resolve().parents[3] / "TripperDashPP"
BIKELINK = _APP / "Tripper" / "BikeLink.swift"
DASHSOCKET = _APP / "Tripper" / "DashSocket.swift"
APPSTATUS = _APP / "App" / "AppStatus.swift"


def _step3(src: str) -> str:
    body = strip_comments(decl_body(src, "private func runHandshake"))
    # Everything after the q3c.d session-key send is step 3.
    return body[body.index("K1GPacket.makeSessionKey"):]


def test_handshake_step3_is_a_wall_clock_race() -> None:
    step3 = _step3(BIKELINK.read_text())
    assert "withThrowingTaskGroup(of: HandshakeOutcome.self)" in step3
    assert "Task.sleep(nanoseconds: UInt64(K1G.handshakeStepTimeout" in step3
    # The timeout arm throws the same classification the retry loop maps
    # to the boot-race retry (reconnect) / silent retry (fresh connect).
    sleep_at = step3.index("Task.sleep(nanoseconds: UInt64(K1G.handshakeStepTimeout")
    assert "throw HandshakeError.authNotReady(" in step3[sleep_at:]
    assert "group.cancelAll()" in step3
    # The old packet-gated deadline must be gone.
    assert "okDeadline" not in step3


def test_streaming_intent_flip_reapplies_keep_awake() -> None:
    src = APPSTATUS.read_text()
    obs = strip_comments(decl_body(src, "private func observeStreamingIntent"))
    assert "_ = hasStreamingIntent" in obs
    assert "self.applyKeepAwake()" in obs
    assert "self.observeStreamingIntent()" in obs  # re-registers
    wiring = strip_comments(decl_body(src, "private func wireNavigation"))
    assert "observeStreamingIntent()" in wiring


def test_dashsocket_cancel_clears_fd_before_source_cancel() -> None:
    body = strip_comments(decl_body(DASHSOCKET.read_text(), "func cancel()"))
    assert "fd = -1" in body
    assert body.index("fd = -1") < body.index("src.cancel()")
