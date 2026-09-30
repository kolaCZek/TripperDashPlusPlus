"""Reconnect without dash Wi-Fi, the RX-silence watchdog, transient send errors.

1. With the bike off / out of range, en0 has no 192.168.1.x address, so the
   unpinned socket would send the reconnect burst over cellular. The rx=0
   that followed counted as a silent dash (`consecutiveSilentAttempts`) and
   the HUD told the rider to "try the ignition". The reconnect path must now
   bail out BEFORE opening a DashSocket, with a result that isn't
   `bootRaceMissingReply`. A fresh connect still proceeds (the probe can lag
   right after a join).

2. A dash that stops talking while `sendto` still succeeds (K1G task wedged,
   dash app restarted with the AP up) used to stay "Connected" forever. The
   heartbeat now stops (= link drop) after `K1G.rxSilenceTimeout` without RX.
   The 10 s value comes from a 1 h ride log: max gap 3.5 s, p99.9 1 s.

3. The heartbeat tolerates a few transient send errors in a row, resets the
   count on a good tick, and still stops on anything else.
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
    guard = "if isReconnect, bikeHost == K1G.bikeIPv4, !Self.wifiHasDashSubnetIPv4() {"
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
    # The only subnet gate in the flow is the reconnect-only one, and it only
    # applies to the real dash address (a fake_dash laptop can sit elsewhere).
    assert body.count("wifiHasDashSubnetIPv4()") == 1
    assert "if isReconnect, bikeHost == K1G.bikeIPv4, !Self.wifiHasDashSubnetIPv4()" in body


def test_other_failure_does_not_count_as_silent_attempt() -> None:
    loop = strip_comments(
        decl_body(BIKE_LINK.read_text(encoding="utf-8"), "private func startReconnectLoop")
    )
    case = loop[loop.index("case .cancelled, .otherFailure:"):]
    case = case[: case.index("}")]
    assert "consecutiveSilentAttempts = 0" in case
    assert "consecutiveSilentAttempts += 1" not in case


ROOT = BIKE_LINK.parents[1]


def _src(rel: str) -> str:
    return strip_comments((ROOT / rel).read_text(encoding="utf-8"))


def test_rx_silence_stops_the_heartbeat() -> None:
    k1g = _src("Tripper/K1GConstants.swift")
    assert "static let rxSilenceTimeout: TimeInterval = 10.0" in k1g
    sock = _src("Tripper/DashSocket.swift")
    assert "func secondsSinceLastRx() -> TimeInterval" in sock
    drain = decl_body(sock, "private func drainAllPendingOnActor")
    got = drain[drain.index("if n > 0 {"):]
    assert "lastRxUptime = ProcessInfo.processInfo.systemUptime" in got[: got.index("continue")]
    run = decl_body(_src("Tripper/HeartbeatLoop.swift"), "@concurrent func run")
    check = run.index("await socket.secondsSinceLastRx()")
    decide = "if Self.isDashSilent(silence: silence, sentTicksWithoutRx: sentTicksWithoutRx) {"
    assert decide in run[check:]
    after = run[run.index(decide):]
    assert "return" in after[: after.index("}")]
    # Only ticks actually sent count, and a fresh RX resets them, so a
    # phone-side stall isn't read as a silent dash.
    ok = run[run.index("try await socket.send(md)"):run.index("} catch {")]
    assert "sentTicksWithoutRx += 1" in ok
    reset = "if silence < 2 * K1G.heartbeatInterval { sentTicksWithoutRx = 0 }"
    assert check < run.index(reset) < run.index(decide)
    # The loop's uncancelled return is what turns into a link drop.
    link = strip_comments(decl_body(BIKE_LINK.read_text(encoding="utf-8"), "private func startHeartbeat"))
    drop = link[link.index("await loop.run()"):]
    guard = drop[drop.index("if !Task.isCancelled {"):]
    assert 'handleLinkDropped(reason: "heartbeat")' in guard[: guard.index("}")]
    # Checked every tick, before the sleep.
    assert check < run.index("try? await Task.sleep")
    # The measurement-only minute log it replaced is gone.
    assert "RX cadence" not in _inbound()


def test_heartbeat_tolerates_transient_send_errors_only() -> None:
    run = decl_body(_src("Tripper/HeartbeatLoop.swift"), "@concurrent func run")
    ok = run[run.index("try await socket.send(md)"):run.index("} catch {")]
    assert "transientFailures = 0" in ok
    catch = run[run.index("} catch {"):run.index("await socket.secondsSinceLastRx()")]
    assert "Self.isTransientSendError(error), transientFailures < Self.maxTransientSendFailures" in catch
    assert "transientFailures += 1" in catch
    tail = catch[catch.index("} else {"):]
    assert "return" in tail
