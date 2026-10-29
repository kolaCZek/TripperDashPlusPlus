"""
Tests for the auto-reconnect state machine, as implemented in:

  - TripperDashPP/Tripper/BikeLink.swift
    (`.reconnecting` LinkState, `shouldAutoReconnect`, `reconnectDeadline`,
    `handleLinkDropped`, `startReconnectLoop`, `wakeReconnect`,
    `disconnect()` clears the intent, heartbeat-drop + NWPathMonitor wake)
  - TripperDashPP/App/AppStatus.swift
    (`observeBikeLink` kills the stream on drop, re-arms it on reconnect
    while navigating)

Python mirror of the Swift reconnect state machine. The real loop is
async + timer-driven; here we model it as discrete ticks so the
transitions and the 10-min cap are pinned deterministically. Mirrors
the structure of test_reroute_lifecycle.py / test_arrival_detection.py.

Decisions (rider-confirmed): retry every 5 s; hard cap 10 min (Swift
has since raised it to 30 min; this model keeps 10) → then .error;
Cancel (user disconnect) clears the intent any time; Wi-Fi return wakes
a retry immediately but does NOT extend the 10-min budget.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional

from tests.swift_source import decl_body, strip_comments


# RECONNECT_INTERVAL matches K1GConstants.swift. RECONNECT_MAX_DURATION does
# NOT: Swift raised `reconnectMaxDuration` to 1800 s (30 min); this model keeps
# the original 600 s — the cap mechanics are what's pinned, not the value.
RECONNECT_INTERVAL = 5.0          # seconds between attempts
RECONNECT_MAX_DURATION = 600.0    # 10-minute hard cap


class LinkState:
    IDLE = "idle"
    CONNECTING = "connecting"
    HANDSHAKING = "handshaking"
    RECONNECTING = "reconnecting"
    CONNECTED = "connected"
    ERROR = "error"


STABLE_LINK_DURATION = 60.0   # K1G.stableLinkDuration
WIFI_BLIP_GRACE = 3.0         # K1G.wifiBlipGrace


@dataclass
class FakeBikeLink:
    """Mirrors BikeLink's reconnect-relevant state + transitions.

    Time is modelled explicitly (`now`) so we can advance it without
    real sleeps. `handshake_succeeds` lets a test script when the bike
    comes back.
    """

    state: str = LinkState.IDLE
    should_auto_reconnect: bool = False
    reconnect_deadline: Optional[float] = None
    now: float = 0.0
    handshake_succeeds: bool = False
    last_wifi_satisfied: bool = True
    path_down_pending: bool = False   # confirmWifiPathDown's task in flight
    path_down_reason: str = "wifi-path-down"
    stream_failure_kept_at: Optional[float] = None
    blip_kept_at: Optional[float] = None
    connection_id: int = 0            # a new DashSocket per connect
    after_blip_socket: Optional[int] = None   # the tail's captured socket
    blips_kept: int = 0               # onBlipKept calls (AppStatus fixes the stream)

    attempts: int = 0
    state_log: list[str] = field(default_factory=list)

    # --- connect / success path --------------------------------------------

    def connect_success(self) -> None:
        """Mirror of a successful runConnectFlow (fresh connect)."""
        self.state = LinkState.CONNECTED
        self.should_auto_reconnect = True
        self.reconnect_deadline = None
        self.connection_id += 1
        self._log()

    # --- drop --------------------------------------------------------------

    def handle_link_dropped(self, reason: str) -> None:
        """Mirror of handleLinkDropped — idempotent, intent-gated."""
        if not self.should_auto_reconnect:
            return
        if self.state != LinkState.CONNECTED:
            return  # already reconnecting / not droppable
        self.path_down_pending = False   # pathDownCheck?.cancel()
        self.state = LinkState.RECONNECTING
        self.reconnect_deadline = self.now + RECONNECT_MAX_DURATION
        self._log()

    # --- retry loop, modelled as discrete ticks ----------------------------

    def tick(self) -> None:
        """One retry-loop iteration. Mirrors the while-loop body in
        startReconnectLoop: check the cap, attempt, sleep."""
        if self.state != LinkState.RECONNECTING or not self.should_auto_reconnect:
            return
        # 10-min hard cap.
        if self.reconnect_deadline is not None and self.now >= self.reconnect_deadline:
            self.should_auto_reconnect = False
            self.reconnect_deadline = None
            self.state = LinkState.ERROR
            self._log()
            return
        self.attempts += 1
        if self.handshake_succeeds:
            self.connect_success()
            return
        # Failed attempt → sleep the interval.
        self.now += RECONNECT_INTERVAL

    # --- wake / cancel -----------------------------------------------------

    def wake_reconnect(self) -> None:
        """Mirror of wakeReconnect: retry now, preserve the deadline."""
        if self.state != LinkState.RECONNECTING or not self.should_auto_reconnect:
            return
        # Restart the loop immediately — model as an instant extra tick.
        self.tick()

    def wifi_path_update(self, satisfied: bool) -> None:
        """Mirror of the NWPathMonitor handler."""
        prev = self.last_wifi_satisfied
        self.last_wifi_satisfied = satisfied
        if not satisfied and self.state == LinkState.CONNECTED:
            self.confirm_later("wifi-path-down")
        elif satisfied and not prev and self.state == LinkState.RECONNECTING:
            self.wake_reconnect()

    def confirm_later(self, reason: str) -> None:
        """confirmWifiPathDown(reason:) scheduling: one check at a time."""
        if not self.path_down_pending:
            self.path_down_pending = True   # wifiBlipGrace later
            self.path_down_reason = reason
        elif reason == "wifi-path-down":
            self.path_down_reason = reason   # the blip explains the failure

    def report_stream_failed(self) -> None:
        """Mirror of reportStreamFailed: the RTP connection went .failed."""
        if self.state == LinkState.CONNECTED:
            late = (self.blip_kept_at is not None
                    and self.now - self.blip_kept_at < WIFI_BLIP_GRACE)
            self.confirm_later("wifi-path-down" if late else "stream-failed")

    def confirm_wifi_path_down(self, subnet: bool = True) -> None:
        """Mirror of confirmWifiPathDown's check, wifiBlipGrace after the
        first unsatisfied update: a blip keeps the link (a quiet dash is
        left to the heartbeat's 10 s RX-silence check)."""
        if not self.path_down_pending:
            return
        self.path_down_pending = False
        if self.state != LinkState.CONNECTED or not self.should_auto_reconnect:
            return
        reason = self.path_down_reason
        if not (self.last_wifi_satisfied and subnet):
            self.handle_link_dropped(reason)
            return
        if reason == "stream-failed":
            def recent(t):
                return t is not None and self.now - t < STABLE_LINK_DURATION
            if recent(self.stream_failure_kept_at):
                return   # gave up on the stream, link kept
            self.stream_failure_kept_at = self.now
        else:
            self.blip_kept_at = self.now
        self.blips_kept += 1
        self.after_blip_socket = self.connection_id

    def after_blip_check(self, rx_age: float) -> None:
        """Mirror of the tail, wifiBlipGrace after a kept blip."""
        sock, self.after_blip_socket = self.after_blip_socket, None
        if (self.state == LinkState.CONNECTED and sock == self.connection_id
                and not self.path_down_pending and self.last_wifi_satisfied
                and rx_age > WIFI_BLIP_GRACE):
            self.handle_link_dropped("dash-silent-after-blip")

    def disconnect(self) -> None:
        """Mirror of user-initiated disconnect()."""
        self.path_down_pending = False   # pathDownCheck?.cancel()
        self.stream_failure_kept_at = None   # user action: fresh budget
        self.should_auto_reconnect = False
        self.reconnect_deadline = None
        self.state = LinkState.IDLE
        self._log()

    def _log(self) -> None:
        self.state_log.append(self.state)


# --- Drop → reconnect → success --------------------------------------------


def test_drop_enters_reconnecting():
    link = FakeBikeLink()
    link.connect_success()
    link.handle_link_dropped("heartbeat")
    assert link.state == LinkState.RECONNECTING
    assert link.reconnect_deadline == RECONNECT_MAX_DURATION  # now=0 + 600


def test_reconnect_succeeds_when_bike_returns():
    link = FakeBikeLink()
    link.connect_success()
    link.handle_link_dropped("heartbeat")
    # A few failed attempts...
    link.tick()
    link.tick()
    assert link.state == LinkState.RECONNECTING
    # Bike comes back.
    link.handshake_succeeds = True
    link.tick()
    assert link.state == LinkState.CONNECTED
    assert link.should_auto_reconnect is True
    assert link.reconnect_deadline is None


# --- 10-minute cap ----------------------------------------------------------


def test_reconnect_gives_up_after_10_min():
    link = FakeBikeLink()
    link.connect_success()
    link.handle_link_dropped("heartbeat")
    # Never succeeds; grind ticks until past the deadline.
    for _ in range(1000):
        if link.state != LinkState.RECONNECTING:
            break
        link.tick()
    assert link.state == LinkState.ERROR
    assert link.should_auto_reconnect is False
    # Roughly 600 s / 5 s = ~120 attempts before giving up.
    assert 100 <= link.attempts <= 130


def test_wifi_toggle_does_not_extend_the_cap():
    """Repeatedly walking in/out of Wi-Fi wakes retries but must NOT push
    the absolute 10-min deadline outward."""
    link = FakeBikeLink()
    link.connect_success()
    link.handle_link_dropped("heartbeat")
    deadline_at_drop = link.reconnect_deadline
    # Simulate Wi-Fi flapping a few times mid-episode.
    link.now = 120
    link.wifi_path_update(False)   # already reconnecting → no-op on deadline
    link.wifi_path_update(True)    # wake, but deadline preserved
    link.now = 300
    link.wifi_path_update(False)
    link.wifi_path_update(True)
    assert link.reconnect_deadline == deadline_at_drop


# --- User cancel ------------------------------------------------------------


def test_disconnect_clears_reconnect_intent():
    link = FakeBikeLink()
    link.connect_success()
    link.handle_link_dropped("heartbeat")
    link.disconnect()
    assert link.state == LinkState.IDLE
    assert link.should_auto_reconnect is False
    assert link.reconnect_deadline is None


def test_drop_after_disconnect_does_not_reconnect():
    """Once the user has disconnected, a late drop signal (racing socket
    teardown) must not re-arm the loop."""
    link = FakeBikeLink()
    link.connect_success()
    link.disconnect()
    link.handle_link_dropped("heartbeat")   # late signal
    assert link.state == LinkState.IDLE
    assert link.should_auto_reconnect is False


# --- Idempotence ------------------------------------------------------------


def test_second_drop_while_reconnecting_is_noop():
    link = FakeBikeLink()
    link.connect_success()
    link.handle_link_dropped("heartbeat")
    deadline = link.reconnect_deadline
    # A second drop signal (e.g. both heartbeat AND path monitor fire).
    link.now = 50
    link.handle_link_dropped("wifi-path-down")
    # Deadline unchanged — we didn't restart the episode.
    assert link.reconnect_deadline == deadline


def test_wifi_down_while_connected_triggers_reconnect():
    link = FakeBikeLink()
    link.connect_success()
    link.wifi_path_update(False)
    assert link.state == LinkState.CONNECTED   # re-checked after the grace
    link.confirm_wifi_path_down()
    assert link.state == LinkState.RECONNECTING


def test_wifi_blip_keeps_the_link():
    """Field ride 2026-10-29: path blips where cellular fell to EDGE each
    cost a 15-37 s reconnect. Back within the grace, with the dash subnet,
    the session stays."""
    link = FakeBikeLink()
    link.connect_success()
    link.wifi_path_update(False)
    link.wifi_path_update(True)
    link.confirm_wifi_path_down()
    assert link.state == LinkState.CONNECTED
    # Back but without a dash-subnet address: drop.
    link = FakeBikeLink()
    link.connect_success()
    link.wifi_path_update(False)
    link.wifi_path_update(True)
    link.confirm_wifi_path_down(subnet=False)
    assert link.state == LinkState.RECONNECTING


def test_rtp_failure_before_path_down_rides_out_the_blip():
    """Field log 8/2026: the RTP connection fails ~95 ms BEFORE the path
    monitor reports the loss. That must not skip the grace while streaming;
    with Wi-Fi back the link stays and AppStatus restarts the stream."""
    link = FakeBikeLink()
    link.connect_success()
    link.report_stream_failed()
    link.wifi_path_update(False)
    assert link.state == LinkState.CONNECTED
    link.wifi_path_update(True)
    link.confirm_wifi_path_down()
    assert link.state == LinkState.CONNECTED
    assert link.blips_kept == 1
    # Bike switched off: still down after the grace → reconnect.
    link = FakeBikeLink()
    link.connect_success()
    link.report_stream_failed()
    link.wifi_path_update(False)
    link.confirm_wifi_path_down()
    assert link.state == LinkState.RECONNECTING
    assert link.blips_kept == 0


def test_a_stream_failing_on_good_wifi_does_not_restart_forever():
    """One in-place restart, then the stream stays down with the link up (no
    reconnect: that bounces the dash to its no-phone screen for 30 min)."""
    link = FakeBikeLink()
    link.connect_success()
    link.report_stream_failed()
    link.confirm_wifi_path_down()
    assert link.state == LinkState.CONNECTED and link.blips_kept == 1
    link.now += 10
    link.report_stream_failed()
    link.confirm_wifi_path_down()
    assert link.state == LinkState.CONNECTED and link.blips_kept == 1   # gave up
    # A minute later a failure gets its in-place restart again.
    link.now += STABLE_LINK_DURATION
    link.report_stream_failed()
    link.confirm_wifi_path_down()
    assert link.state == LinkState.CONNECTED and link.blips_kept == 2
    # A user Disconnect / Connect starts a fresh budget.
    link.now += 10
    link.disconnect()
    link.connect_success()
    link.report_stream_failed()
    link.confirm_wifi_path_down()
    assert link.blips_kept == 3


def test_a_late_stream_failure_after_a_kept_blip_is_not_budgeted():
    """RTP failing just AFTER the path-down grace was ridden out belongs to
    that blip: restarted, but no budget used."""
    link = FakeBikeLink()
    link.connect_success()
    for _ in range(3):
        link.wifi_path_update(False)
        link.wifi_path_update(True)
        link.confirm_wifi_path_down()      # blip kept
        link.now += 1.0
        link.report_stream_failed()        # late failure, inside the window
        link.confirm_wifi_path_down()
        link.now += 20
    assert link.state == LinkState.CONNECTED
    assert link.blips_kept == 6 and link.stream_failure_kept_at is None
    # Long after a blip the same failure is a real one and is budgeted.
    link.report_stream_failed()
    link.confirm_wifi_path_down()
    assert link.stream_failure_kept_at is not None


def test_blip_caused_stream_failures_do_not_use_up_the_budget():
    """Field order: RTP fails ~100 ms before the path-down. Blips in a
    cluster (EDGE stretch) must each be ridden out with a stream restart,
    not a reconnect or a stream left down."""
    link = FakeBikeLink()
    link.connect_success()
    for _ in range(4):
        link.report_stream_failed()
        link.wifi_path_update(False)
        link.wifi_path_update(True)
        link.confirm_wifi_path_down()
        link.now += 15
    assert link.state == LinkState.CONNECTED
    assert link.blips_kept == 4
    assert link.stream_failure_kept_at is None


def test_dash_silent_after_a_kept_blip_is_rehandshaken():
    link = FakeBikeLink()
    link.connect_success()
    link.wifi_path_update(False)
    link.wifi_path_update(True)
    link.confirm_wifi_path_down()
    link.after_blip_check(rx_age=6.0)
    assert link.state == LinkState.RECONNECTING
    # The dash answers: kept.
    link = FakeBikeLink()
    link.connect_success()
    link.wifi_path_update(False)
    link.wifi_path_update(True)
    link.confirm_wifi_path_down()
    link.after_blip_check(rx_age=0.5)
    assert link.state == LinkState.CONNECTED
    # Wi-Fi down again: that blip gets its own grace, no early drop.
    link.wifi_path_update(False)
    link.wifi_path_update(True)
    link.confirm_wifi_path_down()
    link.wifi_path_update(False)
    link.after_blip_check(rx_age=6.0)
    assert link.state == LinkState.CONNECTED
    # A newer connection is not judged by the old tail.
    link = FakeBikeLink()
    link.connect_success()
    link.wifi_path_update(False)
    link.wifi_path_update(True)
    link.confirm_wifi_path_down()
    link.handle_link_dropped("heartbeat")
    link.connect_success()
    link.after_blip_check(rx_age=6.0)
    assert link.state == LinkState.CONNECTED


def test_a_pending_blip_check_never_judges_the_next_link():
    """Disconnect + connect, or a drop + fast reconnect, inside the grace:
    the old check is cancelled and must not drop the new link."""
    for end in ("disconnect", "drop"):
        link = FakeBikeLink()
        link.connect_success()
        link.wifi_path_update(False)
        if end == "disconnect":
            link.disconnect()
        else:
            link.handle_link_dropped("heartbeat")
        link.connect_success()
        link.confirm_wifi_path_down()   # the cancelled task: no-op
        assert link.state == LinkState.CONNECTED, end


def test_wifi_blip_swift_shape():
    src = strip_comments(_bikelink_src())
    handler = decl_body(src, "private func startPathMonitorIfNeeded")
    assert "if !satisfied, self.state == .connected {\n                    self.confirmWifiPathDown()" in handler
    assert 'handleLinkDropped(reason: "wifi-path-down")' not in handler
    check = decl_body(src, "private func confirmWifiPathDown")
    assert "K1G.wifiBlipGrace" in check
    assert "guard let self, !Task.isCancelled else { return }" in check
    # Decided before any await (disconnect can't cancel it after the nil).
    decide = check[check.index("self.pathDownCheck = nil"):check.index('self.log.notice("Wi-Fi path blip')]
    assert "await" not in decide
    assert "guard self.state == .connected, self.shouldAutoReconnect else { return }" in decide
    assert "guard self.lastWifiSatisfied, subnet else {" in decide
    assert "self.handleLinkDropped(reason: reason)" in decide
    assert "private func confirmWifiPathDown(reason: String = \"wifi-path-down\")" in src
    # Only a kept blip calls AppStatus back, after the decision.
    assert check.count("self.onBlipKept?()") == 1
    assert check.index("Date().timeIntervalSince(t) < K1G.stableLinkDuration") < check.index("self.onBlipKept?()")
    assert "streamFailureDroppedAt" not in src   # no reconnect step: two would do
    # A path-down inside a pending stream-failure check takes over the reason.
    assert 'if reason == "wifi-path-down" { pathDownReason = reason }' in check[:check.index("pathDownReason = reason\n        pathDownCheck = Task")]
    # Both budget timestamps are actually recorded.
    assert "self.streamFailureKeptAt = Date()" in decide
    assert "self.blipKeptAt = Date()" in decide
    # The lost call state is re-pushed on a kept blip.
    kept_branch = check[check.index('self.log.notice("Wi-Fi path blip'):check.index("self.onBlipKept?()")]
    assert "self.lastCallState = nil" in kept_branch and "self.sendCallState(call)" in kept_branch
    assert "let reason = self.pathDownReason" in decide
    # The log-only tail judges the socket of the kept link, not a newer one.
    assert "guard self.state == .connected, let socket = kept, self.socket === socket else { return }" in check
    # A dash silent for the whole window after the blip is re-handshaken.
    tail = check[check.index("let kept = self.socket"):]
    assert "guard self.state == .connected, self.socket === socket, self.pathDownCheck == nil,\n                  self.lastWifiSatisfied, rx > K1G.wifiBlipGrace else { return }" in tail
    assert 'self.handleLinkDropped(reason: "dash-silent-after-blip")' in tail
    # The restart budget survives a reconnect (else a stream failing on
    # every start bounces the dash for the whole reconnect budget).
    # A user disconnect (and only that) gives a fresh budget.
    assert src.count("streamFailureKeptAt = nil") == 1
    assert "streamFailureKeptAt = nil" in decl_body(src, "func disconnect()")
    # An RTP failure just after a kept blip is that blip's (not budgeted).
    assert 'confirmWifiPathDown(reason: late ? "wifi-path-down" : "stream-failed")' in decl_body(src, "func reportStreamFailed")
    assert "Date().timeIntervalSince($0) < K1G.wifiBlipGrace" in decl_body(src, "func reportStreamFailed")
    # Cancelled on every way the link ends.
    for anchor in ("private func handleLinkDropped", "func disconnect()"):
        assert "pathDownCheck?.cancel(); pathDownCheck = nil" in decl_body(src, anchor), anchor
    # A stream whose UDP connection died goes through the same grace (that
    # restarts RTP) — transport failures only, not an encoder start failure.
    rtp = strip_comments((Path(__file__).resolve().parents[3] / "TripperDashPP/Stream/RtpStreamer.swift").read_text(encoding="utf-8"))
    on_state = decl_body(rtp, "private func handleConnectionState")
    failed = on_state[on_state.index("case .failed(let err):"):on_state.index("case .waiting")]
    assert "if state != .idle { bikeLink?.reportStreamFailed() }" in failed
    assert rtp.count("reportStreamFailed()") == 1
    # fail() tears down before marking .failed (stop() only runs from
    # .running/.starting), so a failure doesn't leak the source's location
    # consumer, the encoder or the connection.
    fail = decl_body(rtp, "private func fail(")
    assert fail.index("stop()") < fail.index("state = .failed")
    assert "if bikeHost == K1G.bikeIPv4 { params.requiredInterfaceType = .wifi }" in rtp
    # A failed RTP connection gets the same grace instead of dropping at once.
    report = decl_body(src, "func reportStreamFailed")
    assert '"stream-failed"' in report and "confirmWifiPathDown(reason:" in report
    assert "handleLinkDropped" not in report
    # AppStatus: a dead or still-stalled stream restarts like a reconnect.
    status = strip_comments((Path(__file__).resolve().parents[3] / "TripperDashPP/App/AppStatus.swift").read_text(encoding="utf-8"))
    assert "bikeLink.onBlipKept = { [weak self] in Task { await self?.handleBlipKept() } }" in status
    kept = decl_body(status, "private func handleBlipKept")
    # A live stream is left alone: no START_NAV / PROJ_ON mid-stream.
    assert "sendNavStart" not in kept and "sendProjectionOn" not in kept
    assert "guard streamer === s, bikeLink.state == .connected, s.state == .failed || s.isStalled else { return }" in kept
    dead = kept[kept.index("await bikeLink.sendNavStop()"):]
    assert "if activeNavigator.isNavigating && !activeNavigator.hasArrived {" in dead
    assert dead.index("guard streamer === s else { return }") < dead.index("stopStreaming(sendNavStop: false)") < dead.index("await startStreaming()")
    assert "var isStalled: Bool { isWaiting || pipe.isFailing }" in rtp
    on_state2 = decl_body(rtp, "private func handleConnectionState")
    assert "isWaiting = true" in on_state2[on_state2.index("case .waiting"):] and "isWaiting = false" in on_state2[:on_state2.index("case .failed")]
    assert "if sendNavStop { Task { await link.sendNavStop() } }" in decl_body(status, "func stopStreaming(sendNavStop: Bool = true)")
    assert "await resumeFreeRideAfterReconnect()" in dead


def test_first_connect_failure_is_not_a_reconnect():
    """A failed FIRST connect (never reached .connected) must NOT enter
    the reconnect loop — shouldAutoReconnect was never armed."""
    link = FakeBikeLink()
    # Never called connect_success → intent stays false.
    link.handle_link_dropped("heartbeat")
    assert link.state == LinkState.IDLE
    assert link.should_auto_reconnect is False


# --- Swift-source drift guard: short-lived links carry the budget ------------


def _bikelink_src() -> str:
    root = Path(__file__).resolve().parents[3]
    return (root / "TripperDashPP/Tripper/BikeLink.swift").read_text(encoding="utf-8")


def test_swift_drop_carries_budget_over_a_short_lived_link():
    """A dash that handshakes and then goes quiet used to loop connect →
    drop forever, because `handleLinkDropped` reset `reconnectDeadline` on
    every drop. It must now derive the deadline through
    `dropEpisodeDeadline` (which keeps it for a link up < stableLinkDuration),
    and a reconnect must not wipe the deadline it is meant to carry."""
    src = _bikelink_src()
    drop = strip_comments(decl_body(src, "private func handleLinkDropped"))
    assert "dropEpisodeDeadline(" in drop, (
        "handleLinkDropped must compute the deadline via dropEpisodeDeadline"
    )
    assert "reconnectDeadline = Date().addingTimeInterval" not in drop, (
        "handleLinkDropped unconditionally resets the reconnect budget again"
    )
    flow = strip_comments(decl_body(src, "private func runConnectFlow"))
    assert "connectedAt = Date()" in flow, (
        "runConnectFlow must record when the link reached .connected"
    )
    assert "if !isReconnect { reconnectDeadline = nil }" in flow, (
        "a successful reconnect must keep the episode deadline so a quick "
        "re-drop can carry it over; only a fresh connect clears it"
    )
