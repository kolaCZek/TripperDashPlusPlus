"""
Ride history: every ride of the last 30 days (Martin, 2026-09-29):

    "pridat nahoru na listu dalsi ikonku s historii, kam by se ukladaly
     vsechny jizdy za poslednich 30 dni (stejne, jako mame statistiku a
     moznost ulozit jizdu na jejim konci)"

Contract pinned here, without Xcode (the Swift side is unit-tested in
`RideHistoryStoreTests.swift`):

  - One file per ride, named by its start time: a multi-leg session keeps
    one `startedAt`, so every teardown overwrites the same file.
  - Retention is decided from the FILENAME alone (launch never decodes a
    0.7 MB track just to prune it). Exactly 30 days old is kept.
  - RideStatsService feeds the history on every teardown AND in `reset()`
    BEFORE it zeroes the stats — the link-down path runs `reset()` before
    `stopStreaming()` → `end()`, so recording later would store nothing.
    A last-ride summary restored on launch is never re-recorded (it would
    resurrect a ride the rider deleted from the history).
  - Review of #152:
    * closing a RESTORED summary must not clear `restoredFromDisk` (the
      next ride would fold onto yesterday's and merge history files);
    * a ride deleted this session is not written back by a teardown, but
      comes back once the session rides on by another 100 m (distance, not
      track length — a stationary fix adds a point, no distance);
    * a restored summary is never re-recorded by `end()` either;
    * sessions under 100 m / 2 track points aren't kept;
    * the track is checkpointed every 300 accepted fixes (~5 min), off the
      main actor on one serial queue shared with every other write, so a
      kill mid-ride loses minutes, not the whole outing;
    * the sheet decodes once per opening, off the main actor; the detail
      builds its SavedRoute lazily (not in init); "Save to routes" dedupes
      against the library.
  - The toolbar button only shows in the idle picker state, next to
    Saved routes.
"""

from __future__ import annotations

from pathlib import Path

from tests.swift_source import decl_body, strip_comments

REPO = Path(__file__).resolve().parents[3]
APP = REPO / "TripperDashPP"
STORE = APP / "RideStats" / "RideHistoryStore.swift"
SERVICE = APP / "RideStats" / "RideStatsService.swift"
APPSTATUS = APP / "App" / "AppStatus.swift"
PICKER = APP / "UI" / "MapPickerView.swift"
VIEW = APP / "UI" / "RideHistoryView.swift"
PBXPROJ = APP / "TripperDashPP.xcodeproj" / "project.pbxproj"

DAY = 86_400
RETENTION_DAYS = 30
MIN_DISTANCE_M = 100.0


# ─────────────────────────── Python mirror ───────────────────────────


def file_name(started_at: int) -> str:
    return f"ride-{int(started_at)}.json"


def start_date(name: str) -> int | None:
    if not (name.startswith("ride-") and name.endswith(".json")):
        return None
    try:
        return int(name[5:-5])
    except ValueError:
        return None


def is_expired(started_at: float, now: float) -> bool:
    return started_at < now - RETENTION_DAYS * DAY


class History:
    """Mirror of RideHistoryStore over a dict standing in for the directory."""

    def __init__(self) -> None:
        self.files: dict[str, dict] = {}
        self.deleted: dict[str, float] = {}   # name → distance at deletion

    def record(self, ride: dict, now: float) -> None:
        if ride.get("startedAt") is None or ride.get("distance", 1_000) < MIN_DISTANCE_M:
            return
        name = file_name(ride["startedAt"])
        if name in self.deleted:
            if ride.get("distance", 1_000) < self.deleted[name] + MIN_DISTANCE_M:
                return
            del self.deleted[name]
        self.files[name] = ride
        self.prune(now)

    def delete(self, ride: dict) -> None:
        name = file_name(ride["startedAt"])
        self.deleted[name] = ride.get("distance", 1_000)
        self.files.pop(name, None)

    def prune(self, now: float) -> None:
        for name in list(self.files):
            s = start_date(name)
            if s is not None and is_expired(s, now):
                del self.files[name]

    def load(self, now: float) -> list[dict]:
        self.prune(now)
        return sorted(self.files.values(), key=lambda r: r["startedAt"], reverse=True)


class Service:
    """Mirror of the RideStatsService ↔ history wiring on the link-down path."""

    def __init__(self, history: History) -> None:
        self.history = history
        self.stats: dict = {"startedAt": None, "legs": 0}
        self.restored = False   # stats rehydrated from the last-ride summary

    def ride_leg(self, started_at: int) -> None:
        if self.stats["startedAt"] is None or self.restored:
            self.stats = {"startedAt": started_at, "legs": 0}
            self.restored = False
        self.stats = {**self.stats, "legs": self.stats["legs"] + 1,
                      "distance": self.stats.get("distance", 0) + 1_000}   # 1 km per leg

    def end(self, now: float) -> None:          # persistLastRide
        if self.stats["startedAt"] is not None and not self.restored:
            self.history.record(self.stats, now)

    def acknowledge(self) -> None:              # leaves `restored` alone
        pass


    def reset(self, now: float) -> None:
        if not self.restored:
            self.history.record(self.stats, now)    # BEFORE zeroing
        self.stats = {"startedAt": None, "legs": 0}
        self.restored = False


T0 = 1_790_000_000


def test_file_name_round_trips_start_time():
    assert start_date(file_name(T0)) == T0
    assert start_date("notes.txt") is None
    assert start_date("ride-abc.json") is None


def test_multi_leg_session_is_one_ride_not_duplicates():
    h = History()
    svc = Service(h)
    for _ in range(3):              # three legs, arrival teardown after each
        svc.ride_leg(T0)
        svc.end(T0 + 3600)
    rides = h.load(T0 + 3600)
    assert len(rides) == 1 and rides[0]["legs"] == 3


def test_link_down_reset_keeps_the_ride():
    # AppStatus runs reset() BEFORE stopStreaming() → end() when the bike
    # powers off; by the time end() runs, the stats are already zero.
    h = History()
    svc = Service(h)
    svc.ride_leg(T0)
    svc.reset(T0 + 100)
    svc.end(T0 + 101)
    assert [r["startedAt"] for r in h.load(T0 + 101)] == [T0]


def test_reset_does_not_resurrect_a_deleted_restored_ride():
    h = History()
    svc = Service(h)
    svc.stats, svc.restored = {"startedAt": T0, "legs": 1}, True
    svc.reset(T0 + 100)            # rider had deleted it from the history
    assert h.load(T0 + 100) == []


def test_acknowledged_restored_summary_does_not_merge_into_the_next_ride():
    h = History()
    svc = Service(h)
    svc.stats, svc.restored = {"startedAt": T0 - DAY, "legs": 1}, True
    svc.acknowledge()               # rider closes yesterday's panel
    svc.ride_leg(T0)                # today's ride
    svc.reset(T0 + 3600)
    assert [r["startedAt"] for r in h.load(T0 + 3600)] == [T0]


def test_deleted_ride_is_not_written_back_by_a_later_teardown():
    h = History()
    svc = Service(h)
    svc.ride_leg(T0)
    svc.end(T0 + 60)                # manual stop → recorded
    h.delete(svc.stats)             # rider deletes it from the history
    svc.reset(T0 + 120)             # bike off
    assert h.load(T0 + 120) == []


def test_deleted_ride_comes_back_once_the_session_rides_on():
    # Review 2 of #152: delete a short test loop, then keep riding without
    # disconnecting — the rest of the session must still reach the history.
    h = History()
    svc = Service(h)
    svc.ride_leg(T0)
    svc.end(T0 + 60)
    h.delete(svc.stats)
    svc.ride_leg(T0)                # next leg, same session (same startedAt)
    svc.end(T0 + 3600)
    assert [r["legs"] for r in h.load(T0 + 3600)] == [2]


def test_a_stationary_fix_does_not_bring_a_deleted_ride_back():
    # Review 3 of #152: Free ride started and stopped without moving (or a
    # restart replaying the last fix) adds track points but no distance.
    h = History()
    svc = Service(h)
    svc.ride_leg(T0)
    svc.end(T0 + 60)
    h.delete(svc.stats)
    svc.stats = {**svc.stats, "distance": svc.stats["distance"] + 5}   # +1 fix, 5 m jitter
    svc.end(T0 + 63)
    svc.reset(T0 + 90)
    assert h.load(T0 + 90) == []


def test_restored_summary_is_not_rewritten_by_end():
    h = History()
    svc = Service(h)
    svc.stats, svc.restored = {"startedAt": T0 - DAY, "legs": 1}, True
    svc.end(T0)                     # link drop before begin()
    assert h.load(T0) == []


def test_short_session_is_not_kept():
    h = History()
    h.record({"startedAt": T0, "distance": 40.0}, now=T0)
    assert h.load(T0) == []


def test_retention_boundary_and_order():
    h = History()
    for age_days in (31, 30, 2, 1):
        h.record({"startedAt": T0 - age_days * DAY}, now=T0 - age_days * DAY)
    kept = [(T0 - r["startedAt"]) // DAY for r in h.load(T0)]
    assert kept == [1, 2, 30]       # newest first; exactly 30 days is kept


def test_ride_without_a_fix_is_not_recorded():
    h = History()
    h.record({"startedAt": None}, now=T0)
    assert h.load(T0) == []


# ───────────────────────── Swift drift guards ────────────────────────


def _store() -> str:
    return strip_comments(STORE.read_text())


def test_swift_file_name_and_retention_match_the_mirror():
    src = _store()
    assert "nonisolated static let retentionDays = 30" in src
    assert '"ride-\\(Int(startedAt.timeIntervalSince1970)).json"' in src
    body = strip_comments(decl_body(src, "nonisolated static func isExpired"))
    assert "startedAt < now.addingTimeInterval(-Double(retentionDays) * 86_400)" in body


def test_swift_prune_reads_file_names_only():
    body = strip_comments(decl_body(_store(), "private func prune"))
    assert "startDate(fromFileName: url.lastPathComponent)" in body
    assert "JSONDecoder" not in body


def test_swift_store_lives_in_application_support_not_user_defaults():
    src = _store()
    assert "URL.applicationSupportDirectory" in src
    assert "UserDefaults" not in src


def test_swift_reset_records_before_zeroing_unless_restored():
    body = strip_comments(decl_body(SERVICE.read_text(), "func reset()"))
    assert "if !restoredFromDisk { history?.record(stats) }" in body
    assert body.index("history?.record(stats)") < body.index("stats = RideStats()")
    assert body.index("history?.record(stats)") < body.index("restoredFromDisk = false")


def test_swift_every_teardown_snapshot_is_recorded_unless_restored():
    src = SERVICE.read_text()
    body = strip_comments(decl_body(src, "private func persistLastRide"))
    assert "let historyURL = restoredFromDisk ? nil : history?.accept(snapshot)" in body
    assert body.count("JSONEncoder()") == 1, "encode once for UserDefaults and the history file"
    # encode + both writes happen inside the queued closure, not on main
    closure = body[body.index("let write: @Sendable () -> Void = {"):body.index("if background {")]
    assert "JSONEncoder().encode(snapshot)" in closure
    assert "defaults.set(data, forKey: key)" in closure
    assert "data.write(to: historyURL" in closure
    assert "RideHistoryStore.io.async(execute: write)" in body
    assert "RideHistoryStore.io.sync(execute: write)" in body
    assert "history" not in strip_comments(decl_body(src, "private func restoreLastRide"))


def test_swift_acknowledge_keeps_the_restored_flag():
    body = strip_comments(decl_body(SERVICE.read_text(), "func acknowledgeSummary()"))
    assert "removePersistedRide()" in body
    assert "restoredFromDisk" not in body


def test_swift_last_ride_key_is_only_touched_on_the_io_queue():
    # A late async checkpoint must not re-add a key reset()/acknowledge removed.
    src = strip_comments(SERVICE.read_text())
    assert "removePersistedRide()" in strip_comments(decl_body(SERVICE.read_text(), "func reset()"))
    rm = strip_comments(decl_body(SERVICE.read_text(), "private func removePersistedRide"))
    assert "RideHistoryStore.io.sync(execute: remove)" in rm
    # the only direct UserDefaults writes are inside queued closures (+ the
    # restore-failure cleanup at init, before any write can be queued)
    assert src.count("defaults.set(") == 1
    assert src.count("defaults.removeObject(") == 2
    store = _store()
    assert "nonisolated static let io = DispatchQueue(" in store


def test_swift_mid_ride_checkpoint():
    src = strip_comments(SERVICE.read_text())
    assert "static let checkpointEveryFixes = 300" in src
    body = strip_comments(decl_body(SERVICE.read_text(), "private func ingest"))
    assert "count % Self.checkpointEveryFixes == 0 { persistLastRide(background: true) }" in body, \
        "the checkpoint must not block the main actor (render loop)"
    assert "count != before" in body, "a rejected fix must not re-trigger the checkpoint"


def test_swift_store_tombstones_deletes_and_skips_short_sessions():
    src = _store()
    acc = strip_comments(decl_body(src, "func accept("))
    assert "guard Self.isWorthKeeping(stats)" in acc
    assert "guard stats.distanceMeters >= distanceAtDeletion + Self.minimumDistanceMeters else { return nil }" in acc
    assert "Self.io.sync(execute: write)" in strip_comments(decl_body(src, "func record("))
    dele = strip_comments(decl_body(src, "func delete("))
    assert "deleted[name] = ride.distanceMeters" in dele
    assert "Self.io.sync(execute: remove)" in dele
    keep = strip_comments(decl_body(src, "nonisolated static func isWorthKeeping"))
    assert "stats.trackPoints.count >= 2" in keep
    assert "stats.distanceMeters >= minimumDistanceMeters" in keep
    assert "nonisolated static let minimumDistanceMeters = 100.0" in src


def test_swift_load_decodes_off_main_once_per_presentation():
    src = _store()
    load = strip_comments(decl_body(src, "func load("))
    assert "Task.detached" in load and "RideHistoryStore.decode(urls)" in load
    assert "JSONDecoder" not in load
    assert "nonisolated static func decode(_ urls: [URL])" in src
    assert "nonisolated struct RideStats" in (APP / "RideStats" / "RideStats.swift").read_text()
    view = strip_comments(VIEW.read_text())
    assert "guard !loaded else { return }" in view and "await history.load()" in view
    assert ".onAppear { history.load() }" not in view


def test_swift_detail_builds_route_lazily_and_dedupes_save():
    view = strip_comments(VIEW.read_text())
    assert "State(initialValue:" not in view, "NavigationLink builds destinations for every row"
    assert "if route == nil { route = RideStatsService.savedRoute(from: ride) }" in view
    assert "$0.kind == .track && $0.name == route.name" in view


def test_swift_app_wires_one_history_into_ride_stats():
    src = strip_comments(APPSTATUS.read_text())
    assert "let rideHistory = RideHistoryStore()" in src
    assert "RideStatsService(location: locationService, history: rideHistory)" in src


def test_swift_history_button_only_in_idle_picker():
    src = PICKER.read_text()
    gate = src.index("if mode == .picking && !isPlanning {")
    button = src.index('.accessibilityLabel("Ride history")')
    end_of_gate = src.index("ToolbarItem(placement: .topBarTrailing) {\n                Button { showSettings = true }")
    assert gate < button < end_of_gate
    assert "RideHistoryView()" in src


def test_new_app_sources_are_wired_into_the_xcode_project():
    # Manual pbxproj: a file missing from the Sources phase silently never
    # compiles. (Test files are covered by test_xcode_test_target_wiring.)
    src = PBXPROJ.read_text()
    for name in ("RideHistoryStore.swift", "RideHistoryView.swift"):
        for needle in (f"/* {name} in Sources */ = {{isa = PBXBuildFile;",
                       f"/* {name} */ = {{isa = PBXFileReference;",
                       f"/* {name} */,",
                       f"/* {name} in Sources */,"):
            assert needle in src, f"{name}: missing {needle!r}"
