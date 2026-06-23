"""
Tests for the connect-first navigation gate, as implemented in:

  - TripperDashPP/UI/MapPickerView.swift
    (controlButton: "Start navigation" only renders in
    (.picking, .connected) where isPlanning; planning while not
    connected shows "Connect & start navigation" instead (tapping it
    arms auto-start — see test_nav_autostart.py).
    startNavigation(plan:) also hard-guards on .connected and bounces
    to connect() if the link dropped between render and tap.)

Rationale: navigation IS projection onto the dash. Starting it with no
link is meaningless — the rider would "navigate" with nothing on the
TFT. So the Start CTA is gated behind a live connection. A drop DURING
navigation is NOT gated here — that's the reconnect path's job (see
test_reconnect_state_machine.py); this gate is purely about START.

Python mirror of the gate decision, structured like the other mirror
suites. Models the (mode, link_state, is_planning) → control mapping
and the startNavigation guard.
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


# Control identifiers returned by the mirror of `controlButton`.
class Control:
    SWITCHING = "switching"
    STOP_NAV = "stop_nav"
    CONNECTING = "connecting"
    RECONNECTING = "reconnecting"
    START_PLAN = "start_plan"          # the gated "Start navigation"
    CONNECTED_IDLE = "connected_idle"
    CONNECT = "connect"                # "Connect to dash" / "Connect & start navigation"


def control_for(mode: str, link: str, is_planning: bool) -> str:
    """Mirror of MapPickerView.controlButton's switch — same case order."""
    if mode == Mode.TRANSITIONING:
        return Control.SWITCHING
    if mode == Mode.NAVIGATING:
        return Control.STOP_NAV
    # mode == picking from here.
    if link in (LinkState.CONNECTING, LinkState.HANDSHAKING):
        return Control.CONNECTING
    if link == LinkState.RECONNECTING:
        return Control.RECONNECTING
    if link == LinkState.CONNECTED and is_planning:
        return Control.START_PLAN
    if link == LinkState.CONNECTED:
        return Control.CONNECTED_IDLE
    # idle / error.
    return Control.CONNECT


@dataclass
class FakeStarter:
    """Mirror of the startNavigation(plan:) guard."""

    link: str
    is_streaming: bool = False
    plan_computed: bool = True

    nav_started: bool = False
    connect_called: bool = False
    stream_started: bool = False

    def start_navigation(self) -> None:
        if not self.plan_computed:
            return
        # Connect-first hard guard.
        if self.link != LinkState.CONNECTED:
            self.connect_called = True
            return
        self.nav_started = True
        if not self.is_streaming:
            self.stream_started = True


# --- The bug being fixed ----------------------------------------------------


def test_start_is_NOT_offered_when_planning_but_disconnected():
    """The whole point: a laid-out plan while idle must NOT show Start."""
    for link in (LinkState.IDLE, LinkState.ERROR):
        ctrl = control_for(Mode.PICKING, link, is_planning=True)
        assert ctrl == Control.CONNECT, f"link={link} wrongly offered {ctrl}"


def test_start_is_offered_only_when_connected_and_planning():
    ctrl = control_for(Mode.PICKING, LinkState.CONNECTED, is_planning=True)
    assert ctrl == Control.START_PLAN


def test_planning_while_connecting_shows_progress_not_start():
    for link in (LinkState.CONNECTING, LinkState.HANDSHAKING):
        ctrl = control_for(Mode.PICKING, link, is_planning=True)
        assert ctrl == Control.CONNECTING


def test_planning_while_reconnecting_shows_reconnect_not_start():
    ctrl = control_for(Mode.PICKING, LinkState.RECONNECTING, is_planning=True)
    assert ctrl == Control.RECONNECTING


# --- Non-planning states unchanged ------------------------------------------


def test_connected_without_plan_shows_idle_prompt():
    ctrl = control_for(Mode.PICKING, LinkState.CONNECTED, is_planning=False)
    assert ctrl == Control.CONNECTED_IDLE


def test_idle_without_plan_shows_connect():
    ctrl = control_for(Mode.PICKING, LinkState.IDLE, is_planning=False)
    assert ctrl == Control.CONNECT


def test_navigating_always_shows_stop_regardless_of_link():
    # During navigation a drop → reconnecting must NOT swap the bottom bar;
    # the Stop control stays put (reconnect surfaces on the HUD banner).
    for link in vars(LinkState).values():
        if not isinstance(link, str):
            continue
        ctrl = control_for(Mode.NAVIGATING, link, is_planning=True)
        assert ctrl == Control.STOP_NAV


# --- startNavigation guard --------------------------------------------------


def test_start_navigation_blocked_when_not_connected():
    s = FakeStarter(link=LinkState.IDLE)
    s.start_navigation()
    assert s.nav_started is False
    assert s.connect_called is True   # bounces to connect instead


def test_start_navigation_proceeds_when_connected():
    s = FakeStarter(link=LinkState.CONNECTED)
    s.start_navigation()
    assert s.nav_started is True
    assert s.stream_started is True
    assert s.connect_called is False


def test_start_navigation_does_not_double_stream():
    s = FakeStarter(link=LinkState.CONNECTED, is_streaming=True)
    s.start_navigation()
    assert s.nav_started is True
    assert s.stream_started is False  # already streaming → no restart


def test_start_navigation_race_drop_between_render_and_tap():
    """UI showed Start (was connected) but the link dropped just before
    the tap landed → guard catches it, no nav into the void."""
    s = FakeStarter(link=LinkState.RECONNECTING)
    s.start_navigation()
    assert s.nav_started is False
    assert s.connect_called is True
