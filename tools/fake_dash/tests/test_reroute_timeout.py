"""Off-route reroute has a hard time limit (review A4).

While a reroute waits for MKDirections the dash shows "recalculating". The
request used to have no timeout, asked for alternates it never used, and a
failure waited out the full 30 s cooldown — on weak cellular that added up
to about a minute before the next attempt. Now:

  - the navigator hooks cap MKDirections at `routeRequestTimeout` (a sleep
    raced against the reply; the loser cancels the request),
  - the off-route / ETA hook asks for the best route only,
  - after a FAILED attempt the next one comes `rerouteRetryAfterFailure`
    later; a successful swap keeps the full cooldown,
  - the periodic ETA refresh doesn't fire a second request mid-reroute.

The cooldown arithmetic is mirrored in Python; the wiring is pinned with
Swift-source guards.
"""

from __future__ import annotations

import re
from pathlib import Path

from tests.swift_source import decl_body, strip_comments

APP = Path(__file__).resolve().parents[3] / "TripperDashPP"


def _src(rel: str) -> str:
    return strip_comments((APP / rel).read_text(encoding="utf-8"))


def _const(src: str, name: str) -> float:
    m = re.search(rf"let {name}: TimeInterval = ([0-9.]+)", src)
    assert m, f"{name} not found"
    return float(m.group(1))


# --- Mirror of the cooldown gate in ActiveNavigator.ingest ------------------


def next_attempt_allowed(last_reroute_at: float, now: float, cooldown: float) -> bool:
    return now - last_reroute_at >= cooldown


def test_failed_reroute_retries_after_short_delay_success_keeps_cooldown():
    nav = _src("Navigation/ActiveNavigator.swift")
    cooldown = _const(nav, "rerouteCooldown")
    retry = _const(nav, "rerouteRetryAfterFailure")
    timeout = _const(nav, "routeRequestTimeout")
    assert retry < cooldown
    # The "recalculating" window is bounded: one timed-out attempt plus the
    # retry delay stays well under the old ~1 minute.
    assert timeout + retry <= 25

    # Failure at t=timeout (attempt started at 0): the Swift else-branch
    # back-dates lastRerouteAt to now + retry - cooldown.
    failed_at = timeout
    last = failed_at + retry - cooldown
    assert not next_attempt_allowed(last, failed_at + retry - 0.1, cooldown)
    assert next_attempt_allowed(last, failed_at + retry, cooldown)
    # Success keeps lastRerouteAt = attempt start → full cooldown.
    assert not next_attempt_allowed(0, cooldown - 0.1, cooldown)


def test_swift_failure_branch_backdates_cooldown_only_on_failure():
    nav = _src("Navigation/ActiveNavigator.swift")
    reroute = decl_body(nav, "private func requestReroute(")
    backdate = "lastRerouteAt = Date.now.addingTimeInterval(rerouteRetryAfterFailure - rerouteCooldown)"
    assert reroute.count(backdate) == 1
    assert reroute.index("} else {") < reroute.index(backdate)
    # Start of the attempt still stamps the clock (a success keeps 30 s).
    assert reroute.index("lastRerouteAt = .now") < reroute.index("await cb(")


def test_swift_eta_refresh_skipped_while_rerouting():
    nav = _src("Navigation/ActiveNavigator.swift")
    refresh = decl_body(nav, "private func refreshEtaFromApple(")
    guard = refresh[refresh.index("guard"):refresh.index("else { return }")]
    assert "!isRerouting" in guard


def test_swift_route_request_is_raced_against_a_timeout():
    routing = _src("Navigation/RoutingService.swift")
    leg = decl_body(routing, "func calculateLeg(")
    assert "req.requestsAlternateRoutes = alternates" in leg
    assert "try await Self.calculate(directions, timeout: timeout)" in leg
    race = decl_body(routing, "private static func calculate(")
    assert "Task.sleep(" in race
    assert "directions.cancel()" in race
    assert "throw RoutingError.timedOut(seconds: timeout)" in race


def test_swift_route_race_cancels_timer_and_stays_on_main():
    """Review L3: MapKit's reply cancels the timeout Task (none left
    sleeping per request), and the reply is handled in place on main
    (MapKit documents the handler runs on the main thread) rather than
    hopping through a Task with the non-Sendable response."""
    routing = _src("Navigation/RoutingService.swift")
    race = decl_body(routing, "private static func calculate(")
    assert "race.timeoutTask = Task { @MainActor in" in race
    assert "guard !Task.isCancelled, race.waiter != nil else { return }" in race
    handler = race[race.index("directions.calculate { response, error in"):]
    assert handler.lstrip().split("\n")[1].strip() == "MainActor.assumeIsolated {"
    assert "Task {" not in handler
    finish = decl_body(routing, "func finish(")
    assert "timeoutTask?.cancel()" in finish
    # The timer is armed before the request, so a reply can always cancel it.
    assert race.index("race.timeoutTask = Task") < race.index("directions.calculate {")


def test_swift_navigator_hooks_use_timeout_and_offroute_skips_alternates():
    app = _src("App/AppStatus.swift")
    offroute = decl_body(app, "activeNavigator.onRerouteRequested = {")
    assert "alternates: false" in offroute
    assert "timeout: ActiveNavigator.routeRequestTimeout" in offroute
    traffic = decl_body(app, "activeNavigator.onTrafficRoutesRequested = {")
    # The traffic check needs the alternate set; it only gets the timeout.
    assert "alternates: false" not in traffic
    assert "timeout: ActiveNavigator.routeRequestTimeout" in traffic
