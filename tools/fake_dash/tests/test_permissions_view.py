"""Drift guard for Settings -> About -> Check permissions (PermissionsView).

Swift doesn't compile on the Linux host, so this pins that every runtime
permission / system toggle the app depends on keeps a row in the sheet.
"""

from pathlib import Path

SRC = (Path(__file__).resolve().parents[3] / "TripperDashPP" / "UI" / "PermissionsView.swift").read_text()


def test_every_permission_has_a_row():
    for title in ("Location", "Apple Music", "Local Network", "Cellular Data", "Live Activities"):
        assert f'title: "{title}"' in SRC, title


def test_live_state_sources():
    assert "ActivityAuthorizationInfo().areActivitiesEnabled" in SRC
    assert "cellularData.restrictedState" in SRC
    # The CTCellularData notifier runs off-main; a closure written in this
    # MainActor view would trap there. Poll the property instead.
    assert "cellularDataRestrictionDidUpdateNotifier" not in SRC
