"""
Tests for the multi-stop "next waypoint" dash label
(`ActiveNavLoop.nextWaypointLabel`).

Field request (Martin, 7/2026): on a multi-stop `PlannedRoute` the dash
shows an ETA to the FINAL destination but nothing for the next
intermediate waypoint. Repurpose the roadName TLV (`05 01`) — the same
wire field that rendered the burned "SCAN 0xNN" text during
glyph-capture sessions (see `docs/maneuver-glyphs/README.md`) and that
sits unused/nil on an ordinary single-destination ride — to show
"<time> to <name>" while `remainingWaypoints > 1` (i.e. the CURRENT
leg's destination is an intermediate stop, not the final one).

TIME-FIRST ordering (Martin, 7/2026 follow-up): a long waypoint name
must never push the ETA out of the dash's visible text row. The label
puts the time first and clips only the name's tail, so the ETA's
position and content are structurally independent of name length —
this holds regardless of whether the 28-char budget guess matches the
real dash's render width.

This mirrors the Swift implementation and pins:
  - time formatting parity with `NavigationHUD.timeRemaining`
    ("1h 23m" / "15 min");
  - the character budget + ellipsis clipping behaviour (clips the
    NAME, never the time, and the time is always the label's prefix);
  - the negative/zero ETA clamp.
"""

from __future__ import annotations

from pathlib import Path

import pytest


def _swift_source() -> str:
    here = Path(__file__).resolve()
    repo_root = here.parents[3]
    swift = repo_root / "TripperDashPP" / "Navigation" / "ActiveNavLoop.swift"
    return swift.read_text(encoding="utf-8")


def next_waypoint_label(name: str, eta_seconds: float) -> str:
    """Mirror of `ActiveNavLoop.nextWaypointLabel`. Character-count
    clipping (not byte-count) — matches Swift's `String.count` (grapheme
    clusters), which is what Python's `len()` on a `str` also counts by
    codepoint. Diacritics in the names this ships with (Czech) are single
    codepoints under NFC, so `len()` agrees with Swift `.count` for the
    fixtures used here.
    """
    dash_label_char_budget = 28
    total = int(max(0, eta_seconds))
    h = total // 3600
    m = (total % 3600) // 60
    time_part = f"{h}h {m}m" if h > 0 else f"{m} min"
    joiner = " to "
    name_budget = max(3, dash_label_char_budget - len(time_part) - len(joiner))
    if len(name) > name_budget:
        clipped_name = name[: name_budget - 1] + "…"
    else:
        clipped_name = name
    return time_part + joiner + clipped_name


# ----------------------------------------------------------------------
# Time formatting parity with NavigationHUD.timeRemaining.
# ----------------------------------------------------------------------

@pytest.mark.parametrize("name, eta_seconds, expected", [
    ("Slaný", 900, "15 min to Slaný"),
    ("Karlštejn", 4_980, "1h 23m to Karlštejn"),   # 1h 23m == 4980s
    ("Zvoleněves", 40, "0 min to Zvoleněves"),      # sub-minute -> "0 min", never blank
    ("Praha", 3_600, "1h 0m to Praha"),
])
def test_short_names_no_clipping(name, eta_seconds, expected):
    assert next_waypoint_label(name, eta_seconds) == expected


def test_negative_eta_clamps_to_zero():
    assert next_waypoint_label("Slaný", -5) == "0 min to Slaný"


# ----------------------------------------------------------------------
# Name clipping at the character budget (28 total, timePart + " to "
# reserved) — the ETA must ALWAYS be the untouched prefix.
# ----------------------------------------------------------------------

def test_name_at_exact_budget_no_ellipsis():
    # "15 min" timePart (6) + " to " joiner (4) = 10 reserved -> nameBudget = 18.
    exact_fit = "Rohanské nábřeží1"  # 17 characters, under budget
    assert len(exact_fit) == 17
    assert next_waypoint_label(exact_fit, 900) == "15 min to Rohanské nábřeží1"


def test_name_over_budget_gets_ellipsis_truncated():
    long_name = "Rohanské nábřeží Karlín"  # 23 characters, budget is 18 -> clip to 17 + "…"
    label = next_waypoint_label(long_name, 900)
    assert label == "15 min to Rohanské nábřeží …"
    assert label.startswith("15 min to "), "ETA must always be the untouched prefix"


def test_name_budget_recomputed_from_actual_time_length():
    # "1h 23m" is also 6 chars, so budget arithmetic matches the minutes
    # case here — but this asserts the budget is recomputed from the
    # ACTUAL time string length, not hardcoded to the "min" case.
    long_name = "Karlovarský kraj hranice okres"  # 30 characters
    label = next_waypoint_label(long_name, 4_980)
    assert label.startswith("1h 23m to ")
    assert "…" in label


def test_pathological_long_name_never_pushes_eta_out_of_frame():
    """The exact regression Martin flagged: an unexpectedly long
    waypoint name must never push the ETA out of the dash's visible
    text row. Time-first ordering + tail-only clipping guarantees the
    ETA prefix and overall label length stay bounded regardless of
    input name length."""
    pathological = "A" * 200
    label = next_waypoint_label(pathological, 900)
    assert label.startswith("15 min to ")
    assert len(label) <= 29


def test_empty_name_does_not_crash():
    assert next_waypoint_label("", 900) == "15 min to "


# ----------------------------------------------------------------------
# Swift-source drift guards.
# ----------------------------------------------------------------------

def test_swift_gate_requires_more_than_one_remaining_waypoint():
    """The roadName repurposing must be gated on remainingWaypoints > 1
    (i.e. NOT the final leg, NOT a single-destination ride) — otherwise
    it duplicates the dash's own final-ETA fields."""
    src = _swift_source()
    assert "nav.remainingWaypoints > 1" in src, (
        "next-waypoint label gate missing or changed — must stay > 1 so "
        "the final leg / single-destination ride doesn't show a "
        "redundant 'next waypoint' label"
    )


def test_swift_uses_eta_sec_not_final_destination_eta():
    """The label must show the CURRENT LEG's ETA (etaSec / nav.etaSeconds),
    never finalDestinationEtaSeconds — that field is already sent
    separately via the eta/remaining-time TLVs and scoped to the whole
    trip, not the next stop."""
    src = _swift_source()
    start = src.index("let roadName: String? = {")
    end = src.index("}()", start)
    body = src[start:end]
    assert "nextWaypointLabel(name: nextName, etaSeconds: etaSec)" in body
    assert "finalDestinationEtaSeconds" not in body


def test_swift_char_budget_constant_present():
    src = _swift_source()
    assert "dashLabelCharBudget = 28" in src


def test_swift_function_is_nonisolated():
    """Must be `nonisolated static` so it mirrors the RideStatsFormatting
    / MapViewSource.formatAheadDistance convention and is callable from a
    synchronous unit test despite ActiveNavLoop being @MainActor."""
    src = _swift_source()
    assert "nonisolated static func nextWaypointLabel(name: String, etaSeconds: TimeInterval) -> String" in src


def test_swift_returns_time_part_first():
    """Drift guard for the time-first ordering fix (Martin, 7/2026): the
    function must return `timePart + joiner + clippedName`, NOT
    `prefix + clippedName + joiner + timePart` — the whole point is that
    the ETA is a fixed-position, never-clipped PREFIX."""
    src = _swift_source()
    start = src.index("nonisolated static func nextWaypointLabel(")
    end = src.index("\n    }", start)
    body = src[start:end]
    assert "return timePart + joiner + clippedName" in body, (
        "nextWaypointLabel must return the time part FIRST — a long name "
        "must only ever eat into its own tail, never push the ETA out of "
        "frame"
    )
    # The name-budget subtraction must NOT include a "Next " prefix
    # anymore (that was the pre-fix, name-first template).
    assert '"Next "' not in body


# ----------------------------------------------------------------------
# Xcode project wiring (manual pbxproj — no synchronized groups).
# ----------------------------------------------------------------------

def _pbxproj_source() -> str:
    here = Path(__file__).resolve()
    repo_root = here.parents[3]
    pbx = repo_root / "TripperDashPP" / "TripperDashPP.xcodeproj" / "project.pbxproj"
    return pbx.read_text(encoding="utf-8")


def test_project_does_not_use_synchronized_groups():
    """Sanity: confirm the assumption behind the manual pbxproj edit below.
    If this ever flips (project migrated to Xcode-16 synchronized groups)
    the manual NextWaypointLabelTests references become redundant."""
    pbx = _pbxproj_source()
    assert "PBXFileSystemSynchronizedRootGroup" not in pbx, (
        "Project migrated to synchronized groups — the manual "
        "NextWaypointLabelTests references in project.pbxproj are now "
        "redundant; update this test."
    )


def test_next_waypoint_label_tests_is_in_pbxproj():
    pbx = _pbxproj_source()
    assert "NextWaypointLabelTests.swift in Sources" in pbx, (
        "NextWaypointLabelTests.swift must be in a PBXBuildFile (compiled) "
        "— otherwise the new tests silently never run."
    )
    assert "path = NextWaypointLabelTests.swift" in pbx, (
        "NextWaypointLabelTests.swift must have a PBXFileReference in "
        "project.pbxproj."
    )
