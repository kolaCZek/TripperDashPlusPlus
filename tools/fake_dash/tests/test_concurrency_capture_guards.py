"""Guards for the Swift 6 strict-concurrency capture warnings.

Both fixes here silence compiler *warnings*, not errors, so nothing in CI
fails if they regress — `xcodebuild` keeps going and the build stays green
while the diagnostics quietly come back. These guards are the only thing
that actually notices.

The two problems are unrelated beyond both stemming from
`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`:

1. `AppStatus` captured `self` weakly on the *inner* `Task`, inside an
   `onChange:` closure that had already captured `self` strongly. The weak
   capture is then pointless — the outer closure holds the strong reference
   that keeps the object alive anyway. The capture belongs on the outer
   closure.

2. `RideActivityAttributes` picked up a main-actor-isolated
   `ActivityAttributes` conformance from the target's default isolation,
   which ActivityKit cannot use from its own concurrent contexts.
"""

from __future__ import annotations

import pathlib

import pytest

from tests.swift_source import decl_body, strip_comments

REPO = pathlib.Path(__file__).resolve().parents[3]
APP_STATUS = REPO / "TripperDashPP" / "App" / "AppStatus.swift"
RIDE_ATTRS = REPO / "TripperDashPP" / "LiveActivity" / "RideActivityAttributes.swift"

# The observer functions that re-register themselves via
# `withObservationTracking { … } onChange: { … }`.
OBSERVERS = (
    "private func observeBikeLink()",
    "private func observeTrafficRerouteSettings()",
    "private func observeCallStateToggle()",
    "private func observeWeatherToggle()",
    "private func observeSpeedCameraToggle()",
    "private func observeSpeedLimitMode()",
)


@pytest.fixture(scope="module")
def app_status_src() -> str:
    return strip_comments(APP_STATUS.read_text(encoding="utf-8"))


@pytest.fixture(scope="module")
def ride_attrs_src() -> str:
    return strip_comments(RIDE_ATTRS.read_text(encoding="utf-8"))


@pytest.mark.parametrize("anchor", OBSERVERS)
def test_onchange_captures_self_weakly_on_the_outer_closure(app_status_src, anchor):
    """The weak capture must sit on `onChange:`, not on the inner `Task`.

    `withObservationTracking`'s `onChange` closure is stored by the runtime
    until the observed property changes. If it captures `self` strongly, the
    inner `Task`'s `[weak self]` is decorative: the closure itself is already
    keeping `self` alive, so the weak reference can never actually be nil for
    the reason it was written. Swift 6 flags exactly this mismatch.
    """
    body = decl_body(app_status_src, anchor)
    assert "onChange: { [weak self] in" in body, (
        f"{anchor} must capture self weakly on the onChange closure itself — "
        f"a weak capture on the inner Task is cancelled out by the outer "
        f"closure's implicit strong capture, which is what "
        f"'weak ownership of capture differs from implicitly-captured strong "
        f"reference' is warning about."
    )


@pytest.mark.parametrize("anchor", OBSERVERS)
def test_onchange_inner_task_does_not_recapture_self(app_status_src, anchor):
    """The inner Task must not repeat the capture the outer closure made."""
    body = decl_body(app_status_src, anchor)
    assert "Task { @MainActor [weak self] in" not in body, (
        f"{anchor} re-captures self weakly on the inner Task. The outer "
        f"onChange closure already owns the weak capture; repeating it here "
        f"is what produced the original warning."
    )


@pytest.mark.parametrize("anchor", OBSERVERS)
def test_onchange_still_unwraps_self_before_use(app_status_src, anchor):
    """Moving the capture outward must not drop the nil check.

    If `self` is gone the observer must quietly stop, not crash — these fire
    from a runtime-held closure with no guarantee the object still exists.
    """
    body = decl_body(app_status_src, anchor)
    assert "guard let self else { return }" in body, (
        f"{anchor} must still guard-unwrap the weakly captured self before "
        f"touching it."
    )


@pytest.mark.parametrize("anchor", OBSERVERS)
def test_onchange_unwraps_self_outside_the_task(app_status_src, anchor):
    """The unwrap must happen in the closure, not inside the Task.

    Unwrapping inside the Task makes the body read the closure's *captured
    variable* across a concurrency boundary, which trades one Swift 6
    diagnostic for another:

        reference to captured var 'self' in concurrently-executing code

    Unwrapping first gives the Task a plain immutable value to capture. Only
    the observers whose bodies contain an `await` happened to escape the
    second warning, so ordering this correctly everywhere is what keeps the
    file clean rather than coincidence.
    """
    body = decl_body(app_status_src, anchor)
    unwrap = body.index("guard let self else { return }")
    task = body.index("Task { @MainActor in")
    assert unwrap < task, (
        f"{anchor} unwraps self inside the Task. The guard must sit in the "
        f"onChange closure, before the Task, so the Task captures an "
        f"already-unwrapped immutable self."
    )


def test_ride_activity_attributes_conformance_is_nonisolated(ride_attrs_src):
    """ActivityKit calls into this conformance from its own concurrent context.

    The target sets `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so without an
    explicit `nonisolated` the `ActivityAttributes` conformance becomes
    main-actor-isolated and `activity.update(...)` / `activity.end(...)` cannot
    use it — an error under the Swift 6 language mode, a warning today.
    """
    assert "nonisolated struct RideActivityAttributes: ActivityAttributes" in ride_attrs_src, (
        "RideActivityAttributes must be explicitly nonisolated, otherwise it "
        "inherits main-actor isolation from the target's default and "
        "ActivityKit cannot consume the conformance off the main actor."
    )


def test_ride_activity_attributes_stays_free_of_app_types(ride_attrs_src):
    """The nonisolated marking is only safe while this type holds plain values.

    It is compiled into the widget extension too. If an app model or a UI type
    ever lands in here, `nonisolated` stops being a free win and the isolation
    question has to be revisited rather than silently inherited.
    """
    for leaked in ("MKRoute", "ManeuverKind", "DashNavSettings", "UIColor", "import SwiftUI"):
        assert leaked not in ride_attrs_src, (
            f"{leaked!r} leaked into RideActivityAttributes. This type is "
            f"marked nonisolated and shared with the widget extension on the "
            f"understanding that it carries only pre-formatted value types."
        )
