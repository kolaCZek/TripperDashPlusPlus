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

Foreground navigation is perfectly legal on While Using; only the
screen-locked / in-pocket case needs Always.
"""

from __future__ import annotations

import pathlib

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


def test_while_using_starts_updates_in_auth_callback(src: str):
    """Same hole, second entry point — the one reached after the prompt."""
    branch = _branch(decl_body(src, AUTH_CB), "case .authorizedWhenInUse:")
    assert "startUpdates()" in branch, (
        "the authorization-change callback must start updates on While "
        "Using; this is the path taken right after the user answers the "
        "permission prompt"
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


def test_background_updates_are_gated_on_always(src: str):
    """`allowsBackgroundLocationUpdates = true` THROWS on While Using.

    That runtime exception is exactly why the original code gated the whole
    function behind `.authorizedAlways`. The flag must be gated instead, so
    foreground updates — all the map renderer needs — can still run.
    """
    body = decl_body(src, START)
    assert "manager.allowsBackgroundLocationUpdates =" in body
    assert "authorizationStatus == .authorizedAlways" in body, (
        "allowsBackgroundLocationUpdates must be conditioned on Always; "
        "setting it true on While Using throws at runtime"
    )
    assert "manager.allowsBackgroundLocationUpdates = true" not in body, (
        "never set it unconditionally true — it throws unless auth is Always"
    )


def test_upgrade_to_always_is_not_skipped_by_a_running_check(src: str):
    """After an upgrade we are ALREADY running from the While Using start.

    An `!isRunning` guard on the `.authorizedAlways` branch would skip the
    one call that flips `allowsBackgroundLocationUpdates` on, leaving an app
    that works in the foreground and dies on the lock screen — the single
    most important scenario for this product.
    """
    branch = _branch(decl_body(src, AUTH_CB), "case .authorizedAlways:")
    assert "isRunning" not in branch, (
        "the Always branch must not be gated on !isRunning: the upgrade "
        "path is already running, and skipping startUpdates() would leave "
        "background location updates disabled for the whole ride"
    )
    assert "startUpdates()" in branch


@pytest.mark.parametrize(
    "case_label",
    ["case .authorizedWhenInUse:", "case .authorizedAlways:"],
)
def test_each_callback_start_is_consumer_gated(src: str, case_label: str):
    """Per branch, not per function.

    Checking the whole callback body would pass while one branch starts the
    GPS with nobody listening — the other branch's gate satisfies the grep.
    Mutation-proven: stripping the gate from a single branch survived that
    weaker assertion.
    """
    branch = _branch(decl_body(src, AUTH_CB), case_label)
    assert "startUpdates()" in branch
    assert "consumers.isEmpty" in branch, (
        f"{case_label} must gate startUpdates() on there being a consumer, "
        "or the GPS runs with nobody listening and drains the battery"
    )
