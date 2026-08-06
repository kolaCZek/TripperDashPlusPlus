"""
Tests for the route progress bar's two pure decision cores
(`ActiveNavigator.rideProgressFraction` and
`ActiveNavigator.trafficDelayLevel`).

Feature (feat/route-progress-bar, Martin 8/2026): a thin bar on the
bottom edge of the streamed map showing how far along the route the rider
is, plus a COARSE "road ahead" traffic tint.

Two independently-testable pure cores are mirrored here:

  1. Progress fraction = (plannedTotal - remaining) / plannedTotal,
     clamped to 0…1, 0 when the denominator is non-positive.

  2. Traffic delay level — the HONEST Apple-only signal. It is a SINGLE
     coarse level for the whole road ahead (NOT per-segment flow: Apple
     `MKDirections` returns only a scalar `expectedTravelTime`, no
     geometry-resolved flow). It compares the live remaining ETA against
     how long the remaining distance WOULD take at the trip's baseline
     pace (planned distance ÷ planned time captured at start):

        ratio = liveEta / (remainingDistance / baselineSpeed)

        ratio >= 1.40  → heavy    (red)
        ratio >= 1.15  → moderate (amber)
        else           → clear    (green)

     Degenerate inputs (no baseline yet, ~arrived, non-finite ETA) →
     `unknown` (neutral grey), so the bar never makes a false green/red
     claim.

These mirror the Swift implementation in `ActiveNavigator.swift` and a
drift guard asserts the Swift thresholds still match.
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest


# --------------------------------------------------------------------------
# Python mirror of the Swift pure cores
# --------------------------------------------------------------------------

# Thresholds — kept in sync with the Swift source (drift-guarded below).
HEAVY_RATIO = 1.40
MODERATE_RATIO = 1.15
ARRIVED_DISTANCE_FLOOR = 50.0  # metres; below this the gauge is noise


def ride_progress_fraction(planned_total: float, remaining: float) -> float:
    """Mirror of `ActiveNavigator.rideProgressFraction`."""
    if planned_total <= 0:
        return 0.0
    done = planned_total - remaining
    return max(0.0, min(1.0, done / planned_total))


def traffic_delay_level(
    baseline_speed: float, remaining_distance: float, live_eta_seconds: float
) -> str:
    """Mirror of `ActiveNavigator.trafficDelayLevel(baselineSpeed:...)`."""
    if not (
        baseline_speed > 0
        and remaining_distance > ARRIVED_DISTANCE_FLOOR
        and _is_finite(live_eta_seconds)
        and live_eta_seconds > 0
    ):
        return "unknown"
    free_flow = remaining_distance / baseline_speed
    if free_flow <= 0:
        return "unknown"
    ratio = live_eta_seconds / free_flow
    if ratio >= HEAVY_RATIO:
        return "heavy"
    if ratio >= MODERATE_RATIO:
        return "moderate"
    return "clear"


def _is_finite(x: float) -> bool:
    return x == x and x not in (float("inf"), float("-inf"))


# --------------------------------------------------------------------------
# Progress fraction
# --------------------------------------------------------------------------


class TestProgressFraction:
    def test_zero_at_start(self):
        assert ride_progress_fraction(10_000, 10_000) == 0.0

    def test_half_way(self):
        assert ride_progress_fraction(10_000, 5_000) == pytest.approx(0.5)

    def test_arrived(self):
        assert ride_progress_fraction(10_000, 0) == 1.0

    def test_clamped_below_zero(self):
        # remaining somehow exceeds planned (fresh reroute lengthened it) →
        # clamp to 0, never negative.
        assert ride_progress_fraction(10_000, 12_000) == 0.0

    def test_clamped_above_one(self):
        # remaining negative (overshoot noise) → clamp to 1.
        assert ride_progress_fraction(10_000, -500) == 1.0

    def test_zero_denominator_returns_zero(self):
        assert ride_progress_fraction(0, 0) == 0.0

    def test_negative_denominator_returns_zero(self):
        assert ride_progress_fraction(-1, 100) == 0.0


# --------------------------------------------------------------------------
# Traffic delay level
# --------------------------------------------------------------------------


class TestTrafficDelayLevel:
    # baseline_speed = 20 m/s (72 km/h). remaining = 20_000 m →
    # free-flow time = 1000 s.
    BASE = 20.0
    REMAIN = 20_000.0

    def test_clear_when_on_pace(self):
        # live ETA == free-flow → ratio 1.0 → clear.
        assert traffic_delay_level(self.BASE, self.REMAIN, 1000) == "clear"

    def test_clear_just_below_moderate(self):
        # ratio 1.14 → still clear.
        assert traffic_delay_level(self.BASE, self.REMAIN, 1140) == "clear"

    def test_moderate_at_threshold(self):
        # ratio exactly 1.15 → moderate.
        assert traffic_delay_level(self.BASE, self.REMAIN, 1150) == "moderate"

    def test_moderate_just_below_heavy(self):
        # ratio 1.39 → moderate.
        assert traffic_delay_level(self.BASE, self.REMAIN, 1390) == "moderate"

    def test_heavy_at_threshold(self):
        # ratio exactly 1.40 → heavy.
        assert traffic_delay_level(self.BASE, self.REMAIN, 1400) == "heavy"

    def test_heavy_well_over(self):
        # ratio 2.0 (jam) → heavy.
        assert traffic_delay_level(self.BASE, self.REMAIN, 2000) == "heavy"

    def test_faster_than_baseline_is_clear(self):
        # live ETA below free-flow (road cleared) → ratio < 1 → clear,
        # never a bogus "unknown".
        assert traffic_delay_level(self.BASE, self.REMAIN, 800) == "clear"

    def test_unknown_without_baseline(self):
        assert traffic_delay_level(0, self.REMAIN, 1000) == "unknown"

    def test_unknown_when_essentially_arrived(self):
        # remaining below the arrived floor → gauge is noise → unknown.
        assert traffic_delay_level(self.BASE, 40, 100) == "unknown"

    def test_unknown_on_nonpositive_eta(self):
        assert traffic_delay_level(self.BASE, self.REMAIN, 0) == "unknown"

    def test_unknown_on_infinite_eta(self):
        assert traffic_delay_level(self.BASE, self.REMAIN, float("inf")) == "unknown"

    def test_unknown_on_nan_eta(self):
        assert traffic_delay_level(self.BASE, self.REMAIN, float("nan")) == "unknown"


# --------------------------------------------------------------------------
# Drift guard — the Swift source must still match these thresholds
# --------------------------------------------------------------------------


def _swift_navigator_source() -> str:
    here = Path(__file__).resolve()
    repo_root = here.parents[3]
    src = repo_root / "TripperDashPP" / "Navigation" / "ActiveNavigator.swift"
    return src.read_text(encoding="utf-8")


class TestSwiftDriftGuard:
    def test_thresholds_match_swift(self):
        src = _swift_navigator_source()
        assert "ratio >= 1.40 { return .heavy }" in src, "heavy threshold drifted"
        assert "ratio >= 1.15 { return .moderate }" in src, "moderate threshold drifted"

    def test_arrived_floor_matches_swift(self):
        src = _swift_navigator_source()
        assert "remainingDistance > 50" in src, "arrived-floor (50 m) drifted"

    def test_delay_level_enum_present(self):
        src = _swift_navigator_source()
        for case in ("case unknown", "case clear", "case moderate", "case heavy"):
            assert case in src, f"TrafficDelayLevel.{case} missing"

    def test_fraction_uses_final_destination_remaining(self):
        # The fraction must be measured against the whole-trip remaining
        # distance the HUD counts down (not the current-leg remaining), so
        # bar and readout can't disagree.
        src = _swift_navigator_source()
        assert "finalDestinationRemainingDistance" in src
        assert "plannedTotalDistance" in src
