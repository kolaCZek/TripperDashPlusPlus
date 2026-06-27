#!/bin/sh
#
# stamp-git-sha.sh — bake the short git commit SHA into the built Info.plist.
#
# Runs as an Xcode "Run Script" build phase. The app reads the resulting
# `GitCommitSHA` key at runtime (see AppStatus.buildCommitSHA) and shows it
# in Settings → Build → Version, e.g. "1.0 (46ab7a9)".
#
# Works for local Xcode builds, the GitHub Actions macOS CI build, and
# Archive / TestFlight — the script always stamps the SHA of the commit the
# binary was built from.
#
# Notes:
#   - The repo's .git lives one level ABOVE $SRCROOT (which points at the
#     TripperDashPP/ folder that holds the .xcodeproj). `git -C "$SRCROOT"`
#     walks up and finds it, so we don't hardcode the layout.
#   - Reading .git requires user-script sandboxing to be OFF for this target
#     (ENABLE_USER_SCRIPT_SANDBOXING = NO) — .git is outside $SRCROOT and the
#     sandbox would otherwise deny the read.
#   - A dirty working tree appends "*" so a local build with uncommitted
#     changes is visibly distinct from a clean commit (CI is always clean).
#   - Never fails the build: if git or the plist is missing it stamps
#     "unknown" and moves on.

set -eu

GIT_SHA="unknown"
if command -v git >/dev/null 2>&1; then
    if SHA=$(git -C "${SRCROOT}" rev-parse --short HEAD 2>/dev/null); then
        GIT_SHA="${SHA}"
        # Flag uncommitted changes (tracked files only). CI checkouts are
        # clean, so this only ever shows up on local developer builds.
        if ! git -C "${SRCROOT}" diff --quiet HEAD 2>/dev/null; then
            GIT_SHA="${GIT_SHA}*"
        fi
    fi
fi

PLIST="${TARGET_BUILD_DIR}/${INFOPLIST_PATH}"
if [ -f "${PLIST}" ]; then
    /usr/libexec/PlistBuddy -c "Set :GitCommitSHA ${GIT_SHA}" "${PLIST}" 2>/dev/null \
        || /usr/libexec/PlistBuddy -c "Add :GitCommitSHA string ${GIT_SHA}" "${PLIST}"
    echo "note: stamped GitCommitSHA=${GIT_SHA} into ${PLIST}"
else
    echo "warning: Info.plist not found at ${PLIST}; skipping GitCommitSHA stamp"
fi
