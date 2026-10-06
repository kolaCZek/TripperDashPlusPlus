"""
Text overlays on the dash frame sit on a SOLID black backdrop.

At 512 kbps a translucent backdrop lets the moving map show through, so the
encoder re-codes the text block every frame and smears it (rider: "Dense fog"
hard to read). On solid black the block is static between frames and costs
almost nothing. Guard against a well-meant return to a "softer" alpha.
"""
from __future__ import annotations

import pathlib
import re

import pytest

from tests.swift_source import decl_body, strip_comments

SRC = (pathlib.Path(__file__).resolve().parents[3]
       / "TripperDashPP" / "Map" / "MapViewSource.swift").read_text()

FILL = re.compile(r"setFillColor\((?:CGColor\()?red: 0, green: 0, blue: 0, alpha: ([0-9.]+)\)")


@pytest.mark.parametrize("fn", [
    "fileprivate func drawNavOverlay(into ctx: CGContext)",
    "fileprivate func drawWeatherAlert(into ctx: CGContext)",
    "fileprivate func drawNotice(into ctx: CGContext)",
    "fileprivate func drawSpeedSectionPanel(into ctx: CGContext)",
])
def test_text_backdrop_is_solid_black(fn):
    body = strip_comments(decl_body(SRC, fn))
    alphas = FILL.findall(body)
    assert alphas, f"{fn}: black backdrop fill not found"
    assert all(float(a) == 1 for a in alphas), f"{fn}: translucent backdrop {alphas}"
