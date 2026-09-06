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
        assert ".enabled(if: liveProbeEnabled" in body, (
            "the probe no longer uses the .enabled(if:) condition trait. "
            "A `try #require(...)` inside the body does NOT skip — it "
            "records an issue and FAILS the test, which turned CI red once "
            "already. Only a condition trait actually skips."
        )
        assert "#require(liveProbeEnabled" not in body, (
            "the probe is gated with #require again — that fails instead "
            "of skipping when the env var is unset"
        )

    def test_probe_docs_and_skip_message_use_the_test_runner_prefix(self) -> None:
        """Field incident (2026-09-06): `xcodebuild test` does not forward
        the invoking shell's environment to the test-runner process — only
        `TEST_RUNNER_`-prefixed variables get passed through (with the
        prefix stripped; see `man xcodebuild`). Plain
        `TRIPPERDASH_LIVE_MAPKIT=1 xcodebuild test ...` builds and runs
        fine and silently skips with the SAME message as when it's unset —
        indistinguishable from the gate working. It happened twice before
        being traced. The usage instructions and the trait's own skip
        message must say `TEST_RUNNER_TRIPPERDASH_LIVE_MAPKIT`, not the
        bare name, or the next person hits the same trap."""
        body = PROBE.read_text(encoding="utf-8")
        assert "TEST_RUNNER_TRIPPERDASH_LIVE_MAPKIT=1 xcodebuild test" in body, (
            "the usage example dropped the TEST_RUNNER_ prefix — copying "
            "it verbatim would silently skip the probe again"
        )
        assert '"Live MapKit probe — set TEST_RUNNER_TRIPPERDASH_LIVE_MAPKIT=1 to run"' in body, (
            "the .enabled(if:) skip message dropped the TEST_RUNNER_ "
            "prefix — anyone reading the skip reason in CI output would "
            "be told the wrong variable name"
        )

    def test_live_probe_enabled_is_nonisolated(self) -> None:
        """CI (build 34043405676) warned:
        'main actor-isolated var liveProbeEnabled can not be referenced
        from a nonisolated context'. The project has default MainActor
        isolation on, so a bare top-level `var` is silently isolated —
        but `.enabled(if:)` is evaluated from a nonisolated context
        before the test body runs. A warning today, a hard error under a
        stricter concurrency mode tomorrow."""
        body = PROBE.read_text(encoding="utf-8")
        assert "nonisolated private var liveProbeEnabled" in body, (
            "liveProbeEnabled lost its `nonisolated` — the condition "
            "trait needs to read it from outside the MainActor"
        )

    def test_probe_uses_the_real_helpers_not_a_reimplementation(self) -> None:
        """The probe's value is that it exercises the SAME lookup the app
        uses. A local copy of the algorithm would prove nothing."""
        body = PROBE.read_text(encoding="utf-8")
        assert "PolylineMath.nextStepIndex" in body, (
            "the probe must call the real nextStepIndex, not a copy"
        )
        assert "@testable import TripperDashPP" in body

    def test_probe_doc_records_the_corrected_freeze_mechanism(self) -> None:
        """The live run (2026-09-06) falsified PR #125's original framing
        that the freeze needs an EMPTY terminal `arrive` polyline: leg 0
        of a real point-to-point route had 5 non-empty steps and still
        froze its last 23%. The probe's header must keep recording the
        corrected, more general mechanism (nextStepIndex can't return a
        step past the LAST one in route.steps, full stop) — not just the
        empty-polyline special case — so a future reader doesn't reapply
        the disproven narrower claim."""
        body = PROBE.read_text(encoding="utf-8")
        assert "RESULT (run 2026-09-06" in body, (
            "the probe lost its recorded live-run result — without it, "
            "the header's ONE-CLAIM framing reads as still-unverified "
            "or, worse, as the ONLY mechanism, which the run disproved"
        )
        assert "more general than" in body, (
            "the corrected-mechanism explanation is gone — the doc must "
            "not leave 'empty arrive polyline' as the sole framing"
        )
