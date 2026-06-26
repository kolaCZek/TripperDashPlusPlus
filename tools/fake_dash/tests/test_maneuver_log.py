"""
Static + schema tests for the internal file-based maneuver logger.

`ManeuverLog.swift` is a pure iOS file-IO component with no wire-format
equivalent (it writes JSON Lines to the app's Documents directory), so —
exactly like `test_maneuver_catalog.py` and `test_active_nav_order.py` —
these tests can't compile Swift on Linux/CI. They instead:

  (a) STATIC-ANALYSE `ManeuverLog.swift`: assert the design contract the
      task pins down is actually present (JSON Lines output, `route_changed`
      boundary event, GPS lat/lon fields, a private serial DispatchQueue for
      off-MainActor writes, the `isEnabled` toggle, the Documents/maneuver-logs
      path, Sendable snapshot, hex wireByte).

  (b) STATIC-ANALYSE the hook sites: `ActiveNavLoop.tick()` must call
      `ManeuverLog.shared.record(...)` after pushing the overlay, and
      `ActiveNavigator` must expose the read-only `currentCoordinate`
      the logger reads the rider's GPS position from.

  (c) Verify the new file is wired into the Xcode project (this project does
      NOT use Xcode-16 synchronized file-system groups, so the file must be
      referenced explicitly in project.pbxproj or it won't compile).

  (d) MIRROR the `.jsonl` line shape in Python and assert a representative
      `nav_tick` line and a `route_changed` line parse as valid JSON with the
      expected schema — so the format the Swift encodes stays grep/replay-able.
"""

from __future__ import annotations

import json
import re
from pathlib import Path

import pytest


def _repo_root() -> Path:
    return Path(__file__).resolve().parents[3]


def _maneuver_log_source() -> str:
    p = _repo_root() / "TripperDashPP" / "Navigation" / "ManeuverLog.swift"
    return p.read_text(encoding="utf-8")


def _nav_loop_source() -> str:
    p = _repo_root() / "TripperDashPP" / "Navigation" / "ActiveNavLoop.swift"
    return p.read_text(encoding="utf-8")


def _navigator_source() -> str:
    p = _repo_root() / "TripperDashPP" / "Navigation" / "ActiveNavigator.swift"
    return p.read_text(encoding="utf-8")


def _pbxproj_source() -> str:
    p = (
        _repo_root()
        / "TripperDashPP"
        / "TripperDashPP.xcodeproj"
        / "project.pbxproj"
    )
    return p.read_text(encoding="utf-8")


# -----------------------------------------------------------------------
# (a) ManeuverLog.swift exists and honours the design contract.
# -----------------------------------------------------------------------

def test_maneuver_log_file_exists():
    p = _repo_root() / "TripperDashPP" / "Navigation" / "ManeuverLog.swift"
    assert p.is_file(), "ManeuverLog.swift was not created in TripperDashPP/Navigation/"


def test_is_a_shared_singleton():
    src = _maneuver_log_source()
    assert re.search(r"static\s+let\s+shared\s*=\s*ManeuverLog\(\)", src), (
        "ManeuverLog must be a `static let shared` singleton."
    )


def test_has_enabled_toggle_default_on():
    """`isEnabled` must exist, default to true, and gate `record`."""
    src = _maneuver_log_source()
    assert re.search(r"static\s+var\s+isEnabled\s*=\s*true", src), (
        "Expected `static var isEnabled = true` (default ON for debug)."
    )
    # record() early-returns when disabled.
    assert re.search(r"guard\s+Self\.isEnabled\s+else\s*\{\s*return", src), (
        "record() must early-return when `isEnabled` is false."
    )


def test_writes_json_lines_to_documents_maneuver_logs():
    src = _maneuver_log_source()
    assert ".jsonl" in src, "Logger must write JSON Lines (.jsonl) files."
    assert "maneuver-logs" in src, (
        "Logs must live under a `maneuver-logs` subdirectory."
    )
    assert ".documentDirectory" in src, (
        "Logs must be written under the app Documents directory."
    )
    # Per-session file name with a session-start stamp.
    assert re.search(r'"nav-\\\(.*?\)\.jsonl"', src) or "nav-" in src, (
        "Session files should be named nav-<sessionStart>.jsonl."
    )


def test_uses_private_serial_dispatch_queue_for_writes():
    """Writes must be delegated off the @MainActor 1 Hz loop to a serial
    queue so the nav loop never blocks on file IO."""
    src = _maneuver_log_source()
    assert "DispatchQueue(" in src, "Expected a private DispatchQueue for writes."
    # A serial queue is the default (no `attributes: .concurrent`).
    assert ".concurrent" not in src, (
        "The write queue must be SERIAL (no .concurrent attribute) so writes "
        "are serialized without extra locking."
    )
    assert re.search(r"queue\.async\s*\{", src), (
        "record() must hand the write to the serial queue via queue.async."
    )


def test_record_passes_only_sendable_snapshot():
    """Swift 6 strict concurrency: the value crossing the queue boundary must
    be a Sendable value type (an `Entry` struct), never an MKRoute object."""
    src = _maneuver_log_source()
    assert re.search(r"struct\s+Entry\s*:\s*Sendable", src), (
        "Expected a `struct Entry: Sendable` snapshot passed to the queue."
    )
    # The logger must not depend on MapKit — it works purely on value types,
    # so no MKRoute/MKRoute.Step reference can ever cross the queue boundary.
    assert "import MapKit" not in src, (
        "ManeuverLog must not import MapKit — only Sendable value snapshots "
        "may cross the queue boundary, never an MKRoute reference."
    )


def test_records_gps_lat_lon_fields():
    src = _maneuver_log_source()
    assert "lat" in src and "lon" in src, (
        "Each tick must record the rider's GPS lat/lon."
    )
    assert "coordinate?.latitude" in src and "coordinate?.longitude" in src, (
        "lat/lon must be derived from the supplied CLLocationCoordinate2D."
    )


def test_records_maneuver_and_hex_wirebyte():
    src = _maneuver_log_source()
    assert "wireByte" in src, "Tick must record the maneuver wireByte."
    # Hex formatting of the wire byte, e.g. 0x15.
    assert re.search(r'"0x%02X"', src) or re.search(r"0x%02X", src), (
        "wireByte should be logged as 2-digit hex (0x%02X)."
    )


def test_records_distances_eta_and_rerouting():
    src = _maneuver_log_source()
    for field in (
        "distanceToNextStep",
        "remainingDistance",
        "etaSeconds",
        "isRerouting",
    ):
        assert field in src, f"Tick must record `{field}`."


def test_records_route_identity():
    src = _maneuver_log_source()
    for field in ("destination", "routeStepCount", "routeDistanceMeters"):
        assert field in src, f"Route identity must include `{field}`."


def test_emits_route_changed_boundary_event():
    """A reroute / leg-advance changes the route key → a standalone
    `route_changed` line must be emitted so logs split per route."""
    src = _maneuver_log_source()
    assert '"route_changed"' in src or "route_changed" in src, (
        "Expected a `route_changed` boundary event."
    )
    assert "lastRouteKey" in src, (
        "Logger must track the previous route key to detect route changes."
    )
    assert "routeKey" in src, "Expected a `routeKey` route fingerprint."


def test_has_size_cap_rotation():
    src = _maneuver_log_source()
    assert "maxBytes" in src, "Expected a per-session size cap (maxBytes)."


def test_marked_internal_debug_local_only():
    """Privacy: the GPS-bearing log must be documented as internal/local-only."""
    src = _maneuver_log_source().lower()
    assert "internal" in src and ("debug" in src), (
        "ManeuverLog must be documented as an internal debug log."
    )
    assert "privacy" in src or "never" in src or "local" in src, (
        "ManeuverLog must document that the GPS trail stays local / is not "
        "transmitted."
    )


def test_subsystem_matches_active_nav_loop():
    """Subsystem string should be consistent with ActiveNavLoop's."""
    src = _maneuver_log_source()
    assert "cz.kolaczek.tripperdash" in src, (
        "ManeuverLog should use the same os.Logger subsystem as ActiveNavLoop "
        "(cz.kolaczek.tripperdash)."
    )


# -----------------------------------------------------------------------
# (b) Hook sites: ActiveNavLoop.tick() + ActiveNavigator.currentCoordinate.
# -----------------------------------------------------------------------

def test_active_nav_loop_calls_record():
    src = _nav_loop_source()
    assert "ManeuverLog.shared.record(" in src, (
        "ActiveNavLoop.tick() must call ManeuverLog.shared.record(...)."
    )


def test_record_call_is_after_overlay_push():
    """The logger call must sit at the END of tick(), after the overlay push,
    so it observes the exact glyph that was shown this tick."""
    src = _nav_loop_source()
    overlay_idx = src.find("setNavOverlay(overlay)")
    record_idx = src.find("ManeuverLog.shared.record(")
    assert overlay_idx != -1, "Could not find the overlay push in ActiveNavLoop."
    assert record_idx != -1, "Could not find the ManeuverLog call in ActiveNavLoop."
    assert record_idx > overlay_idx, (
        "ManeuverLog.shared.record(...) must come AFTER mapSource?.setNavOverlay(overlay)."
    )


def test_record_call_passes_core_values():
    """The single hook must forward the key tick values the task lists."""
    src = _nav_loop_source()
    # Narrow to the record(...) call argument list.
    m = re.search(r"ManeuverLog\.shared\.record\((.*?)\)\s*\n\s*\}", src, re.DOTALL)
    assert m, "Could not isolate the record(...) call arguments."
    call = m.group(1)
    for arg in (
        "coordinate:",
        "maneuver:",
        "wireByte:",
        "instructions:",
        "distanceToNextStep:",
        "remainingDistance:",
        "isRerouting:",
        "destination:",
        "routeStepCount:",
        "routeDistanceMeters:",
    ):
        assert arg in call, f"record(...) call is missing argument `{arg}`."


def test_record_call_forwards_gps_from_navigator():
    src = _nav_loop_source()
    assert "nav.currentCoordinate" in src, (
        "The GPS position must come from ActiveNavigator.currentCoordinate."
    )


def test_record_call_forwards_secondary_when_emitted():
    """Look-ahead maneuver should be logged only when actually emitted."""
    src = _nav_loop_source()
    assert "secondaryWireByte:" in src, (
        "record(...) should forward the secondary maneuver wire byte."
    )
    assert "emitSecondary ? distSecond : nil" in src, (
        "Secondary distance should be passed only when emitSecondary is true."
    )


def test_navigator_exposes_current_coordinate():
    """Minimal ActiveNavigator change: a read-only published current GPS."""
    src = _navigator_source()
    assert re.search(
        r"private\(set\)\s+var\s+currentCoordinate\s*:\s*CLLocationCoordinate2D\?",
        src,
    ), "ActiveNavigator must expose `private(set) var currentCoordinate: CLLocationCoordinate2D?`."
    assert "self.currentCoordinate = coord" in src, (
        "ActiveNavigator.ingest(fix:) must store the incoming fix coordinate."
    )


def test_navigator_change_is_minimal():
    """Guard the 'keep it minimal for trivial merge' constraint: at most a
    couple of references to the new property in ActiveNavigator."""
    src = _navigator_source()
    assert src.count("currentCoordinate") <= 3, (
        "ActiveNavigator change should stay minimal (declaration + assignment)."
    )


# -----------------------------------------------------------------------
# (c) Xcode project wiring (no synchronized groups in this project).
# -----------------------------------------------------------------------

def test_project_does_not_use_synchronized_groups():
    """Sanity: confirm the assumption behind the manual pbxproj edit. If this
    ever flips (project migrated to Xcode-16 synchronized groups) the manual
    references below become redundant and this test documents why."""
    pbx = _pbxproj_source()
    assert "PBXFileSystemSynchronizedRootGroup" not in pbx, (
        "Project migrated to synchronized groups — the manual ManeuverLog "
        "references in project.pbxproj are now redundant; update this test."
    )


def test_maneuver_log_is_in_pbxproj():
    pbx = _pbxproj_source()
    assert "ManeuverLog.swift in Sources" in pbx, (
        "ManeuverLog.swift must be in a PBXBuildFile (compiled) — otherwise it "
        "won't be built."
    )
    assert "path = ManeuverLog.swift" in pbx, (
        "ManeuverLog.swift must have a PBXFileReference in project.pbxproj."
    )


# -----------------------------------------------------------------------
# (d) Python mirror of the .jsonl line schema.
# -----------------------------------------------------------------------

def make_nav_tick_line(
    *,
    timestamp: str = "2026-06-26T14:35:02.123Z",
    lat: float = 50.0875,
    lon: float = 14.4213,
    maneuver: str = "right",
    wire_byte: int = 0x15,
    instructions: str = "Turn right onto Wenceslas Square",
    dist_next: float = 120.0,
    remaining: float = 5400.0,
    eta: float = 642.0,
    rerouting: bool = False,
    destination: str = "Prague",
    step_count: int = 12,
    route_distance: float = 5400.0,
    secondary_byte: int | None = None,
    secondary_dist: float | None = None,
) -> dict:
    """Mirror of `ManeuverLog.Line` for event == 'nav_tick'. Optional fields
    are omitted (mirrors `JSONEncoder` skipping nil)."""
    route_id = f"{destination}|{step_count}|{int(round(route_distance))}"
    line: dict = {
        "event": "nav_tick",
        "timestamp": timestamp,
        "lat": lat,
        "lon": lon,
        "maneuver": maneuver,
        "wireByte": f"0x{wire_byte:02X}",
        "instructions": instructions,
        "distanceToNextStep": dist_next,
        "remainingDistance": remaining,
        "etaSeconds": eta,
        "isRerouting": rerouting,
        "routeId": route_id,
        "destination": destination,
        "routeStepCount": step_count,
        "routeDistanceMeters": route_distance,
    }
    if secondary_byte is not None:
        line["secondaryManeuver"] = "left"
        line["secondaryWireByte"] = f"0x{secondary_byte:02X}"
    if secondary_dist is not None:
        line["secondaryDistanceMeters"] = secondary_dist
    return line


def make_route_changed_line(
    *,
    timestamp: str = "2026-06-26T14:40:11.001Z",
    rerouting: bool = True,
    destination: str = "Prague",
    step_count: int = 9,
    route_distance: float = 4800.0,
    from_route_id: str | None = "Prague|12|5400",
) -> dict:
    """Mirror of `ManeuverLog.Line` for event == 'route_changed'."""
    to_route_id = f"{destination}|{step_count}|{int(round(route_distance))}"
    return {
        "event": "route_changed",
        "timestamp": timestamp,
        "isRerouting": rerouting,
        "routeId": to_route_id,
        "destination": destination,
        "routeStepCount": step_count,
        "routeDistanceMeters": route_distance,
        "fromRouteId": from_route_id,
        "toRouteId": to_route_id,
    }


def test_nav_tick_line_is_valid_json_with_schema():
    line = make_nav_tick_line()
    blob = json.dumps(line)
    parsed = json.loads(blob)
    assert parsed["event"] == "nav_tick"
    # GPS + glyph + distances + reroute + route identity must all be present.
    for key in (
        "timestamp",
        "lat",
        "lon",
        "maneuver",
        "wireByte",
        "distanceToNextStep",
        "remainingDistance",
        "isRerouting",
        "routeId",
        "destination",
        "routeStepCount",
        "routeDistanceMeters",
    ):
        assert key in parsed, f"nav_tick line missing `{key}`."
    # wireByte is hex text.
    assert re.fullmatch(r"0x[0-9A-F]{2}", parsed["wireByte"])


def test_nav_tick_secondary_fields_optional():
    without = make_nav_tick_line()
    assert "secondaryWireByte" not in without

    withsec = make_nav_tick_line(secondary_byte=0x14, secondary_dist=300.0)
    assert withsec["secondaryWireByte"] == "0x14"
    assert withsec["secondaryDistanceMeters"] == 300.0


def test_route_changed_line_schema_and_jsonl_roundtrip():
    line = make_route_changed_line()
    # One object per line, newline-terminated → JSON Lines.
    blob = json.dumps(line) + "\n"
    assert blob.endswith("\n")
    parsed = json.loads(blob.strip())
    assert parsed["event"] == "route_changed"
    assert parsed["fromRouteId"] != parsed["toRouteId"], (
        "A route change must record distinct from/to route ids."
    )
    assert parsed["routeId"] == parsed["toRouteId"]


def test_route_id_distinguishes_reroute():
    """Two routes to the same destination with different step count / length
    must yield different route ids so the logs split per route."""
    a = make_nav_tick_line(step_count=12, route_distance=5400.0)
    b = make_nav_tick_line(step_count=9, route_distance=4800.0)
    assert a["routeId"] != b["routeId"], (
        "Reroute (new step count / distance) must change the routeId — this is "
        "what lets logs be filtered per route."
    )


def test_jsonl_multiple_lines_parse_independently():
    """A realistic fragment: route_changed marker then a nav tick — each line
    is an independent JSON object."""
    lines = [
        make_route_changed_line(from_route_id=None),
        make_nav_tick_line(),
    ]
    text = "\n".join(json.dumps(x) for x in lines) + "\n"
    parsed = [json.loads(row) for row in text.splitlines() if row]
    assert len(parsed) == 2
    assert parsed[0]["event"] == "route_changed"
    assert parsed[1]["event"] == "nav_tick"
