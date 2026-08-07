"""
Tests for the adaptive weather-sampling spacing and the contiguous
hazard-span picker (feat, Martin 8/2026).

Two pure cores mirrored from `WeatherAlertService.swift`:

1. `adaptiveSpacing(routeLengthMeters:)` — the along-route sample spacing
   scales with route length so a short ride samples finely (down to 1 km)
   and a long ride stays coarse (up to 10 km), targeting a roughly
   constant point count that never overruns Open-Meteo's single-GET
   budget.  spacing = clamp(min(len, range) / target, minSpacing, maxSpacing)

2. `pickAlongRoute` span walk — the surfaced hazard now carries the
   near/far edge of the CONTIGUOUS run of same-glyph samples it belongs
   to, so the progress bar can paint the whole stretch (rain 15→40 km)
   instead of a single point.

Drift guards assert the Swift source still matches these cores.
"""

from __future__ import annotations

from pathlib import Path
from typing import Optional, Sequence

import pytest


# --------------------------------------------------------------------------
# Mirror: adaptive spacing
# --------------------------------------------------------------------------

SAMPLE_RANGE_M = 100_000.0
SAMPLE_TARGET_COUNT = 20.0
SAMPLE_MIN_SPACING_M = 1_000.0
SAMPLE_MAX_SPACING_M = 10_000.0


def adaptive_spacing(route_length_m: float) -> float:
    """Mirror of `WeatherAlertService.adaptiveSpacing`."""
    if route_length_m <= 0:
        return SAMPLE_MAX_SPACING_M
    raw = route_length_m / SAMPLE_TARGET_COUNT
    return min(max(raw, SAMPLE_MIN_SPACING_M), SAMPLE_MAX_SPACING_M)


class TestAdaptiveSpacing:
    def test_short_ride_uses_min_spacing(self):
        # 20 km / 20 = 1 km → the floor exactly.
        assert adaptive_spacing(20_000) == 1_000

    def test_tiny_ride_floored(self):
        # 5 km / 20 = 250 m → floored to 1 km.
        assert adaptive_spacing(5_000) == 1_000

    def test_medium_ride_scales(self):
        # 80 km / 20 = 4 km, within the band → used as-is.
        assert adaptive_spacing(80_000) == 4_000

    def test_long_ride_hits_max_spacing(self):
        # 200 km / 20 = 10 km → the ceiling exactly.
        assert adaptive_spacing(200_000) == 10_000

    def test_very_long_saturates_ceiling(self):
        # 1000 km / 20 = 50 km → clamped down to the 10 km ceiling.
        assert adaptive_spacing(1_000_000) == 10_000

    def test_zero_length_falls_back_to_max(self):
        assert adaptive_spacing(0) == SAMPLE_MAX_SPACING_M

    def test_negative_length_falls_back_to_max(self):
        assert adaptive_spacing(-100) == SAMPLE_MAX_SPACING_M

    def test_point_budget_never_exceeded(self):
        # For any route length the resulting point count over the SAMPLED
        # span (min(len, range) / spacing) must stay under Open-Meteo's
        # ~100-point single-GET budget.
        for length in (1_000, 20_000, 80_000, 100_000, 500_000, 2_000_000):
            spacing = adaptive_spacing(length)
            sampled_span = min(length, SAMPLE_RANGE_M)
            points = sampled_span / spacing
            assert points <= 100, (length, spacing, points)


# --------------------------------------------------------------------------
# Mirror: contiguous hazard-span walk
# --------------------------------------------------------------------------


def pick_span(glyphs: Sequence[Optional[str]], dists: Sequence[float]):
    """Mirror of the span walk in `WeatherAlertService.pickAlongRoute`.

    `glyphs[i]` is the classified hazard glyph at sample i, or None for a
    clear sample. `dists[i]` is that sample's along-route distance. Picks
    the nearest highest-severity hazard as "best" is out of scope here — we
    feed the caller the index directly via the simplest policy: nearest
    non-clear sample (all same severity in these cases). Returns
    (start, end) of the contiguous same-glyph run, or (None, None) for a
    lone/at-rider hazard.
    """
    # Nearest non-clear ahead sample (dist > 0) is "best".
    best_idx = None
    for i, g in enumerate(glyphs):
        if g is not None and dists[i] > 0:
            best_idx = i
            break
    if best_idx is None:
        return (None, None)
    best_glyph = glyphs[best_idx]
    lo = hi = best_idx
    while lo - 1 >= 0 and glyphs[lo - 1] == best_glyph:
        lo -= 1
    while hi + 1 < len(glyphs) and glyphs[hi + 1] == best_glyph:
        hi += 1
    if hi > lo:
        return (dists[lo], dists[hi])
    return (None, None)


class TestHazardSpan:
    def test_contiguous_run_becomes_span(self):
        # rain at 15, 25, 35 km → span 15…35.
        glyphs = [None, "rain", "rain", "rain", None]
        dists = [0, 15_000, 25_000, 35_000, 45_000]
        assert pick_span(glyphs, dists) == (15_000, 35_000)

    def test_lone_hazard_no_span(self):
        # A single rain sample surrounded by clears → point, not a span.
        glyphs = [None, "rain", None]
        dists = [0, 20_000, 40_000]
        assert pick_span(glyphs, dists) == (None, None)

    def test_clear_breaks_the_run(self):
        # rain, clear, rain → the near run is a lone point (no span).
        glyphs = [None, "rain", None, "rain", "rain"]
        dists = [0, 10_000, 20_000, 30_000, 40_000]
        # Nearest is idx1 (lone) → no span.
        assert pick_span(glyphs, dists) == (None, None)

    def test_different_glyph_breaks_the_run(self):
        # rain, rain, storm → span covers only the rain run.
        glyphs = [None, "rain", "rain", "storm"]
        dists = [0, 10_000, 20_000, 30_000]
        assert pick_span(glyphs, dists) == (10_000, 20_000)


# --------------------------------------------------------------------------
# Drift guards — Swift source must still match these cores
# --------------------------------------------------------------------------


def _weather_src() -> str:
    here = Path(__file__).resolve()
    repo_root = here.parents[3]
    src = repo_root / "TripperDashPP" / "RideAlerts" / "WeatherAlertService.swift"
    return src.read_text(encoding="utf-8")


def _navloop_src() -> str:
    here = Path(__file__).resolve()
    repo_root = here.parents[3]
    src = repo_root / "TripperDashPP" / "Navigation" / "ActiveNavLoop.swift"
    return src.read_text(encoding="utf-8")


def _mapview_src() -> str:
    here = Path(__file__).resolve()
    repo_root = here.parents[3]
    src = repo_root / "TripperDashPP" / "Map" / "MapViewSource.swift"
    return src.read_text(encoding="utf-8")


class TestSwiftDriftGuard:
    def test_adaptive_spacing_exists(self):
        src = _weather_src()
        assert "func adaptiveSpacing" in src
        assert "sampleTargetCount" in src
        assert "sampleMinSpacingMeters" in src
        assert "sampleMaxSpacingMeters" in src
        # The old fixed-spacing constant must be gone.
        assert "sampleSpacingMeters" not in src

    def test_refresh_uses_adaptive_spacing(self):
        src = _weather_src()
        assert "adaptiveSpacing(routeLengthMeters:" in src
        assert "polylineLength(" in src

    def test_alert_carries_span(self):
        src = _weather_src()
        assert "spanStartMeters" in src
        assert "spanEndMeters" in src

    def test_navloop_maps_span_to_fractions(self):
        src = _navloop_src()
        assert "hazardStartFraction" in src
        assert "hazardEndFraction" in src
        assert "spanStartMeters" in src

    def test_renderer_paints_span(self):
        src = _mapview_src()
        assert "hazardStartFraction" in src
        assert "hazardEndFraction" in src
