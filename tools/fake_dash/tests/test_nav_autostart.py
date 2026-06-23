"""
Tests for auto-start-on-connect, as implemented in:

  - TripperDashPP/UI/MapPickerView.swift
    (pendingAutoStart flag, armed by "Connect & start navigation";
    tryAutoStartNavigation() fired from onChange(bikeLink.state) and
    onChange(plannedRoute.isComputed); cleared on idle/error, on plan
    teardown, and on Cancel.)

Behaviour: when the rider taps "Connect & start navigation" (only shown
while a plan is laid out and the link is idle/errored), the app arms
pendingAutoStart and kicks off connect(). The moment the link reaches
.connected AND the plan is computed, navigation auto-starts — no second
tap. The arm is intentionally inert for mid-ride reconnects, idle
connects without a plan, and failed/cancelled connects.

Python mirror of the arm/fire/cancel decision logic.
"""

from __future__ import annotations

from dataclasses import dataclass


class Mode:
    PICKING = "picking"
    NAVIGATING = "navigating"
    TRANSITIONING = "transitioning"


class LinkState:
    IDLE = "idle"
    CONNECTING = "connecting"
    HANDSHAKING = "handshaking"
    RECONNECTING = "reconnecting"
    CONNECTED = "connected"
    ERROR = "error"


@dataclass
class FakeView:
    """Mirror of the MapPickerView auto-start state machine."""

    link: str = LinkState.IDLE
    mode: str = Mode.PICKING
    has_plan: bool = False
    plan_computed: bool = False

    pending_auto_start: bool = False
    nav_started: int = 0
    connect_called: int = 0

    # --- user actions -------------------------------------------------------

    def tap_connect_control(self) -> None:
        """Mirror of connectControl's button action."""
        if self.has_plan:           # isPlanning
            self.pending_auto_start = True
        self.connect_called += 1
        self.link = LinkState.CONNECTING

    def tap_cancel(self) -> None:
        """Cancel during connecting/handshaking."""
        self.pending_auto_start = False
        self.link = LinkState.IDLE

    def clear_plan(self) -> None:
        """Rider tears the plan down (cleared destination)."""
        self.has_plan = False
        self.plan_computed = False
        self._on_planning_changed(False)

    # --- link / plan transitions (the onChange hooks) -----------------------

    def set_link(self, new: str) -> None:
        self.link = new
        self._handle_link_state(new)

    def set_plan_computed(self, computed: bool) -> None:
        self.plan_computed = computed
        self._try_auto_start()       # onChange(plannedRoute.isComputed)

    def start_navigating(self) -> None:
        """Simulate having reached the navigating phase."""
        self.mode = Mode.NAVIGATING

    # --- mirror of the private handlers -------------------------------------

    def _handle_link_state(self, new: str) -> None:
        if new == LinkState.CONNECTED:
            self._try_auto_start()
        elif new in (LinkState.IDLE, LinkState.ERROR):
            self.pending_auto_start = False
        # connecting / handshaking / reconnecting → no-op

    def _on_planning_changed(self, planning: bool) -> None:
        if not planning:
            self.pending_auto_start = False

    def _try_auto_start(self) -> None:
        if not self.pending_auto_start:
            return
        if self.link != LinkState.CONNECTED:
            return
        if self.mode != Mode.PICKING:
            return
        if not (self.has_plan and self.plan_computed):
            return
        self.pending_auto_start = False
        self.nav_started += 1


# --- happy path -------------------------------------------------------------


def test_auto_start_fires_when_connected_and_plan_ready():
    v = FakeView(has_plan=True, plan_computed=True)
    v.tap_connect_control()
    assert v.pending_auto_start is True
    v.set_link(LinkState.HANDSHAKING)   # interim, no fire
    assert v.nav_started == 0
    v.set_link(LinkState.CONNECTED)
    assert v.nav_started == 1
    assert v.pending_auto_start is False  # consumed


def test_auto_start_waits_for_plan_to_finish_computing():
    """Rider taps connect before the route finished baking. Connect
    completes first; the plan-computed trigger fires the start."""
    v = FakeView(has_plan=True, plan_computed=False)
    v.tap_connect_control()
    v.set_link(LinkState.CONNECTED)
    assert v.nav_started == 0            # plan not ready yet → held
    assert v.pending_auto_start is True  # still armed
    v.set_plan_computed(True)
    assert v.nav_started == 1
    assert v.pending_auto_start is False


# --- the feature must NOT fire in these cases -------------------------------


def test_no_arm_without_plan():
    """Plain 'Connect to dash' (no plan) must never arm auto-start."""
    v = FakeView(has_plan=False)
    v.tap_connect_control()
    assert v.pending_auto_start is False
    v.set_link(LinkState.CONNECTED)
    assert v.nav_started == 0


def test_reconnect_midride_does_not_autostart():
    """A drop+reconnect while navigating must not re-launch navigation.
    mode == navigating, and pending_auto_start was never armed there."""
    v = FakeView(has_plan=True, plan_computed=True, mode=Mode.NAVIGATING)
    # Link drops then recovers mid-ride:
    v.set_link(LinkState.RECONNECTING)
    v.set_link(LinkState.CONNECTED)
    assert v.nav_started == 0


def test_failed_connect_clears_arm():
    v = FakeView(has_plan=True, plan_computed=True)
    v.tap_connect_control()
    assert v.pending_auto_start is True
    v.set_link(LinkState.ERROR)          # handshake failed
    assert v.pending_auto_start is False
    # A later successful connect must not silently fire the old intent:
    v.set_link(LinkState.CONNECTED)
    assert v.nav_started == 0


def test_cancel_clears_arm():
    v = FakeView(has_plan=True, plan_computed=True)
    v.tap_connect_control()
    v.tap_cancel()
    assert v.pending_auto_start is False
    v.set_link(LinkState.CONNECTED)
    assert v.nav_started == 0


def test_plan_teardown_while_connecting_clears_arm():
    v = FakeView(has_plan=True, plan_computed=True)
    v.tap_connect_control()
    assert v.pending_auto_start is True
    v.clear_plan()                       # rider cleared the destination
    assert v.pending_auto_start is False
    v.set_link(LinkState.CONNECTED)
    assert v.nav_started == 0


def test_idempotent_no_double_start():
    """Both triggers (link + plan-computed) can fire close together; the
    flag guard means navigation starts exactly once."""
    v = FakeView(has_plan=True, plan_computed=True)
    v.tap_connect_control()
    v.set_link(LinkState.CONNECTED)      # fires
    v.set_plan_computed(True)            # would re-fire, but flag cleared
    assert v.nav_started == 1


def test_already_connected_then_arm_fires_on_plan_ready():
    """Edge: link already connected (idle-connected), rider builds a plan
    and taps connect-control? In practice the control would be the Start
    button, but verify the arm+fire still resolves through plan-ready."""
    v = FakeView(has_plan=True, plan_computed=False, link=LinkState.CONNECTED)
    # Simulate arming directly (connected, plan still baking).
    v.pending_auto_start = True
    v._try_auto_start()
    assert v.nav_started == 0            # plan not computed
    v.set_plan_computed(True)
    assert v.nav_started == 1
