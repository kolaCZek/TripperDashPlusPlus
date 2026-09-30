"""The navigating / free-ride bodies must scroll.

Demo mode stacks the dash preview on top of the HUD; with multi-stop pills
and the Edit route button the column outgrew the screen, and SwiftUI then
overflowed the root VStack both ways — the status banner slid under the
clock and the Stop button fell off the bottom (no way to end the ride).
"""

from pathlib import Path

from tests.swift_source import decl_body, strip_comments

SRC = Path(__file__).resolve().parents[3] / "TripperDashPP/UI/MapPickerView.swift"


def test_ride_bodies_are_scrollable():
    src = strip_comments(SRC.read_text())
    for name, hud in (("navigatingBody", "NavigationHUD("), ("freeRidingBody", "FreeRideHUD(")):
        body = decl_body(src, f"private var {name}: some View")
        scroll = decl_body(body, "ScrollView {")
        assert hud in scroll, f"{name}: the HUD must sit inside the ScrollView"
        # Fill the viewport when it fits, so the HUD panel still reaches the Stop bar.
        assert ".frame(minHeight: geo.size.height" in scroll, name
        assert ".scrollBounceBehavior(.basedOnSize)" in body, name
