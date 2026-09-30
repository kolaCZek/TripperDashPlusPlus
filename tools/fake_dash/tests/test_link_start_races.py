"""Drift guards for the start / cancel races in the connection flow.

None of this is visible to fake_dash: it is ordering across `await` points on
the main actor (Wi-Fi flap during a ~2 s stream start, Cancel during the Wi-Fi
join, a cancelled handshake unwinding after a newer flow started). The guards
pin the specific code shapes that close each race.

1. `AppStatus.startStreaming` re-checks the streamer, the link and the ride
   intent after its ~2 s of awaits and BEFORE `s.start()` — otherwise a drop
   or a Stop inside that window streams into a dead link or leaves an orphan
   streamer nothing can stop.
2. `AppStatus.observeBikeLink` re-arms observation BEFORE awaiting the resume,
   so a drop during the resume is seen.
3. `AppStatus.connect(to:)` drops a stale join outcome (Cancel during the
   join), and `BikeLink.reportJoinFailure` ignores a failure once the attempt
   is no longer current.
4. `BikeLink.runConnectFlow`'s generic catch treats `Task.isCancelled` as a
   cancel (a cancelled `for await` lands there, not in `catch is
   CancellationError`) and only closes its OWN socket; `runInitialConnect`
   leaves `state` / `connectTask` alone once cancelled.
"""

from __future__ import annotations

import pathlib

import pytest

from tests.swift_source import decl_body, strip_comments

REPO = pathlib.Path(__file__).resolve().parents[3]
APP_STATUS = REPO / "TripperDashPP" / "App" / "AppStatus.swift"
BIKE_LINK = REPO / "TripperDashPP" / "Tripper" / "BikeLink.swift"


@pytest.fixture(scope="module")
def app_src() -> str:
    return APP_STATUS.read_text(encoding="utf-8")


@pytest.fixture(scope="module")
def link_src() -> str:
    return BIKE_LINK.read_text(encoding="utf-8")


def _body(src: str, anchor: str) -> str:
    return strip_comments(decl_body(src, anchor))


# ── #2: startStreaming re-checks before s.start() ─────────────────────────


def test_start_streaming_rechecks_link_before_start(app_src):
    body = _body(app_src, "func startStreaming() async")
    guard = "guard streamer === s, link.state == .connected, hasStreamingIntent else {"
    assert guard in body, (
        "startStreaming must re-check (streamer still ours, link still "
        ".connected, ride still wanted) after its awaits — a drop or Stop in "
        "the ~2 s window otherwise starts an orphan / dead-link stream"
    )
    g = body.index(guard)
    assert body.index("K1G.postZ2Warmup") < g < body.index("s.start()"), (
        "the re-check must sit after the last await (post-z2 warm-up) and "
        "right before s.start()"
    )
    # Nothing that installs ride state may run before the re-check. Only the
    # non-demo path (after `guard streamer == nil`) — the demo branch has the
    # same statements with no re-check.
    live = body[body.index("guard streamer == nil") :]
    lg = live.index(guard)
    for later in ("activeNavLoop = loop", "rideStats.begin()", "self.liveActivity = liveAct"):
        assert later in live and live.index(later) > lg, (
            f"{later} must run only after the re-check"
        )
    bail = body[g : body.index("s.start()")]
    assert "if streamer === s { streamer = nil }" in bail, (
        "the bail path must drop its own not-yet-started streamer (and only "
        "its own — an overlapping resume may have installed a newer one)"
    )
    # Nav-start already went out: leave projection whenever no newer start
    # owns the session — including after a Stop in the window, which nils
    # `streamer` and sends its nav-stop BEFORE our nav-start.
    assert "if self.streamer == nil { await link.sendNavStop() }" in bail, (
        "the bail must send nav-stop whenever `streamer == nil`, not only "
        "when the streamer was still ours — a Stop in the window otherwise "
        "leaves the dash in projection with no video"
    )


def test_start_streaming_superseded_start_skips_nav_start(app_src):
    body = _body(app_src, "func startStreaming() async")
    live = body[body.index("guard streamer == nil") :]
    guard = "guard streamer === s else { return }"
    assert guard in live, (
        "a start superseded during the route-card await must not send its "
        "nav-start / keepalive into a newer session"
    )
    assert (
        live.index("await bikeLink.sendRouteCard(")
        < live.index(guard)
        < live.index("await bikeLink.sendNavStart()")
    )


# ── #2: observer re-arms before awaiting ──────────────────────────────────


def test_observe_bike_link_rearms_before_await(app_src):
    body = _body(app_src, "private func observeBikeLink()")
    task = body[body.index("Task { @MainActor in") :]
    rearm = task.index("self.observeBikeLink()")
    first_await = task.index("await ")
    assert rearm < first_await, (
        "observeBikeLink must re-arm before awaiting startStreaming/resume — "
        "otherwise a drop during the ~2 s resume goes unobserved"
    )
    assert task.count("self.observeBikeLink()") == 1, "re-arm exactly once"


# ── #3: Cancel during the Wi-Fi join ──────────────────────────────────────


def test_connect_join_task_drops_stale_outcome(app_src):
    body = _body(app_src, "func connect(to bike: SavedBike)")
    assert "joinTask?.cancel()" in body
    assert "joinTask = Task { @MainActor in" in body
    guard = "guard !Task.isCancelled, bikeLink.state == .connecting else { return }"
    assert guard in body, (
        "after the join await, a Cancel (.idle) or a newer flow must make the "
        "outcome a no-op"
    )
    assert (
        body.index("await wifiJoiner.ensureJoined")
        < body.index(guard)
        < body.index("switch outcome")
    )


def test_report_join_failure_only_while_joining(link_src):
    body = _body(link_src, "func reportJoinFailure")
    guard = "guard state == .connecting, connectTask == nil else {"
    assert guard in body
    assert body.index(guard) < body.index("state = .error(message)")


# ── #8: stale flow unwind can't clobber a newer flow ──────────────────────


def test_connect_flow_generic_catch_honours_cancellation(link_src):
    body = _body(link_src, "private func runConnectFlow")
    # The explicit CancellationError branch closes only its own socket too.
    cancel_catch = body[body.index("} catch is CancellationError {") : body.rindex("} catch {")]
    assert "await flowSocket?.cancel()" in cancel_catch
    assert "if self.socket === flowSocket { self.socket = nil }" in cancel_catch
    assert "return .cancelled" in cancel_catch
    generic = body[body.rindex("} catch {") :]
    cancelled = generic.index("if Task.isCancelled {")
    assert cancelled < generic.index("self.lastError = msg"), (
        "a cancelled for-await lands in the generic catch — it must return "
        "before setting lastError / .error"
    )
    assert cancelled < generic.index("self.state = .error(msg)")
    assert "return .cancelled" in generic[cancelled:generic.index("self.lastError = msg")]
    # Close only this attempt's socket — never whatever self.socket holds now.
    assert "self.socket?.cancel()" not in body
    assert "await flowSocket?.cancel()" in body
    assert "if self.socket === flowSocket { self.socket = nil }" in generic


def test_initial_connect_ignores_result_once_cancelled(link_src):
    body = _body(link_src, "private func runInitialConnect")
    guard = "guard !Task.isCancelled else { return }"
    assert guard in body
    assert (
        body.index("await runConnectFlow(isReconnect: false)")
        < body.index(guard)
        < body.index("switch result")
    ), "check cancellation before touching state / connectTask"


def test_connect_flow_in_flight_is_counted(link_src):
    """A stale flow's `defer` must not clear the flag for a newer live flow."""
    body = _body(link_src, "private func runConnectFlow")
    assert "connectFlowsInFlight += 1" in body
    assert "defer { connectFlowsInFlight -= 1 }" in body
