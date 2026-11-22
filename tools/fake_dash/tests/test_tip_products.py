"""
Guard for the in-app tips (Settings → Support): the product IDs in
`SupportView.swift`, the local `Tips.storekit` config and the App Store
Connect setup must match, or a tip silently doesn't show. Tips must stay
consumable (they unlock nothing), and the .storekit file must not be
bundled into the app.
"""

import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3] / "TripperDashPP"
SWIFT = (ROOT / "UI/SupportView.swift").read_text()
STOREKIT = json.loads((ROOT / "UI/Tips.storekit").read_text())
PBXPROJ = (ROOT / "TripperDashPP.xcodeproj/project.pbxproj").read_text()


def swift_ids():
    block = re.search(r"static let productIDs = \[(.*?)\]", SWIFT, re.S).group(1)
    return re.findall(r'"([^"]+)"', block)


def test_ids_match_storekit_config():
    ids = swift_ids()
    assert ids == [p["productID"] for p in STOREKIT["products"]]
    assert len(ids) == 3 and all(i.startswith("eu.kolaczek.TripperDashPP.tip.") for i in ids)


def test_tips_are_consumable_and_nothing_else_is_sold():
    assert {p["type"] for p in STOREKIT["products"]} == {"Consumable"}
    assert STOREKIT["subscriptionGroups"] == [] and STOREKIT["nonRenewingSubscriptions"] == []


def test_finished_on_purchase_and_on_updates():
    assert "await transaction.finish()" in SWIFT
    assert "Transaction.updates" in SWIFT
    app = (ROOT / "App/TripperDashPPApp.swift").read_text()
    assert "Tips.finishUpdates()" in app


def test_storekit_file_not_shipped():
    assert "Tips.storekit */ = {isa = PBXFileReference" in PBXPROJ
    assert "Tips.storekit in " not in PBXPROJ  # no build-phase membership
