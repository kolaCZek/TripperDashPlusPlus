"""
One title for the ride on the dash route card and the Live Activity.

`AppStatus.stagedDestination` lost its last non-nil write in the
planning-mode rework, so the pre-z2 route card and its post-z2 confirmation
announced "Free ride" during navigation (field log 2026-09-30:
`Sent 0x007e route card x4 (title=Free ride)`) and the Live Activity started
untitled, while the 1 Hz keep-alive sent the CURRENT leg's stop. Every one of
them now reads `ActiveNavigator.rideTitle` — the plan's final stop, nil when
not navigating — and the dead `stagedDestination` is gone.
"""

from __future__ import annotations

from pathlib import Path

from tests.swift_source import decl_body, strip_comments

REPO = Path(__file__).resolve().parents[3]
APP = REPO / "TripperDashPP"
STATUS = APP / "App" / "AppStatus.swift"
LOOP = APP / "Navigation" / "ActiveNavLoop.swift"
NAV = APP / "Navigation" / "ActiveNavigator.swift"


def _code(path: Path) -> str:
    return strip_comments(path.read_text(encoding="utf-8"))


def test_ride_title_is_final_stop_and_nil_when_not_navigating() -> None:
    body = decl_body(_code(NAV), "var rideTitle: String?")
    assert "guard isNavigating else { return nil }" in body
    assert "plan?.waypoints.last?.name" in body


def test_start_streaming_titles_read_ride_title() -> None:
    body = decl_body(_code(STATUS), "func startStreaming()")
    assert "title: activeNavigator.rideTitle ?? \"Free ride\"," in body
    assert "sendRouteCardKeepalive(title: activeNavigator.rideTitle ?? \"Free ride\")" in body
    # Demo branch and real branch both title the Live Activity.
    assert body.count("liveAct.start(destinationName: activeNavigator.rideTitle)") == 2
    # Free ride keeps its placeholder-free pre-z2 card.
    assert "includeManeuverPlaceholders: !isFreeRiding" in body


def test_keepalive_reads_ride_title() -> None:
    body = decl_body(_code(LOOP), "private func tick()")
    assert "title: nav.rideTitle ?? \"Free ride\"" in body


def test_staged_destination_is_gone() -> None:
    for path in APP.rglob("*.swift"):
        assert "stagedDestination" not in path.read_text(encoding="utf-8"), path
