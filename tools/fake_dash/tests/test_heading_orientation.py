"""
The compass follows the phone's orientation in its mount (issue #225,
reported by renansalenave).

Below ~11 km/h the dash map follows the compass, and `CLHeading` reads the
phone's top edge in `CLLocationManager.headingOrientation` (default
portrait). A phone mounted sideways turned the map by 90°. LocationService
now sets `headingOrientation` from low-passed gravity (accelerometer: no
permission, works with Rotation Lock on).

The Swift classifier and filter are mirrored here and pinned by their
source lines, so a drift in either fails.
"""
from __future__ import annotations

import math
from pathlib import Path

from tests.swift_source import decl_body, strip_comments

SRC = strip_comments((Path(__file__).resolve().parents[3] / "TripperDashPP/App/LocationService.swift")
                     .read_text(encoding="utf-8"))
CLASSIFY = decl_body(SRC, "nonisolated static func headingOrientation(gx: Double, gy: Double,")
APPLY = decl_body(SRC, "private func applyGravity(_ g: CMAcceleration)")


def _orientation(gx, gy, current):
    in_plane = math.hypot(gx, gy)
    if not in_plane >= 0.3:
        return current
    margin = 0.25 * in_plane
    if abs(gy) > abs(gx) + margin:
        return "portrait" if gy < 0 else "portraitUpsideDown"
    if abs(gx) > abs(gy) + margin:
        return "landscapeLeft" if gx < 0 else "landscapeRight"
    return current


def _filtered(samples, a=0.2):
    f = None
    out = []
    for g in samples:
        f = g if f is None else tuple(p + a * (q - p) for p, q in zip(f, g))
        out.append(f)
    return out


def _tilted(edge_down, tilt_deg):
    """Gravity for a phone tilted back `tilt_deg` from vertical."""
    c, s = math.cos(math.radians(tilt_deg)), math.sin(math.radians(tilt_deg))
    x, y = {"portrait": (0, -1), "landscapeLeft": (-1, 0), "landscapeRight": (1, 0)}[edge_down]
    return (x * c, y * c, -s)


def test_swift_classifier_matches_the_mirror() -> None:
    for line in (
        "let inPlane = (gx * gx + gy * gy).squareRoot()",
        "guard inPlane >= 0.3 else { return current }",
        "let margin = 0.25 * inPlane",
        "if abs(gy) > abs(gx) + margin { return gy < 0 ? .portrait : .portraitUpsideDown }",
        "if abs(gx) > abs(gy) + margin { return gx < 0 ? .landscapeLeft : .landscapeRight }",
    ):
        assert line in CLASSIFY, line
    assert CLASSIFY.count("return current") == 2


def test_orientations() -> None:
    p = "portrait"
    assert _orientation(0, -1, p) == "portrait"
    assert _orientation(0, 1, p) == "portraitUpsideDown"
    assert _orientation(-1, 0, p) == "landscapeLeft"                    # top edge to the left
    assert _orientation(1, 0, p) == "landscapeRight"
    assert _orientation(-0.7, -0.6, "landscapeLeft") == "landscapeLeft"  # ~45°: no flap
    assert _orientation(-0.7, -0.6, p) == p
    assert _orientation(0.1, 0.1, "landscapeLeft") == "landscapeLeft"    # flat: keep


def test_steep_mounts_still_switch() -> None:
    # Review: a landscape mount tilted back 60–70° toward the rider.
    for tilt in (0, 30, 60, 70):
        gx, gy, _ = _tilted("landscapeLeft", tilt)
        assert _orientation(gx, gy, "portrait") == "landscapeLeft", tilt
        gx, gy, _ = _tilted("portrait", tilt)
        assert _orientation(gx, gy, "landscapeLeft") == "portrait", tilt
    gx, gy, _ = _tilted("landscapeLeft", 80)                            # tank bag
    assert _orientation(gx, gy, "portrait") == "portrait"


def test_a_vibration_spike_does_not_flip() -> None:
    # Idling portrait, one 0.5 s sample with a 1.6 g sideways jolt (on its
    # own it would read as landscape).
    assert _orientation(1.6, -1, "portrait") == "landscapeRight"
    samples = [(0, -1, 0)] * 4 + [(1.6, -1, 0)] + [(0, -1, 0)] * 4
    assert all(_orientation(x, y, "portrait") == "portrait" for x, y, _ in _filtered(samples))
    # A real turn of the phone still lands within a few seconds.
    turned = _filtered([(0, -1, 0)] + [(-1, 0, 0)] * 6)
    assert _orientation(turned[-1][0], turned[-1][1], "portrait") == "landscapeLeft"


def test_swift_filter_matches_the_mirror() -> None:
    assert "let a = 0.2" in APPLY
    assert "gravity.map { (x: $0.x + a * (g.x - $0.x), y: $0.y + a * (g.y - $0.y), z: $0.z + a * (g.z - $0.z)) }" in APPLY
    assert "?? (x: g.x, y: g.y, z: g.z)" in APPLY
    assert APPLY.index("gravity = f") < APPLY.index("Self.headingOrientation(gx: f.x, gy: f.y, current: manager.headingOrientation)")


def test_wired_to_the_heading_updates() -> None:
    start = decl_body(SRC, "private func startUpdates()")
    assert start.index("manager.startUpdatingHeading()") < start.index("startOrientationUpdates()")
    stop = decl_body(SRC, "private func stopUpdates()")
    assert "motion.stopAccelerometerUpdates()" in stop
    # Review: a sideways pocket must not outlast the ride; filter restarts.
    assert "manager.headingOrientation = .portrait" in stop and "gravity = nil" in stop
    body = decl_body(SRC, "private func startOrientationUpdates()")
    assert "guard motion.isAccelerometerAvailable, !motion.isAccelerometerActive else { return }" in body
    assert "MainActor.assumeIsolated { self?.applyGravity(g) }" in body
    assert "manager.headingOrientation = next" in APPLY
