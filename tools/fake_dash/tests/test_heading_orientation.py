"""
The compass follows the phone's orientation in its mount (issue #225,
reported by renansalenave).

Below ~11 km/h the dash map follows the compass, and `CLHeading` reads the
phone's top edge in `CLLocationManager.headingOrientation` (default
portrait). A phone mounted sideways turned the map by 90°. LocationService
now sets `headingOrientation` from gravity (accelerometer: no permission,
works with Rotation Lock on).

The Swift classifier is mirrored here (`_orientation`) and pinned by its
source lines, so a drift in either fails.
"""
from __future__ import annotations

from pathlib import Path

from tests.swift_source import decl_body, strip_comments

SRC = strip_comments((Path(__file__).resolve().parents[3] / "TripperDashPP/App/LocationService.swift")
                     .read_text(encoding="utf-8"))
CLASSIFY = decl_body(SRC, "nonisolated static func headingOrientation(gx: Double, gy: Double, gz: Double,")


def _orientation(gx, gy, gz, current):
    if not abs(gz) < 0.8:
        return current
    margin = 0.25
    if abs(gy) > abs(gx) + margin:
        return "portrait" if gy < 0 else "portraitUpsideDown"
    if abs(gx) > abs(gy) + margin:
        return "landscapeLeft" if gx < 0 else "landscapeRight"
    return current


def test_swift_classifier_matches_the_mirror() -> None:
    for line in (
        "guard abs(gz) < 0.8 else { return current }",
        "let margin = 0.25",
        "if abs(gy) > abs(gx) + margin { return gy < 0 ? .portrait : .portraitUpsideDown }",
        "if abs(gx) > abs(gy) + margin { return gx < 0 ? .landscapeLeft : .landscapeRight }",
    ):
        assert line in CLASSIFY, line
    assert CLASSIFY.count("return current") == 2


def test_orientations() -> None:
    p = "portrait"
    assert _orientation(0, -1, 0, p) == "portrait"
    assert _orientation(0, -0.6, -0.8 + 0.01, p) == "portrait"          # tilted back in a mount
    assert _orientation(0, 1, 0, p) == "portraitUpsideDown"
    assert _orientation(-1, 0, 0, p) == "landscapeLeft"                 # top edge to the left
    assert _orientation(1, 0, 0, p) == "landscapeRight"
    assert _orientation(-0.7, -0.6, 0, "landscapeLeft") == "landscapeLeft"   # ~45°: no flap
    assert _orientation(-0.7, -0.6, 0, p) == p
    assert _orientation(1, 0, -0.95, p) == p                            # flat on the tank: keep


def test_wired_to_the_heading_updates() -> None:
    start = decl_body(SRC, "private func startUpdates()")
    assert start.index("manager.startUpdatingHeading()") < start.index("startOrientationUpdates()")
    assert "motion.stopAccelerometerUpdates()" in decl_body(SRC, "private func stopUpdates()")
    body = decl_body(SRC, "private func startOrientationUpdates()")
    assert "guard motion.isAccelerometerAvailable, !motion.isAccelerometerActive else { return }" in body
    assert "MainActor.assumeIsolated { self?.applyGravity(g) }" in body
    apply = decl_body(SRC, "private func applyGravity(_ g: CMAcceleration)")
    assert "current: manager.headingOrientation)" in apply
    assert "manager.headingOrientation = next" in apply
