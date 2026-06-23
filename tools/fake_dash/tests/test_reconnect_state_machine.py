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

Decisions (rider-confirmed): retry every 5 s; hard cap 10 min → then
.error; Cancel (user disconnect) clears the intent any time; Wi-Fi
return wakes a retry immediately but does NOT extend the 10-min budget.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Optional


# Matches K1GConstants.swift.
RECONNECT_INTERVAL = 5.0          # seconds between attempts
RECONNECT_MAX_DURATION = 600.0    # 10-minute hard cap


class LinkState:
    IDLE = "idle"
    CONNECTING = "connecting"
    HANDSHAKING = "handshaking"
    RECONNECTING = "reconnecting"
    CONNECTED = "connected"
    ERROR = "error"


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

    attempts: int = 0
    state_log: list[str] = field(default_factory=list)

    # --- connect / success path --------------------------------------------

    def connect_success(self) -> None:
        """Mirror of a successful runConnectFlow (fresh connect)."""
        self.state = LinkState.CONNECTED
        self.should_auto_reconnect = True
        self.reconnect_deadline = None
        self._log()

    # --- drop --------------------------------------------------------------

    def handle_link_dropped(self, reason: str) -> None:
        """Mirror of handleLinkDropped — idempotent, intent-gated."""
        if not self.should_auto_reconnect:
            return
        if self.state != LinkState.CONNECTED:
            return  # already reconnecting / not droppable
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
            self.handle_link_dropped("wifi-path-down")
        elif satisfied and not prev and self.state == LinkState.RECONNECTING:
            self.wake_reconnect()

    def disconnect(self) -> None:
        """Mirror of user-initiated disconnect()."""
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
    assert link.state == LinkState.RECONNECTING


def test_first_connect_failure_is_not_a_reconnect():
    """A failed FIRST connect (never reached .connected) must NOT enter
    the reconnect loop — shouldAutoReconnect was never armed."""
    link = FakeBikeLink()
    # Never called connect_success → intent stays false.
    link.handle_link_dropped("heartbeat")
    assert link.state == LinkState.IDLE
    assert link.should_auto_reconnect is False
