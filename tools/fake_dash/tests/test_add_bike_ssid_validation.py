"""
Guard for the Tripper AP SSID validation in AddBikeSheet.

Field report (external tester, 8/2026): the add-bike form's SSID footer used
to read "The dash IP is always 192.168.1.1." The tester typed that IP INTO the
SSID field. The banner then showed "192.168.1.1" as the network name, and
`ensureJoined("192.168.1.1")` could never associate → the dash handshake timed
out ("auth-OK within 3.0s") and the app looked broken.

Two fixes, guarded here:
  1. The IP must NOT appear in the SSID field's helper text (it invites the
     exact mistake). It may still appear elsewhere (permissions copy, etc.).
  2. AddBikeSheet must validate the SSID against the Tripper AP format
     `RE_XXXX_XXXXXX` so an IP / home-Wi-Fi name can't be saved as a bike.

This is a Python mirror of the Swift regex in
`AddBikeSheet.isValidTripperSSID`. If the Swift pattern changes, update this
mirror — the tests fail loudly until the two are realigned.
"""

from __future__ import annotations

import re
from pathlib import Path

from tests.swift_source import decl_body


def _repo_root() -> Path:
    return Path(__file__).resolve().parents[3]


def _add_bike_sheet_src() -> str:
    return (_repo_root() / "TripperDashPP" / "UI" / "AddBikeSheet.swift").read_text(
        encoding="utf-8"
    )


# Mirror of AddBikeSheet.isValidTripperSSID's regex.
TRIPPER_SSID_RE = re.compile(r"^RE_[A-Z0-9]{4}_[A-Z0-9]{6}$")


def _sheet_ssid_footer() -> str:
    """The helper text under the SSID field (the `footer:` after the
    'Wi-Fi network (SSID)' header)."""
    src = _add_bike_sheet_src()
    # Scope to the footer closure that follows the header, brace-balanced.
    # This matters because the only assertion on this text is a NEGATIVE one:
    # a fixed slice that is too short would silently stop covering the footer
    # and the guard would pass while the dash IP sat right back in it. Too
    # long is no better — it would reach into the toolbar and could fail on
    # unrelated text.
    return decl_body(src, 'Text("Wi-Fi network (SSID)")')


# --- The mistake the field report was about -------------------------------

def test_ip_not_in_ssid_field_helper_text():
    """The SSID field's helper text must not name the dash IP — that's what
    led the tester to type 192.168.1.1 into the SSID field."""
    footer = _sheet_ssid_footer()
    assert "192.168.1.1" not in footer, (
        "the dash IP is back in the SSID field footer — it invites typing the "
        "IP into the SSID field (8/2026 field report)"
    )


def test_sheet_has_ssid_validator():
    src = _add_bike_sheet_src()
    assert "isValidTripperSSID" in src, "AddBikeSheet lost its SSID format validator"
    # The Add button must be gated on validity, not just non-empty.
    assert "canAdd" in src and "isValidTripperSSID(normalizedSSID)" in src, (
        "Add button must be disabled unless the SSID matches the Tripper format"
    )


def test_swift_regex_matches_mirror():
    """The Swift source's regex literal must equal the pattern this test
    mirrors, so the two can't silently diverge."""
    src = _add_bike_sheet_src()
    assert r"^RE_[A-Z0-9]{4}_[A-Z0-9]{6}$" in src, (
        "Swift SSID regex changed — update TRIPPER_SSID_RE in this mirror too"
    )


# --- The validator behaviour (mirrored) -----------------------------------

def test_valid_tripper_ssids_pass():
    for s in ("RE_DEMO_000001", "RE_0W12_345678", "RE_ABCD_987654", "RE_ZZZZ_000000"):
        assert TRIPPER_SSID_RE.match(s), f"{s} should be a valid Tripper SSID"


def test_ip_and_home_names_rejected():
    for s in ("192.168.1.1", "MYHOMEWIFI", "RE_ABC_123456", "RE_DEMO_0001", "RE_0W12_34567", "TRIPPER"):
        assert not TRIPPER_SSID_RE.match(s), f"{s} must NOT validate as a Tripper SSID"


# --- The SSID typing aid must not undo the guard -----------------------------
# Mirror of AddBikeSheet.formatSSIDInput. It shapes (prefix, upper-case, the
# second underscore) but never strips characters, so a home Wi-Fi name or the
# dash IP still fails the format check. An earlier version stripped
# everything but letters/digits and turned "Vodafone5G" into a valid
# RE_VODA_FONE5G.

_PREFIX = "RE_"
_CODE = set("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")


def format_ssid_input(raw: str) -> str:
    up = raw.upper()
    if _PREFIX.startswith(up):
        return _PREFIX
    if up.startswith(_PREFIX):
        body = up[3:]
    elif up.startswith("RE"):
        body = up[2:]
    else:
        return up
    while len(body) > 11 and body.startswith(_PREFIX):
        body = body[3:]
    if len(body) > 4 and all(c in _CODE for c in body[:4]) and body[4] != "_":
        return _PREFIX + body[:4] + "_" + body[4:]
    return _PREFIX + body


def test_formatter_mirror_matches_swift_source():
    body = decl_body(_add_bike_sheet_src(), "nonisolated static func formatSSIDInput(")
    assert "} else {\n            return upper\n        }" in body, (
        "non-RE input must be returned as typed so the format error shows it"
    )
    assert ".filter" not in body, "the formatter must not strip characters"


def test_typing_aid_keeps_non_tripper_names_invalid():
    names = ["Home-WiFi-5G", "TP-Link_5GHz", "192.168.100.1", "192.168.1.1", "My Home Net"]
    for name in names:
        assert not TRIPPER_SSID_RE.match(format_ssid_input(name)), name
        assert not TRIPPER_SSID_RE.match(format_ssid_input(_PREFIX + name)), name
    assert format_ssid_input("Vodafone5G") == "VODAFONE5G"


def test_typing_aid_completes_and_keeps_valid_ssids():
    for ssid in ["RE_0W12_345678", "RE_RE12_345678", "RE_REAB_CDEFGH"]:
        assert format_ssid_input(ssid) == ssid
        assert format_ssid_input(_PREFIX + ssid) == ssid  # paste after prefix
        typed = _PREFIX
        for c in ssid[3:].replace("_", "").lower():
            typed = format_ssid_input(typed + c)
        assert typed == ssid
        while typed != _PREFIX:  # backspace never gets stuck
            shorter = format_ssid_input(typed[:-1])
            assert len(shorter) < len(typed) or shorter == _PREFIX
            typed = shorter
