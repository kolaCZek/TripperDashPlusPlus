"""Guards for the blank-frame diagnostic notice.

A rider hit a permanently blank map on a planned route — ETA and turn
arrow live, map empty. The screenshot could not distinguish "no GPS fix"
from "no route geometry", and a TestFlight *screenshot* report carries no
app logs: verified against two real reports, the screenshot one holds
`feedback.json` plus the image, while `crashlog.crash` ships only with
crashes. So `os.Logger` never reaches us for a non-crashing bug and the
video frame is the only channel back from a rider's bike.

`drawVectorOnlyFrame` now raises a centred `DashNotice` naming the reason,
reusing the existing notice primitive rather than hand-placing text — the
dash panel is circular, so frame corners fall outside the glass and only
the centred card is reliably visible.
"""

from __future__ import annotations

import pathlib

import pytest

from tests.swift_source import decl_body, strip_comments

REPO = pathlib.Path(__file__).resolve().parents[3]
SOURCE = REPO / "TripperDashPP" / "Map" / "MapViewSource.swift"

VECTOR_FRAME = "private func drawVectorOnlyFrame(into ctx: CGContext)"
REPORTER = "private func reportBlankFrameReason()"


@pytest.fixture(scope="module")
def src() -> str:
    return strip_comments(SOURCE.read_text(encoding="utf-8"))


@pytest.fixture(scope="module")
def reporter(src: str) -> str:
    return decl_body(src, REPORTER)


def test_blank_frame_reports_a_reason(src: str):
    body = decl_body(src, VECTOR_FRAME)
    assert "reportBlankFrameReason()" in body, (
        "drawVectorOnlyFrame must report why the frame is blank — a blank "
        "frame with no reason is indistinguishable from a dozen causes in a "
        "screenshot, and screenshot reports carry no logs"
    )


def test_report_happens_in_the_early_return_branch(src: str):
    """Below the guard the frame has content; a notice there is a defect."""
    body = decl_body(src, VECTOR_FRAME)
    guard = body.index("guard let fix = lastFix, !routeDrawCoords.isEmpty else {")
    call = body.index("reportBlankFrameReason()")
    ret = body.index("return", guard)
    assert guard < call < ret, (
        "the reason must be reported inside the guard's else-branch, before "
        "its return — otherwise it fires on frames that do have a map"
    )


@pytest.mark.parametrize(
    "reason",
    ['"No GPS fix or route"', '"No GPS fix"', '"No route to draw"'],
)
def test_each_cause_reads_differently(reporter: str, reason: str):
    """Distinct causes need distinct wording or the notice proves nothing.

    The entire point is telling `lastFix == nil` apart from an empty
    `routeDrawCoords`; one shared string leaves us guessing again.
    """
    assert reason in reporter, f"missing distinct wording for {reason}"


def test_reason_is_derived_from_both_halves_of_the_guard(reporter: str):
    assert "lastFix == nil" in reporter
    assert "routeDrawCoords.isEmpty" in reporter


def test_notice_is_latched_so_it_can_expire(reporter: str):
    """The render loop runs at 6 fps; re-raising every frame never expires.

    `showNotice` stamps a fresh expiry each call, so an unlatched call would
    push the deadline forward ~6 times a second and the card would obstruct
    the dash permanently instead of clearing after its duration.
    """
    assert "guard reason != lastBlankFrameReason else { return }" in reporter, (
        "the notice must be latched on the reason text, or the 6 fps render "
        "loop re-arms it every frame and it never expires"
    )
    assert "lastBlankFrameReason = reason" in reporter, (
        "the latch must be updated after raising the notice"
    )


def test_latch_resets_when_streaming_starts(src: str):
    """Otherwise only the first session of an app launch ever reports."""
    start = decl_body(src, "func start(onFrame: @escaping (CVPixelBuffer, CMTime) -> Void)")
    assert "lastBlankFrameReason = nil" in start, (
        "start() must clear the blank-frame latch so each streaming session "
        "reports afresh"
    )


def test_notice_uses_the_existing_centred_primitive(reporter: str):
    """Centre is the only placement reliably visible on a circular panel.

    Hand-placing text in a frame corner looks right in the phone preview and
    can be off-glass on the bike, silently wasting the diagnostic.
    """
    assert "showNotice(DashNotice(" in reporter, (
        "reuse showNotice/DashNotice — it renders a centred card, which is "
        "what survives the dash's circular panel"
    )
    assert "Self.drawText(" not in reporter, (
        "do not hand-place diagnostic text; frame corners fall outside the "
        "circular dash glass"
    )


def test_notice_is_visible_long_enough_to_photograph(reporter: str):
    """It exists to be screenshotted by a rider who just noticed a problem."""
    assert "duration: 10" in reporter, (
        "the blank-frame notice needs a long duration — the rider has to "
        "notice the blank map and get the phone out to capture it"
    )


def test_notice_is_drawn_after_the_vector_frame(src: str):
    """The notice raised while drawing must reach the SAME frame.

    `drawNotice` is called later in the render pass than
    `drawVectorOnlyFrame`; if that order flipped, the reason would lag a
    frame behind or be missed on a single-frame blank episode.
    """
    vector_call = src.index("drawVectorOnlyFrame(into: ctx)")
    notice_call = src.index("drawNotice(into: ctx)")
    assert vector_call < notice_call, (
        "drawNotice must run after drawVectorOnlyFrame in the render pass so "
        "a notice raised during the blank frame is burned into that frame"
    )
