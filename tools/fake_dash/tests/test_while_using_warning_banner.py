"""Guards for the While-Using warning banner shown before navigation starts.

A rider on "While Using" location permission gets a working map right up
until the screen locks, then it goes blank silently (see #133 for the root
cause). The fix in #133 makes foreground use work; this warns the rider
about the pocket case *before* they start riding, when they can still open
Settings and fix it, instead of discovering a dead map mid-ride.

Placed in `planningBanner`, which only renders in `planningBody` (before
`startNavigation` is tapped) — never in `navigatingBody`, so a rider who
already started navigating never sees it fight for space with the live
route.
"""

from __future__ import annotations

import pathlib

import pytest

from tests.swift_source import decl_body, strip_comments

REPO = pathlib.Path(__file__).resolve().parents[3]
SOURCE = REPO / "TripperDashPP" / "UI" / "MapPickerView.swift"

BANNER = "private var planningBanner: some View"


@pytest.fixture(scope="module")
def src() -> str:
    return strip_comments(SOURCE.read_text(encoding="utf-8"))


@pytest.fixture(scope="module")
def banner(src: str) -> str:
    return decl_body(src, BANNER)


def test_banner_checks_while_using(banner: str):
    assert "authorizationStatus == .authorizedWhenInUse" in banner, (
        "the warning must be keyed on .authorizedWhenInUse specifically — "
        "not .denied/.restricted (those already show a different, existing "
        "warning path) and not .notDetermined (nothing to warn about yet)"
    )


def test_banner_mentions_the_screen_lock_consequence(banner: str):
    """The warning must say WHAT breaks, not just that something is off.

    A rider who doesn't know the map dies on lock will dismiss a vague
    permission nag; the whole point is naming the failure they'd otherwise
    hit mid-ride with no error.
    """
    assert "screen locks" in banner


def test_banner_tells_the_rider_what_to_do(banner: str):
    assert "Always" in banner and "Settings" in banner, (
        "the banner must name the fix (Always, in Settings), not just the "
        "symptom — this is a dead end otherwise, since the in-app upgrade "
        "prompt was already answered once"
    )


def test_banner_is_a_distinct_branch_from_the_error_banner(banner: str):
    """Must not silently piggyback on planError and get swallowed by it."""
    assert banner.count("Label(") >= 2, (
        "expected two Label(...) banners: the existing plan error, and the "
        "new While-Using warning as a SEPARATE branch (the 'calculating' "
        "state uses Text, not Label)"
    )
    assert "else if let err = status.planError" in banner
    assert "else if status.locationService.authorizationStatus == .authorizedWhenInUse" in banner, (
        "the warning must be its own else-if branch, not folded into the "
        "planError condition where an unrelated plan error would hide it"
    )


def test_banner_uses_a_different_color_than_the_error_banner(banner: str):
    """Orange, not red — this is advance warning, not a failure that happened."""
    idx = banner.index("authorizedWhenInUse")
    tail = banner[idx:]
    assert ".foregroundStyle(.orange)" in tail
    assert ".foregroundStyle(.red)" not in tail


def test_banner_only_appears_in_planning_not_navigating(src: str):
    """This must render pre-ride, never fight the live route for space."""
    planning_body = decl_body(src, "private func planningBody(plan: PlannedRoute) -> some View")
    navigating_body = decl_body(src, "private var navigatingBody: some View")
    assert "planningBanner" in planning_body
    assert "planningBanner" not in navigating_body, (
        "the While-Using warning must not appear once navigation has "
        "started — a rider already riding can't act on it, and it would "
        "compete with the live route/ETA for the same banner slot"
    )
