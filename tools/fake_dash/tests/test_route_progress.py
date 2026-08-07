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


EDITABLE_LIST_THRESHOLD = 20  # RoutePoint.editableListThreshold


def waypoint_fractions(leg_distances: list[float]) -> list[float]:
    """Mirror of the waypoint-tick capture in `ActiveNavigator.start(plan:)`.

    Given the selected distance of every remaining leg, return the 0…1 bar
    position of each intermediate pass-through waypoint — the cumulative
    length up to each leg boundary EXCEPT the last (the final destination
    is the bar's end, not a tick). Empty for a single leg or zero total,
    and suppressed entirely for a dense plan (via-point count above the
    planner's editable-list threshold) so a recorded track doesn't smear
    the bar into an unreadable comb.
    """
    total = sum(leg_distances)
    via_count = len(leg_distances) - 1
    if total <= 0 or via_count < 1 or via_count > EDITABLE_LIST_THRESHOLD:
        return []
    fractions: list[float] = []
    cumulative = 0.0
    for dist in leg_distances[:-1]:
        cumulative += dist
        fractions.append(cumulative / total)
    return fractions


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
# Waypoint tick positions
# --------------------------------------------------------------------------


class TestWaypointFractions:
    def test_single_leg_no_ticks(self):
        # A direct route (one leg) has no intermediate via-points.
        assert waypoint_fractions([10_000]) == []

    def test_two_legs_one_tick_at_midpoint(self):
        # Two equal legs → one via-point at the halfway mark.
        assert waypoint_fractions([5_000, 5_000]) == pytest.approx([0.5])

    def test_three_uneven_legs(self):
        # Ticks at each boundary before the final destination.
        got = waypoint_fractions([2_000, 3_000, 5_000])
        assert got == pytest.approx([0.2, 0.5])

    def test_final_destination_not_a_tick(self):
        # The last boundary (fraction 1.0) is the bar's end, never emitted.
        got = waypoint_fractions([1_000, 1_000, 1_000])
        assert 1.0 not in got
        assert got == pytest.approx([1 / 3, 2 / 3])

    def test_zero_total_no_ticks(self):
        assert waypoint_fractions([0, 0]) == []

    def test_at_threshold_still_drawn(self):
        # Exactly threshold via-points (threshold+1 legs) → still drawn.
        legs = [1_000.0] * (EDITABLE_LIST_THRESHOLD + 1)
        got = waypoint_fractions(legs)
        assert len(got) == EDITABLE_LIST_THRESHOLD

    def test_above_threshold_suppressed(self):
        # One past the threshold (a dense track) → no ticks at all.
        legs = [1_000.0] * (EDITABLE_LIST_THRESHOLD + 2)
        assert waypoint_fractions(legs) == []

    def test_dense_track_suppressed(self):
        # A recorded track staged for nav (hundreds of points) → empty.
        legs = [100.0] * 500
        assert waypoint_fractions(legs) == []


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

    def test_waypoint_ticks_gated_on_editable_threshold(self):
        # The waypoint ticks must reuse the SAME density cutoff the planner
        # uses for its editable stop list, so a dense imported track shows
        # no ticks (they'd smear into a comb).
        src = _swift_navigator_source()
        assert "plannedWaypointFractions" in src
        assert "RoutePoint.editableListThreshold" in src


# --------------------------------------------------------------------------
# Weather-hazard band position on the bar
# --------------------------------------------------------------------------


def hazard_fraction(ride_fraction: float, distance_ahead: float,
                    planned_total: float) -> float | None:
    """Mirror of the hazard-fraction calc in `ActiveNavLoop` block 2a.

    The rider is at `ride_fraction` of the trip; a located hazard sits
    `distance_ahead` metres further along the route, so its trip fraction
    is current + ahead/total, clamped to 0…1. Returns None when there's no
    positive planned total (can't place it) — the caller also gates on the
    hazard actually having an ahead-distance.
    """
    if planned_total <= 0:
        return None
    return max(0.0, min(1.0, ride_fraction + distance_ahead / planned_total))


class TestHazardFraction:
    def test_hazard_ahead_of_rider(self):
        # 20% done on a 100 km trip, rain 15 km ahead → 0.20 + 0.15 = 0.35.
        assert hazard_fraction(0.20, 15_000, 100_000) == pytest.approx(0.35)

    def test_hazard_at_rider(self):
        # distance_ahead 0 → band sits exactly at the current position.
        assert hazard_fraction(0.40, 0, 100_000) == pytest.approx(0.40)

    def test_hazard_clamped_to_end(self):
        # Hazard further than the remaining trip → clamp to the bar's end.
        assert hazard_fraction(0.90, 50_000, 100_000) == 1.0

    def test_no_planned_total_returns_none(self):
        assert hazard_fraction(0.5, 10_000, 0) is None


# --------------------------------------------------------------------------
# Drift guard — the renderer + nav pump must still match this behaviour
# --------------------------------------------------------------------------


def _swift_mapviewsource() -> str:
    here = Path(__file__).resolve()
    repo_root = here.parents[3]
    src = repo_root / "TripperDashPP" / "Map" / "MapViewSource.swift"
    return src.read_text(encoding="utf-8")


def _swift_navloop() -> str:
    here = Path(__file__).resolve()
    repo_root = here.parents[3]
    src = repo_root / "TripperDashPP" / "Navigation" / "ActiveNavLoop.swift"
    return src.read_text(encoding="utf-8")


class TestProgressBarRenderDriftGuard:
    def test_bar_left_inset_clears_maneuver_glyph(self):
        # The bar must be laid out with an explicit LEFT inset (not a bare
        # centred fraction) so its start clears the dash's own maneuver
        # glyph in the top-left. Regression for the "left end hidden under
        # the turn card" rider photo (8/2026).
        src = _swift_mapviewsource()
        assert "progressBarLeftInset" in src
        assert "progressBarRightInset" in src

    def test_waypoint_ticks_are_bright_and_overhang(self):
        # Ticks must be the bright white-core + dark-outline overhang marker,
        # not the old 1.5 px dark hairline that was invisible.
        src = _swift_mapviewsource()
        idx = src.index("func drawProgressBar")
        body = src[idx:idx + 6000]
        assert "tickOverhang" in body
        # The old invisible hairline width must be gone.
        assert "let tickW: CGFloat = 1.5" not in body

    def test_hazard_band_drawn(self):
        # The renderer must draw a hazard band when hazardFraction is set.
        src = _swift_mapviewsource()
        assert "hazardFraction" in src
        assert "hazardIsWarning" in src

    def test_navloop_computes_hazard_fraction(self):
        # The nav pump must translate the weather alert's along-route
        # distance into a bar fraction using the planned total.
        src = _swift_navloop()
        assert "hazardFraction" in src
        assert "distanceAhead" in src
        assert "plannedTotalDistance" in src
