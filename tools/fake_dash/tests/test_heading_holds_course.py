"""
Below ~11 km/h the dash map holds the last GPS course instead of the
compass (issue #225, reported by renansalenave).

The compass (`CLHeading.trueHeading`) follows the phone's top edge, so a
phone turned in its mount turned the map and the arrow on the dash at a
light or in slow traffic. The bike doesn't turn while stopped: hold the
last moving course. The compass is only the fallback before the first
moving fix of a stream, and the held course is dropped on stop.
"""
from __future__ import annotations

from pathlib import Path

from tests.swift_source import decl_body, strip_comments

SRC = strip_comments((Path(__file__).resolve().parents[3] / "TripperDashPP/Map/MapViewSource.swift")
                     .read_text(encoding="utf-8"))
BODY = decl_body(SRC, "private func recomputeHeading()")


def test_course_then_held_course_then_compass() -> None:
    course = BODY.index("newTarget = fix.course")
    held = BODY.index("} else if let lastMovingCourse {")
    compass = BODY.index("} else if lastCompassValid {")
    assert course < BODY.index("lastMovingCourse = fix.course") < held < compass
    assert "newTarget = lastMovingCourse" in BODY[held:compass]
    assert "newTarget = lastCompassHeading" in BODY[compass:]


def test_held_course_is_dropped_on_stop() -> None:
    assert "lastMovingCourse = nil" in decl_body(SRC, "func stop()")
