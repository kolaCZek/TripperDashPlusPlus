"""
Tests for the planning-cancel lifecycle — the "Invalid Number Of Items In
Section" crash reported from TestFlight on 1.0.3.

CRASH REPORT (Ari, 2026-09-06, iPhone 14,7 / iOS 26.6.1, build 1.0.3 (1)):

    "První pád aplikace, při pokusu odejít z možnosti trasy a vytvořit
     nový cíl"
    ("first crash, trying to leave the route options and create a new
     destination")

    EXC_CRASH (SIGABRT), uptime 5 s, thread 0:
      -[UICollectionView _Bug_Detected_In_Client_Of_UICollectionView_
        Invalid_Number_Of_Items_In_Section:]
      UICollectionViewListCoordinatorBase.performUpdates(...)   <- SwiftUI List

TWO INDEPENDENT DEFECTS FEED IT.

(1) ORPHANED RECOMPUTE. `AppStatus.recomputeDirtyLegs(_:in:)` captures the
    `PlannedRoute` strongly, and `RoutingService.recompute` mutates it via
    `plan.setOptions(...)` AFTER each `await calculateLeg(...)` — roughly a
    1 s network round trip per leg. `cancelPlanning()` only does
    `plannedRoute = nil`; it cancels nothing. So the in-flight task resumes
    and writes into a plan that is detached from `AppStatus` but still
    `@Observable` and still carrying the SwiftUI observers registered by the
    Stops `List`. The late write pushes an observation change into a
    collection view SwiftUI has already started tearing down.

(2) STICKY SHEET FLAGS. `addingStopToPlan` / `slotToFill` are armed BEFORE
    the search sheet opens and were cleared ONLY inside
    `handlePickedDestination` — i.e. only when the rider actually picked
    something. Swiping the sheet away left them armed, so the NEXT search
    (the plain pill) was still routed as "add a stop to the current plan".
    Picking a destination then inserted a via-point instead of creating a
    new destination — changing `plan.waypoints.count`, which drives BOTH
    the Stops list's row count AND, at `RoutePoint.editableListThreshold`,
    whether the list exists at all. That is exactly Ari's wording: leaving
    the route options, then creating a new destination.

The fixes: identity guards (`plannedRoute === plan`) before and after every
suspension point, an `isStillLive` callback threaded into the per-leg loop
so writes stop at the source, and an `onDismiss` that disarms the one-shot
sheet flags.

This file mirrors the lifecycle rules in Python and pins the Swift source.
"""

from __future__ import annotations

from pathlib import Path

from tests.swift_source import decl_body, strip_comments


REPO = Path(__file__).resolve().parents[3]
APPSTATUS = REPO / "TripperDashPP" / "App" / "AppStatus.swift"
ROUTING = REPO / "TripperDashPP" / "Navigation" / "RoutingService.swift"
PICKER = REPO / "TripperDashPP" / "UI" / "MapPickerView.swift"


# --------------------------------------------------------------------------
# Python mirror of the recompute lifecycle.
# --------------------------------------------------------------------------

class FakePlan:
    """Stand-in for the @Observable PlannedRoute."""

    def __init__(self, waypoints: int) -> None:
        self.waypoints = waypoints
        self.writes: list[int] = []      # leg indices written back

    def set_options(self, leg_index: int) -> None:
        self.writes.append(leg_index)


class FakeStatus:
    """Mirror of AppStatus's plan lifecycle, including the identity guard."""

    def __init__(self) -> None:
        self.planned_route: FakePlan | None = None
        self.plan_error: str | None = None

    def begin_planning(self, waypoints: int) -> FakePlan:
        plan = FakePlan(waypoints)
        self.planned_route = plan
        return plan

    def cancel_planning(self) -> None:
        self.planned_route = None

    def recompute(self, plan: FakePlan, legs: list[int],
                  cancel_before_leg: int | None = None) -> None:
        """Mirror of recomputeDirtyLegs + RoutingService.recompute.

        `cancel_before_leg` simulates the rider tapping Cancel while the
        network call for that leg index is in flight.
        """
        if self.planned_route is not plan:            # entry guard
            return
        for i in legs:
            if self.planned_route is not plan:        # per-leg guard
                return
            if cancel_before_leg == i:                # await suspends here
                self.cancel_planning()
            if self.planned_route is not plan:        # post-await guard
                return
            plan.set_options(i)
        if self.planned_route is not plan:
            return
        self.plan_error = None


class TestRecomputeLifecycle:

    def test_cancel_mid_recompute_stops_writing_into_the_plan(self) -> None:
        """The crash's core: a cancelled plan must receive no further writes."""
        st = FakeStatus()
        plan = st.begin_planning(waypoints=5)
        st.recompute(plan, [0, 1, 2, 3], cancel_before_leg=2)

        assert plan.writes == [0, 1], (
            f"writes continued after cancel: {plan.writes} — a detached "
            "@Observable plan was mutated while SwiftUI tore down its List"
        )

    def test_uncancelled_recompute_still_writes_every_leg(self) -> None:
        """Regression guard: the happy path must be untouched."""
        st = FakeStatus()
        plan = st.begin_planning(waypoints=5)
        st.recompute(plan, [0, 1, 2, 3])
        assert plan.writes == [0, 1, 2, 3]
        assert st.plan_error is None

    def test_a_stale_plan_never_starts_recomputing(self) -> None:
        """Entry guard: a task queued for an already-replaced plan is a no-op."""
        st = FakeStatus()
        stale = st.begin_planning(waypoints=3)
        st.begin_planning(waypoints=7)      # rider started a different plan
        st.recompute(stale, [0, 1])
        assert stale.writes == []

    def test_starting_a_new_plan_mid_recompute_abandons_the_old_one(self) -> None:
        """Not just cancel — swapping plans must also stop the old writes."""
        st = FakeStatus()
        old = st.begin_planning(waypoints=4)

        def swap_then_continue() -> None:
            st.begin_planning(waypoints=9)

        # Leg 0 lands, then the rider stages a different route.
        if st.planned_route is old:
            old.set_options(0)
        swap_then_continue()
        # Remaining legs must not be written.
        for i in (1, 2):
            if st.planned_route is not old:
                break
            old.set_options(i)

        assert old.writes == [0]

    def test_plan_error_is_not_published_onto_a_dead_plan(self) -> None:
        """`planError` feeds the planning UI; writing it after teardown is
        the same class of late mutation as the leg write itself."""
        st = FakeStatus()
        plan = st.begin_planning(waypoints=3)
        st.plan_error = "previous error"
        st.recompute(plan, [0, 1], cancel_before_leg=0)
        assert st.plan_error == "previous error", (
            "planError was republished after the plan was cancelled"
        )


# --------------------------------------------------------------------------
# Sticky sheet flags (defect 2).
# --------------------------------------------------------------------------

class SheetFlags:
    """Mirror of MapPickerView's one-shot search-routing flags."""

    def __init__(self) -> None:
        self.adding_stop_to_plan = False
        self.slot_to_fill: str | None = None
        self.shared_search_seed: str | None = None

    def open_search_to_add_stop(self) -> None:
        self.adding_stop_to_plan = True

    def open_search_plain(self) -> None:
        pass

    def dismiss(self) -> None:
        """The new onDismiss — disarms every one-shot flag."""
        self.adding_stop_to_plan = False
        self.slot_to_fill = None
        self.shared_search_seed = None

    def route_pick(self) -> str:
        if self.slot_to_fill is not None:
            return "quick-slot"
        if self.adding_stop_to_plan:
            return "insert-via-point"
        return "new-destination"


class TestSheetFlagLifecycle:

    def test_swiping_the_sheet_away_disarms_add_stop(self) -> None:
        """Ari's path: open 'add stop', back out, then search a new target."""
        f = SheetFlags()
        f.open_search_to_add_stop()
        f.dismiss()                     # rider swipes the sheet away
        f.open_search_plain()           # taps the plain search pill
        assert f.route_pick() == "new-destination", (
            "a dismissed 'add stop' sheet left the flag armed — the next "
            "search silently inserted a via-point, changing waypoints.count"
        )

    def test_add_stop_still_works_when_not_dismissed(self) -> None:
        """Regression guard: the intended flow must be unaffected."""
        f = SheetFlags()
        f.open_search_to_add_stop()
        assert f.route_pick() == "insert-via-point"

    def test_dismiss_clears_the_quick_slot_too(self) -> None:
        f = SheetFlags()
        f.slot_to_fill = "home"
        f.dismiss()
        f.open_search_plain()
        assert f.route_pick() == "new-destination"


# --------------------------------------------------------------------------
# Swift source drift guards.
# --------------------------------------------------------------------------

class TestSwiftSourceGuards:

    def test_recompute_dirty_legs_guards_plan_identity(self) -> None:
        src = APPSTATUS.read_text(encoding="utf-8")
        body = strip_comments(decl_body(src, "func recomputeDirtyLegs"))
        assert body.count("plannedRoute === plan") >= 3, (
            "recomputeDirtyLegs must re-check plan identity before the "
            "await and in BOTH the success and failure paths after it"
        )

    def test_recompute_dirty_legs_passes_a_liveness_callback(self) -> None:
        src = APPSTATUS.read_text(encoding="utf-8")
        body = strip_comments(decl_body(src, "func recomputeDirtyLegs"))
        assert "isStillLive:" in body, (
            "the per-leg liveness callback is no longer threaded into "
            "RoutingService.recompute — writes resume at the source"
        )

    def test_routing_service_checks_liveness_around_the_await(self) -> None:
        src = ROUTING.read_text(encoding="utf-8")
        body = strip_comments(decl_body(src, "func recompute"))
        assert "isStillLive" in body, "liveness parameter gone"
        # The check must exist AFTER the network call, before the mutation.
        assert "await calculateLeg" in body
        after = body.split("await calculateLeg", 1)[1]
        before_set = after.split("plan.setOptions", 1)[0]
        assert "stillLive()" in before_set, (
            "no liveness check between `await calculateLeg` and "
            "`plan.setOptions` — this is the exact crash window"
        )

    def test_search_sheet_disarms_its_one_shot_flags_on_dismiss(self) -> None:
        src = PICKER.read_text(encoding="utf-8")
        assert "isPresented: $showSearch, onDismiss:" in src, (
            "the destination-search sheet lost its onDismiss — the "
            "addingStopToPlan / slotToFill flags stay armed after a swipe"
        )
        # Scope to the onDismiss closure by its real delimiters, not a fixed
        # character window (see test_swift_source_helper's meta-guard: a
        # fixed window silently stops covering the code it claims to check).
        start = src.index("isPresented: $showSearch, onDismiss:")
        block = src[start:src.index("DestinationSearchSheet(onPick:", start)]
        for flag in ("addingStopToPlan = false",
                     "slotToFill = nil",
                     "sharedSearchSeed = nil"):
            assert flag in block, f"onDismiss no longer clears {flag!r}"

    def test_cancel_planning_still_clears_the_live_plan(self) -> None:
        """The guards are keyed on `plannedRoute` becoming nil — if cancel
        stopped doing that, every guard above silently stops working."""
        src = APPSTATUS.read_text(encoding="utf-8")
        body = strip_comments(decl_body(src, "func cancelPlanning"))
        assert "plannedRoute = nil" in body
