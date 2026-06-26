"""
Guard tests for the Files-app sharing of the app sandbox Documents/ dir.

`ManeuverLog` writes per-session navigation logs to
`Documents/maneuver-logs/nav-<ts>.jsonl`. Those are only reachable off the
phone *without Xcode* if the app exposes its Documents/ directory to the
Files app, which needs two Info.plist keys set together:

  - UIFileSharingEnabled              → Documents/ visible in Files / Finder
  - LSSupportsOpeningDocumentsInPlace → open files in place, not as a copy

These are static-analysis / contract tests (no Xcode, no simulator): they
parse the real Info.plist and assert both keys are present and true, so a
future plist refactor can't silently drop them and re-strand the logs behind
Xcode's container download. Same discipline as test_maneuver_log.py.
"""

from __future__ import annotations

import plistlib
from pathlib import Path

import pytest


def _repo_root() -> Path:
    return Path(__file__).resolve().parents[3]


def _info_plist_path() -> Path:
    return _repo_root() / "TripperDashPP" / "TripperDashPP-Info.plist"


def _load_info_plist() -> dict:
    with _info_plist_path().open("rb") as f:
        return plistlib.load(f)


def test_info_plist_exists():
    assert _info_plist_path().is_file(), "TripperDashPP-Info.plist is missing"


def test_info_plist_is_valid_xml():
    """The whole point of a static guard: a malformed plist breaks the build
    with a cryptic error. Parsing it here catches that in CI on Linux."""
    d = _load_info_plist()
    assert isinstance(d, dict) and d, "Info.plist did not parse to a non-empty dict"


def test_uifilesharing_enabled_true():
    d = _load_info_plist()
    assert d.get("UIFileSharingEnabled") is True, (
        "UIFileSharingEnabled must be <true/> so the maneuver logs in "
        "Documents/ show up under Files -> On My iPhone -> TripperDash++"
    )


def test_supports_opening_documents_in_place_true():
    d = _load_info_plist()
    assert d.get("LSSupportsOpeningDocumentsInPlace") is True, (
        "LSSupportsOpeningDocumentsInPlace must be <true/> so the log files "
        "open in place in the Files app instead of being imported as copies"
    )


def test_both_file_sharing_keys_present_together():
    """The two keys are useless apart — Apple only surfaces Documents/ in the
    Files app when BOTH are set. Pin them as a pair so a partial edit fails."""
    d = _load_info_plist()
    missing = [
        k
        for k in ("UIFileSharingEnabled", "LSSupportsOpeningDocumentsInPlace")
        if d.get(k) is not True
    ]
    assert not missing, f"file-sharing keys must be set together; missing/!true: {missing}"


@pytest.mark.parametrize(
    "key",
    [
        "UIBackgroundModes",
        "NSLocationWhenInUseUsageDescription",
        "NSLocalNetworkUsageDescription",
        "UIRequiredDeviceCapabilities",
        "UISupportedInterfaceOrientations",
        "ITSAppUsesNonExemptEncryption",
    ],
)
def test_existing_plist_keys_preserved(key: str):
    """Adding the file-sharing keys must not have clobbered the pre-existing
    background-mode / privacy / ATS / device-requirement keys."""
    d = _load_info_plist()
    assert key in d, f"pre-existing Info.plist key {key!r} went missing"
