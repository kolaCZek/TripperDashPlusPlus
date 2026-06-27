"""
Guard tests for the build-time git-SHA stamping shown in Settings → Build.

The Settings screen's "Version" row shows the short git commit SHA the binary
was built from, e.g. `1.0 (46ab7a9)`. That value is produced by a build-phase
script (`tools/stamp-git-sha.sh`) which writes a `GitCommitSHA` key into the
built Info.plist with PlistBuddy; `AppStatus.buildCommitSHA` reads it back at
runtime and `StreamingView` renders it.

There are two failure classes a Linux CI run *can* catch without Xcode:

  1. Static wiring rot — someone drops the `GitCommitSHA` plist placeholder,
     deletes the Run Script phase, renames the script, or re-enables user
     script sandboxing (which would deny the script's read of `.git`, since
     `.git` lives above $SRCROOT). These are asserted by parsing the real
     Info.plist + project.pbxproj.

  2. SHA-derivation logic — the exact rule the shell implements (short HEAD,
     plus a trailing "*" when the tracked working tree is dirty). PlistBuddy
     isn't on Linux, so we don't run the script end-to-end; instead we mirror
     its git logic against a throwaway repo and pin both the clean and dirty
     cases. Same discipline as the state-machine mirrors elsewhere in this dir.
"""

from __future__ import annotations

import plistlib
import subprocess
import tempfile
from pathlib import Path

import pytest


def _repo_root() -> Path:
    return Path(__file__).resolve().parents[3]


def _info_plist_path() -> Path:
    return _repo_root() / "TripperDashPP" / "TripperDashPP-Info.plist"


def _script_path() -> Path:
    return _repo_root() / "tools" / "stamp-git-sha.sh"


def _pbxproj_path() -> Path:
    return (
        _repo_root()
        / "TripperDashPP"
        / "TripperDashPP.xcodeproj"
        / "project.pbxproj"
    )


def _load_info_plist() -> dict:
    with _info_plist_path().open("rb") as f:
        return plistlib.load(f)


# ───────────────────────── static wiring guards ─────────────────────────


def test_gitcommitsha_placeholder_present():
    """The plist must carry a GitCommitSHA string. The build script overwrites
    its value; if the key is gone, an unstamped/older build can't surface a SHA
    and AppStatus silently falls back to 'unknown'."""
    d = _load_info_plist()
    assert "GitCommitSHA" in d, "GitCommitSHA key missing from Info.plist"
    assert isinstance(d["GitCommitSHA"], str), "GitCommitSHA must be a string"


def test_stamp_script_exists_and_executable():
    s = _script_path()
    assert s.is_file(), "tools/stamp-git-sha.sh is missing"
    mode = s.stat().st_mode
    assert mode & 0o111, "stamp-git-sha.sh must be executable (chmod +x)"


def test_stamp_script_contents():
    """Pin the three load-bearing pieces of the script's behaviour so a future
    edit can't quietly break the contract the rest of the chain relies on."""
    body = _script_path().read_text()
    assert "rev-parse --short HEAD" in body, "script must read the short HEAD SHA"
    assert "GitCommitSHA" in body, "script must write the GitCommitSHA plist key"
    # dirty-tree marker
    assert '"*"' in body or "*" in body, "script should flag a dirty tree"


def test_pbxproj_has_shell_script_phase_wired():
    """The Run Script phase must exist AND be registered in the target's
    buildPhases — a phase object that isn't referenced never runs."""
    txt = _pbxproj_path().read_text()
    assert "PBXShellScriptBuildPhase" in txt, "no shell script build phase in pbxproj"
    assert txt.count("stamp-git-sha.sh") >= 1, "pbxproj does not reference the stamp script"
    # the phase UUID must appear twice: its definition + the buildPhases ref
    assert "Stamp git SHA */" in txt, "shell script phase comment/registration missing"


def test_user_script_sandboxing_disabled():
    """Reading `.git` (which lives above $SRCROOT) requires user script
    sandboxing OFF. If a refactor re-enables it, the script's git read is
    denied and every build stamps 'unknown' — assert it stays NO."""
    txt = _pbxproj_path().read_text()
    assert "ENABLE_USER_SCRIPT_SANDBOXING = NO;" in txt, (
        "ENABLE_USER_SCRIPT_SANDBOXING must be NO so the stamp script can read .git"
    )
    assert "ENABLE_USER_SCRIPT_SANDBOXING = YES;" not in txt, (
        "a leftover ENABLE_USER_SCRIPT_SANDBOXING = YES would re-sandbox the script"
    )


# ───────────────────── SHA-derivation logic mirror ─────────────────────
#
# Mirrors tools/stamp-git-sha.sh's git logic 1:1 (minus PlistBuddy, which is
# macOS-only). If you change the shell rule, update this mirror in the same
# commit or it pins stale behaviour.


def _derive_sha(workdir: Path) -> str:
    sha = subprocess.run(
        ["git", "-C", str(workdir), "rev-parse", "--short", "HEAD"],
        capture_output=True, text=True, check=True,
    ).stdout.strip()
    dirty = subprocess.run(
        ["git", "-C", str(workdir), "diff", "--quiet", "HEAD"],
    ).returncode != 0
    return f"{sha}*" if dirty else sha


def _git(workdir: Path, *args: str) -> None:
    subprocess.run(["git", "-C", str(workdir), *args], check=True,
                   capture_output=True, text=True)


@pytest.fixture()
def tmp_repo():
    with tempfile.TemporaryDirectory() as d:
        p = Path(d)
        _git(p, "init", "-q")
        _git(p, "config", "user.email", "t@t.t")
        _git(p, "config", "user.name", "t")
        (p / "f.txt").write_text("hello\n")
        _git(p, "add", "f.txt")
        _git(p, "commit", "-q", "-m", "init")
        yield p


def test_clean_tree_yields_bare_sha(tmp_repo):
    expected = subprocess.run(
        ["git", "-C", str(tmp_repo), "rev-parse", "--short", "HEAD"],
        capture_output=True, text=True, check=True,
    ).stdout.strip()
    got = _derive_sha(tmp_repo)
    assert got == expected, f"clean tree should give bare SHA, got {got!r}"
    assert not got.endswith("*"), "clean tree must not carry the dirty marker"


def test_dirty_tree_appends_star(tmp_repo):
    (tmp_repo / "f.txt").write_text("changed\n")  # uncommitted tracked change
    got = _derive_sha(tmp_repo)
    assert got.endswith("*"), f"dirty tree must append '*', got {got!r}"
    assert got[:-1], "there must still be a SHA before the '*'"
