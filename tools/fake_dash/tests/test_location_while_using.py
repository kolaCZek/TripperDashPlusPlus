"""Guards for location updates on "While Using" authorization.

A rider reported a permanently blank dash map while the ETA and turn arrow
stayed live, reproduced on the author's own phone by setting the app's
location permission to "While Using the App".

Root cause: `startUpdates()` was reachable only from the `.authorizedAlways`
branch. Both `.authorizedWhenInUse` branches (`beginIfNeeded` and the
authorization-change callback) merely re-requested the Always upgrade and
returned. iOS prompts for that upgrade exactly once, so a rider who answers
"Keep While Using" is pinned to that status permanently — no fix ever
reached `MapViewSource`, `lastFix` stayed nil, and `drawVectorOnlyFrame`
early-returned on every frame.

Routing kept working throughout, which is what made the symptom so
confusing: `RoutingService` builds its request with
`MKDirectionsRequest.source = .forCurrentLocation()`, which resolves
through MapKit's own location, not through `LocationService`. Hence a live
ETA and maneuver arrow on top of a blank map.

Foreground navigation is perfectly legal on While Using, and so is the
locked-screen ride: updates start in the foreground with
`allowsBackgroundLocationUpdates = true`, which keeps a While Using app
"in use" in the background (blue indicator pill).
"""

from __future__ import annotations

import pathlib
import re

import pytest

from tests.swift_source import decl_body, strip_comments

REPO = pathlib.Path(__file__).resolve().parents[3]
SOURCE = REPO / "TripperDashPP" / "App" / "LocationService.swift"

BEGIN = "private func beginIfNeeded()"
START = "private func startUpdates()"
AUTH_CB = "nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager)"


@pytest.fixture(scope="module")
def src() -> str:
    return strip_comments(SOURCE.read_text(encoding="utf-8"))


def _branch(body: str, case_label: str) -> str:
    """Return the text of one `switch` case, up to the next `case`."""
    start = body.index(case_label)
    rest = body[start + len(case_label):]
    end = rest.find("case ")
    return rest if end == -1 else rest[:end]


def test_while_using_starts_updates_in_begin(src: str):
    """The bug: this branch asked for an upgrade and returned."""
    branch = _branch(decl_body(src, BEGIN), "case .authorizedWhenInUse:")
    assert "startUpdates()" in branch, (
        "beginIfNeeded must start updates on While Using — iOS prompts for "
        "the Always upgrade only once, so a rider who declines it would "
        "otherwise never get a single location fix"
    )
    assert "if false" not in branch and "if false {" not in branch, (
        "startUpdates() must not sit behind dead code — a literal `if "
        "false { startUpdates() }` satisfies a plain substring check while "
        "never actually starting updates"
    )


def test_while_using_starts_updates_in_auth_callback(src: str):
    """Same hole, second entry point — the one reached after the prompt."""
    branch = _branch(decl_body(src, AUTH_CB), "case .authorizedWhenInUse:")
    assert "startUpdates()" in branch, (
        "the authorization-change callback must start updates on While "
        "Using; this is the path taken right after the user answers the "
        "permission prompt"
    )
    assert "if false" not in branch, (
        "startUpdates() must not sit behind dead code"
    )


def test_always_branch_still_starts_updates(src: str):
    branch = _branch(decl_body(src, BEGIN), "case .authorizedAlways:")
    assert "startUpdates()" in branch


def test_not_determined_does_not_start_updates(src: str):
    """Starting before the user has answered is meaningless.

    `.notDetermined` must only request; the authorization-change callback
    starts updates once an answer arrives.
    """
    branch = _branch(decl_body(src, BEGIN), "case .notDetermined:")
    assert "startUpdates()" not in branch, (
        "do not start updates before the user has answered the prompt"
    )


def test_denied_does_not_start_updates(src: str):
    branch = _branch(decl_body(src, BEGIN), "case .denied, .restricted:")
    assert "startUpdates()" not in branch


def test_background_updates_are_on_regardless_of_always(src: str):
    """While Using riders must keep streaming with the phone locked.

    Gating `allowsBackgroundLocationUpdates` on `.authorizedAlways` let a
    While Using app be suspended shortly after the screen locked, and the
    dash dropped the link 2-3 min into the ride (field report, build 5).
    Apple documents one fatal-error condition for this flag: setting it
    without `location` in UIBackgroundModes. Authorization level is not
    one, so the flag is set unconditionally.
    """
    body = decl_body(src, START)
    assert re.search(
        r"manager\.allowsBackgroundLocationUpdates\s*=\s*true\b", body
    ), "startUpdates() must set allowsBackgroundLocationUpdates = true"
    assert "authorizedAlways" not in body, (
        "startUpdates() must not branch on Always: that is exactly what "
        "suspended While Using riders on the lock screen"
    )
    assert body.count("allowsBackgroundLocationUpdates") == 1, (
        "exactly one assignment, so a later one cannot quietly override it"
    )


def test_info_plist_declares_location_background_mode():
    """The one documented crash for the flag above: `location` missing here."""
    plist = (REPO / "TripperDashPP" / "TripperDashPP-Info.plist").read_text()
    modes = plist.split("<key>UIBackgroundModes</key>", 1)[1].split("</array>", 1)[0]
    assert "<string>location</string>" in modes


def test_upgrade_to_always_is_not_skipped_by_a_running_check(src: str):
    """After an upgrade we are ALREADY running from the While Using start.

    An `!isRunning` guard on the `.authorizedAlways` branch would skip
    `startUpdates()` on a status change mid-ride, so the manager config is
    never re-applied.

    Checking for the literal token `isRunning` is not enough: a rewrite
    could reintroduce the identical skip-bug under a renamed shadow flag
    (e.g. `hasAlreadyStarted`) that tracks the same thing under a new name.
    So additionally require the branch to match the known-good shape
    exactly: a single unconditional (consumer-gated only) `startUpdates()`
    call, with no OTHER boolean guarding it.
    """
    branch = _branch(decl_body(src, AUTH_CB), "case .authorizedAlways:")
    assert "isRunning" not in branch, (
        "the Always branch must not be gated on !isRunning: the upgrade "
        "path is already running, and skipping startUpdates() would leave "
        "background location updates disabled for the whole ride"
    )
    assert re.fullmatch(
        r"\s*if\s+!self\.consumers\.isEmpty\s*\{\s*self\.startUpdates\(\)\s*\}\s*",
        branch,
    ), (
        "the Always branch must be EXACTLY `if !self.consumers.isEmpty { "
        "self.startUpdates() }` — any extra boolean ANDed into that "
        "condition (under any name) reintroduces a skip-bug that renaming "
        "away from `isRunning` would not be caught by a token-absence check"
    )


@pytest.mark.parametrize(
    "case_label",
    ["case .authorizedWhenInUse:", "case .authorizedAlways:"],
)
def test_each_callback_start_is_consumer_gated(src: str, case_label: str):
    """Per branch, not per function, and the gate must actually GOVERN the call.

    Checking the whole callback body would pass while one branch starts the
    GPS with nobody listening — the other branch's gate satisfies the grep.
    Mutation-proven: stripping the gate from a single branch survived that
    weaker assertion.

    Checking mere presence of both substrings is ALSO not enough: a rewrite
    like `self.startUpdates(); if self.consumers.isEmpty { }` (unconditional
    start, with an unrelated empty check sitting next to it) satisfies both
    substring checks while reintroducing exactly the bug this test exists
    to catch. Require `startUpdates()` textually INSIDE the `if
    !consumers.isEmpty { ... }` body via regex, not just present somewhere
    in the branch.
    """
    branch = _branch(decl_body(src, AUTH_CB), case_label)
    gated = re.search(
        r"if\s+!self\.consumers\.isEmpty\s*\{\s*self\.startUpdates\(\)\s*\}",
        branch,
    )
    assert gated, (
        f"{case_label} must call startUpdates() DIRECTLY inside "
        "`if !self.consumers.isEmpty { ... }` — not merely have both "
        "tokens present somewhere in the branch"
    )
    # And there must be no OTHER, ungated startUpdates() call in the branch.
    assert branch.count("startUpdates()") == 1, (
        f"{case_label} has more than one startUpdates() call — the extra "
        "one is likely ungated"
    )
