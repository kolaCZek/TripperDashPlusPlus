"""Settings -> Diagnostics -> Export log (Debug and TestFlight builds only).

Field logs could only be read with Console.app on a Mac tethered to the
phone, so a rider on the road had no way to send one. The app now writes its
own entries (OSLogStore, current process) to a text file for the share sheet,
and Info.plist persists the info level for its subsystems so a long ride's
"Baked batch" / "Speed-limit grid" / heartbeat lines don't roll out of the
memory buffer first.
"""

from __future__ import annotations

import plistlib
import re
from pathlib import Path

from tests.swift_source import decl_body, strip_comments

APP = Path(__file__).resolve().parents[3] / "TripperDashPP"


def _subsystems() -> set[str]:
    subs = set()
    for f in APP.rglob("*.swift"):
        if "TripperDashShare" in f.parts or "TripperDashPPTests" in f.parts:
            continue
        subs |= set(re.findall(r'subsystem:\s*"([^"]+)"', f.read_text(encoding="utf-8")))
    return subs


def test_info_plist_persists_info_level_for_every_app_subsystem():
    with open(APP / "TripperDashPP-Info.plist", "rb") as fh:
        prefs = plistlib.load(fh)["OSLogPreferences"]
    subs = _subsystems()
    assert subs, "no Logger subsystems found"
    assert subs <= set(prefs), f"subsystems without persisted info: {subs - set(prefs)}"
    for s in subs:
        level = prefs[s]["DEFAULT-OPTIONS"]["Level"]
        # Info, not Debug: debug is the per-tile URL / fetch spam.
        assert level == {"Enable": "Info", "Persist": "Info"}, s


def test_app_logs_under_one_subsystem():
    # Console.app filters and the bug-report template name one subsystem.
    assert _subsystems() == {"eu.kolaczek.tripperdashpp"}, _subsystems()


def test_export_reads_own_entries_off_main_and_shares_a_file():
    src = strip_comments((APP / "UI/StreamingView.swift").read_text(encoding="utf-8"))
    assert "import OSLog" in src
    view = decl_body(src, "struct StreamingView: View")
    assert "LogExportSection()" in view
    # Never in the App Store: TestFlight and the App Store both ship the
    # Release archive, so a Release build asks StoreKit where it came from.
    assert re.search(r"if canExportLog \{\s+LogExportSection\(\)\s+\}", view)
    assert ".task { canExportLog = await LogExportSection.isAvailable() }" in view
    assert "@State private var canExportLog = false" in view
    section = decl_body(src, "private struct LogExportSection: View")
    gate = decl_body(section, "nonisolated static func isAvailable(")
    # The StoreKit path sits outside `#if`, so CI's Debug build compiles it.
    assert "#else" not in gate
    flag = gate[gate.index("#if DEBUG"):gate.index("#endif")]
    assert "debug = true" in flag and "return" not in flag
    store = gate[gate.index("#endif"):]
    assert store.index("if debug { return true }") < store.index("AppTransaction.shared")
    assert "try? await AppTransaction.shared else { return false }" in store
    assert "return result.unsafePayloadValue.environment != .production" in store
    scheme = (APP / "TripperDashPP.xcodeproj/xcshareddata/xcschemes/TripperDashPP.xcscheme").read_text()
    assert re.search(r'<LaunchAction\s+buildConfiguration = "Debug"', scheme)
    assert re.search(r'<ArchiveAction\s+buildConfiguration = "Release"', scheme)
    assert "ShareLink(item: url)" in section
    # Feedback while the (slow) read runs, and no second tap.
    assert 'isPreparing ? "Preparing log…" : "Export log"' in section
    assert "if isPreparing { ProgressView() }" in section
    assert ".disabled(isPreparing)" in section
    write = decl_body(section, "@concurrent nonisolated private static func writeLog(")
    assert "OSLogStore(scope: .currentProcessIdentifier)" in write
    # No NSPredicate: iOS's OSLogStore mishandles a subsystem predicate
    # (FB8518539) and the export came out as an empty file. Filtered in
    # Swift; every app subsystem starts with "eu.kolaczek".
    assert "NSPredicate" not in write
    assert "try store.getEntries()" in write
    assert 'entry.subsystem.hasPrefix("eu.kolaczek")' in write
    # A header line, so a short export says whether iOS returned anything.
    assert "log entries read" in write
    assert "FileManager.default.temporaryDirectory" in write



_LOG_CALL = re.compile(r"\b\w*[lL]og\.(info|notice|error|warning|fault|log)\(")
# Interpolations that put a position in the log: coordinates directly, or
# strings derived from one (Overpass cache keys are a bbox, tile keys are
# z/x/y, shared map URLs carry @lat,lon, a ShareResolution holds coordinates).
_POSITION = re.compile(
    r"\\\((?:[^()]|\([^()]*\))*\b(latitude|longitude|coordinate)\b"
    r"|\\\(([\w.]*[kK]ey|[\w.?]*absoluteString[^,)]*|text ?\?\?[^,)]*|String\(describing: resolution\)), privacy: \.public"
)


def _log_calls(src: str):
    """Yield (line, full call text) for every non-debug Logger call,
    following balanced parentheses across lines."""
    for m in _LOG_CALL.finditer(src):
        depth, j = 1, m.end()
        while j < len(src) and depth:
            depth += {"(": 1, ")": -1}.get(src[j], 0)
            j += 1
        yield src.count("\n", 0, m.start()) + 1, src[m.start():j]


def test_no_persisted_log_line_carries_a_position():
    # The info level is persisted in every build, not just Debug, so a
    # position in a log line stays on the phone and leaves it in any
    # sysdiagnose. Log counts and distances; mark position-derived strings
    # .private. Debug lines aren't persisted, so they're out of scope.
    hits = [
        f"{f.relative_to(APP)}:{n}"
        for f in APP.rglob("*.swift")
        if "TripperDashPPTests" not in f.parts
        for n, call in _log_calls(strip_comments(f.read_text(encoding="utf-8")))
        if _POSITION.search(call)
    ]
    assert not hits, f"position in persisted log lines: {hits}"


def test_field_log_has_cellular_radio_and_path_changes():
    # Dash drops in an EDGE-only area: the export must show the radio
    # (LTE / Edge) and both path monitors' changes at info level.
    tele = strip_comments((APP / "Tripper/DeviceTelemetry.swift").read_text(encoding="utf-8"))
    assert 'log.info("Cellular radio' in tele
    assert "forName: .CTServiceRadioAccessTechnologyDidChange" in tele
    assert 'log.info("Cellular path' in tele
    link = strip_comments((APP / "Tripper/BikeLink.swift").read_text(encoding="utf-8"))
    assert 'log.info("Wi-Fi path' in link


def test_error_and_state_text_survives_a_release_export():
    # Without a debugger attached, os_log redacts every dynamic string not
    # marked `.public`, so a TestFlight export would show `<private>` for
    # the error text and link state, the lines a field log is read for.
    bad = []
    for f in APP.rglob("*.swift"):
        if "TripperDashPPTests" in f.parts:
            continue
        for n, line in enumerate(f.read_text(encoding="utf-8").splitlines(), 1):
            if not _LOG_CALL.search(line):
                continue
            for expr in re.findall(r"\\\((localizedDescription|[^()]*?\.localizedDescription|String\(describing: [^)]*\))(?!, privacy)", line):
                bad.append(f"{f.name}:{n} {expr}")
    assert not bad, bad

