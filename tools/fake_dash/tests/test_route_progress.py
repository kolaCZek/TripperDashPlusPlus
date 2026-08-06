"""
Tests for the route progress bar's pure decision core
(`ActiveNavigator.rideProgressFraction`).

Feature (feat/route-progress-bar, Martin 8/2026): a thin bar centred on
the bottom edge of the streamed map (75% of the dash width) showing how
far along the route the rider is — grey behind (done), blue ahead
(remaining), a red right-pointing chevron marking the current position.

There is deliberately NO traffic tint: Apple `MKDirections` returns only
a scalar `expectedTravelTime`, no per-segment flow, so the bar makes no
green/amber/red claim. True per-section colouring waits on a BYOK
live-traffic provider (routing-engines.md). The only pure core left to
pin is the progress fraction.

  fraction = (plannedTotal - remaining) / plannedTotal,
             clamped to 0…1, 0 when the denominator is non-positive.

This mirrors the Swift implementation in `ActiveNavigator.swift` and a
drift guard asserts the Swift core still matches.
"""

from __future__ import annotations

from pathlib import Path

import pytest


# --------------------------------------------------------------------------
# Python mirror of the Swift pure core
# --------------------------------------------------------------------------


def ride_progress_fraction(planned_total: float, remaining: float) -> float:
    """Mirror of `ActiveNavigator.rideProgressFraction`."""
    if planned_total <= 0:
        return 0.0
    done = planned_total - remaining
    return max(0.0, min(1.0, done / planned_total))


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
# Drift guard — the Swift source must still match this core
# --------------------------------------------------------------------------


def _swift_navigator_source() -> str:
    here = Path(__file__).resolve()
    repo_root = here.parents[3]
    src = repo_root / "TripperDashPP" / "Navigation" / "ActiveNavigator.swift"
    return src.read_text(encoding="utf-8")


class TestSwiftDriftGuard:
    def test_fraction_uses_final_destination_remaining(self):
        # The fraction must be measured against the whole-trip remaining
        # distance the HUD counts down (not the current-leg remaining), so
        # bar and readout can't disagree.
        src = _swift_navigator_source()
        assert "finalDestinationRemainingDistance" in src
        assert "plannedTotalDistance" in src

    def test_no_traffic_delay_core_remains(self):
        # The coarse traffic-delay tint was dropped (no honest per-segment
        # source). Guard against it silently creeping back in a half-wired
        # state — the bar is progress-only now.
        src = _swift_navigator_source()
        assert "TrafficDelayLevel" not in src
        assert "trafficDelayLevel" not in src
