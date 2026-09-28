"""Settings -> Diagnostics -> Export log (Debug builds only).

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


def test_export_reads_own_entries_off_main_and_shares_a_file():
    src = strip_comments((APP / "UI/StreamingView.swift").read_text(encoding="utf-8"))
    assert "import OSLog" in src
    view = decl_body(src, "struct StreamingView: View")
    assert "LogExportSection()" in view
    # Debug only: Xcode Run uses Debug, Archive (TestFlight / App Store)
    # uses Release, so the button never ships. Both the call site and the
    # type are compiled out.
    call = view.index("LogExportSection()")
    assert view.rfind("#if DEBUG", 0, call) > view.rfind("#endif", 0, call)
    assert view.index("#endif", call) > call
    decl = src.index("private struct LogExportSection: View")
    assert src.rfind("#if DEBUG", 0, decl) > src.rfind("#endif", 0, decl)
    scheme = (APP / "TripperDashPP.xcodeproj/xcshareddata/xcschemes/TripperDashPP.xcscheme").read_text()
    assert re.search(r'<LaunchAction\s+buildConfiguration = "Debug"', scheme)
    assert re.search(r'<ArchiveAction\s+buildConfiguration = "Release"', scheme)
    section = decl_body(src, "private struct LogExportSection: View")
    assert "ShareLink(item: url)" in section
    write = decl_body(section, "@concurrent nonisolated private static func writeLog(")
    assert "OSLogStore(scope: .currentProcessIdentifier)" in write
    # Every app subsystem contains "kolaczek" (the predicate matches them all).
    assert 'NSPredicate(format: "subsystem CONTAINS %@", "kolaczek")' in write
    assert all("kolaczek" in s for s in _subsystems())
    assert "store.getEntries(matching: own)" in write
    assert "FileManager.default.temporaryDirectory" in write
