"""
Regression for the "orphan ETA bubble" field bug (roundabout, 8/2026):
the dash showed a "−2 min" ETA bubble next to the blue route, but NO grey
alternative-route line was drawn under it.

## Mechanism

An alternative route is drawn in two independent passes:

  1. `drawAlternativeLines` — the thin grey line. Guards
     `alt.coords.count > 1` and SKIPS any alt with a degenerate polyline
     (empty or single-point).
  2. `drawAlternativeBubbles` — the "+5 min" / "−2 min" ETA label, drawn
     from a SEPARATE `bubbleAnchor` coordinate that is always valid.

`pushAlternativeRenders` used to `.map` every `MKRoute` into a render,
falling back to `route.polyline.coordinate` for the bubble anchor even
when the coord list was empty. MapKit occasionally hands back a
degenerate alternative near a fork / roundabout (empty or single-point
polyline). That produced a render whose LINE was skipped (count <= 1) but
whose BUBBLE still drew — an orphan "−2 min" floating with no line.

## Fix

- Source (`pushAlternativeRenders`): `.compactMap` + `guard coords.count
  > 1 else { return nil }` — a degenerate alt yields NO render at all, so
  neither line nor bubble.
- Renderer (`drawAlternativeBubbles`): symmetric `guard alt.coords.count
  > 1 else { continue }` — belt-and-braces so a bubble can never orphan
  itself from its line regardless of how the list was built.

This file mirrors the filter, pins the bug/fix, and drift-guards both
Swift guards.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path

from tests.swift_source import decl_body


# --- Mirror of the render model + the two draw passes -----------------------


@dataclass
class AltRender:
    coords: list[int]          # coordinate list (ints model lat/lon points)
    eta_delta_s: float
    bubble_anchor: object      # always non-None in the buggy path


def push_alternative_renders(routes: list[list[int]], active_time: float,
                             travel_times: list[float]) -> list[AltRender]:
    """Mirror of the FIXED `pushAlternativeRenders`: compactMap + drop any
    alt without a drawable (>= 2 point) line. `routes[i]` is alt i's
    coordinate list."""
    out: list[AltRender] = []
    for coords, tt in zip(routes, travel_times):
        if len(coords) <= 1:            # guard coords.count > 1
            continue
        anchor = coords[len(coords) // 2]
        out.append(AltRender(coords=list(coords),
                             eta_delta_s=tt - active_time,
                             bubble_anchor=anchor))
    return out


def draw_alternative_lines(alts: list[AltRender]) -> list[int]:
    """Mirror of `drawAlternativeLines`: returns the indices whose line is
    actually stroked (count > 1)."""
    return [i for i, a in enumerate(alts) if len(a.coords) > 1]


def draw_alternative_bubbles(alts: list[AltRender]) -> list[int]:
    """Mirror of the FIXED `drawAlternativeBubbles`: same `count > 1` guard
    as the line pass, so bubbles and lines are always drawn for the exact
    same set."""
    return [i for i, a in enumerate(alts) if len(a.coords) > 1]


# --- The bug + the fix ------------------------------------------------------


def test_degenerate_alt_yields_no_render_at_source():
    """A single-point / empty alt must produce NO render — so it can't
    orphan a bubble downstream."""
    routes = [[1, 2, 3, 4], [], [7]]        # alt 1 empty, alt 2 single-point
    renders = push_alternative_renders(routes, active_time=600,
                                       travel_times=[540, 500, 500])
    assert len(renders) == 1
    assert renders[0].coords == [1, 2, 3, 4]


def test_bubbles_and_lines_drawn_for_identical_set():
    """The whole invariant: every bubble has a line and every line has a
    bubble. No orphans in either direction."""
    routes = [[1, 2, 3], [], [10, 11, 12, 13], [99]]
    renders = push_alternative_renders(routes, active_time=600,
                                       travel_times=[500, 500, 700, 500])
    lines = draw_alternative_lines(renders)
    bubbles = draw_alternative_bubbles(renders)
    assert lines == bubbles, "a bubble without a line (or vice versa) — orphan bug"


def test_bubble_guard_catches_degenerate_even_if_source_filter_bypassed():
    """Belt-and-braces: if a degenerate render reaches the renderer anyway
    (built some other way), the bubble pass must still skip it so it can't
    orphan."""
    # Hand-build a render list that includes a degenerate alt (as if the
    # source filter were bypassed).
    renders = [
        AltRender(coords=[1, 2, 3], eta_delta_s=-120, bubble_anchor=2),
        AltRender(coords=[9], eta_delta_s=-120, bubble_anchor=9),   # degenerate
    ]
    lines = draw_alternative_lines(renders)
    bubbles = draw_alternative_bubbles(renders)
    assert lines == [0]
    assert bubbles == [0], "degenerate alt still drew a bubble — orphan bug"


def test_normal_alternatives_all_render():
    routes = [[1, 2, 3], [4, 5, 6, 7]]
    renders = push_alternative_renders(routes, active_time=600,
                                       travel_times=[480, 660])
    assert len(renders) == 2
    assert draw_alternative_lines(renders) == [0, 1]
    assert draw_alternative_bubbles(renders) == [0, 1]


# --- Swift-source drift guards ----------------------------------------------


def _repo_root() -> Path:
    return Path(__file__).resolve().parents[3]


def test_swift_push_alternative_renders_filters_degenerate():
    src = (_repo_root() / "TripperDashPP" / "UI" / "MapPickerView.swift").read_text("utf-8")
    body = decl_body(src, "func pushAlternativeRenders")
    assert "compactMap" in body, (
        "pushAlternativeRenders no longer compactMaps — a degenerate alt "
        "will produce an orphan ETA bubble with no line again"
    )
    assert "coords.count > 1" in body, (
        "the drawable-line guard is gone from pushAlternativeRenders"
    )
    # The empty-coords bubble-anchor fallback must NOT come back — that was
    # exactly what let a lineless alt keep its bubble. (Match the ternary
    # fallback specifically, not the `.coordinateList()` call.)
    assert "? route.polyline.coordinate" not in body, (
        "empty-coords bubble-anchor fallback is back — a lineless alt can "
        "orphan a bubble again"
    )


def test_swift_bubble_pass_has_symmetric_guard():
    src = (_repo_root() / "TripperDashPP" / "Map" / "MapViewSource.swift").read_text("utf-8")
    body = decl_body(src, "func drawAlternativeBubbles")
    assert "alt.coords.count > 1" in body, (
        "drawAlternativeBubbles lost its symmetric count > 1 guard — a "
        "degenerate alt could orphan a bubble from its line again"
    )
