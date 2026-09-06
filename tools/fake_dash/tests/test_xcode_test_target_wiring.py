"""
Guard: every Swift test file must be wired into project.pbxproj in ALL
FOUR places, and the live-MapKit probe must stay opt-in.

Why this exists: `TripperDashPP.xcodeproj` does not use synchronized
groups, so adding a `.swift` file to the folder is NOT enough — it needs
four separate entries (PBXBuildFile, PBXFileReference, the group's
`children`, and the target's `Sources` phase). Miss one and the file is
silently never compiled: no error, no warning, and a test that "passes"
because it never ran. That is the worst possible failure mode for a test,
so it gets its own guard.
"""

from __future__ import annotations

import re
from pathlib import Path


REPO = Path(__file__).resolve().parents[3]
PBXPROJ = REPO / "TripperDashPP" / "TripperDashPP.xcodeproj" / "project.pbxproj"
TESTS_DIR = REPO / "TripperDashPP" / "TripperDashPPTests"
PROBE = TESTS_DIR / "LegTailMapKitProbeTests.swift"


def _pbxproj() -> str:
    return PBXPROJ.read_text(encoding="utf-8")


class TestSwiftTestFilesAreWiredIntoTheProject:

    def test_every_test_file_has_all_four_pbxproj_entries(self) -> None:
        src = _pbxproj()
        missing: list[str] = []

        for path in sorted(TESTS_DIR.glob("*.swift")):
            name = path.name
            checks = {
                "PBXBuildFile": f"/* {name} in Sources */ = {{isa = PBXBuildFile;",
                "PBXFileReference": f"/* {name} */ = {{isa = PBXFileReference;",
                "group children": f"/* {name} */,",
                "Sources phase": f"/* {name} in Sources */,",
            }
            for label, needle in checks.items():
                if needle not in src:
                    missing.append(f"{name}: missing {label}")

        assert not missing, (
            "Swift test files not fully wired into project.pbxproj — they "
            "will NOT be compiled and their tests will never run:\n  "
            + "\n  ".join(missing)
        )

    def test_no_duplicate_build_file_ids(self) -> None:
        """A copy-pasted UUID makes Xcode drop one of the two files."""
        src = _pbxproj()
        ids = re.findall(r"^\t\t([0-9A-F]{24}) /\* .*? \*/ = \{isa = PBXBuildFile;",
                         src, re.M)
        dupes = {i for i in ids if ids.count(i) > 1}
        assert not dupes, f"duplicate PBXBuildFile ids in project.pbxproj: {dupes}"


class TestLiveMapKitProbeStaysOptIn:
    """The probe hits the real MKDirections API. If it ever runs by
    default it makes CI depend on Apple's servers, and a flaky test is
    worse than no test — it gets muted and then it protects nothing."""

    def test_probe_file_exists(self) -> None:
        assert PROBE.exists(), "LegTailMapKitProbeTests.swift is gone"

    def test_probe_is_gated_behind_an_env_var(self) -> None:
        body = PROBE.read_text(encoding="utf-8")
        assert "TRIPPERDASH_LIVE_MAPKIT" in body, (
            "the live MapKit probe lost its env-var gate — it would now "
            "run on every CI build and make the suite network-dependent"
        )
        assert "try #require(liveProbeEnabled" in body, (
            "the probe no longer bails out when the gate is unset; a "
            "`#expect` is not enough, the test must SKIP"
        )

    def test_probe_uses_the_real_helpers_not_a_reimplementation(self) -> None:
        """The probe's value is that it exercises the SAME lookup the app
        uses. A local copy of the algorithm would prove nothing."""
        body = PROBE.read_text(encoding="utf-8")
        assert "PolylineMath.nextStepIndex" in body, (
            "the probe must call the real nextStepIndex, not a copy"
        )
        assert "@testable import TripperDashPP" in body
