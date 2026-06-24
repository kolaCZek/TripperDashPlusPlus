"""
Tests for the Wi-Fi auto-connect gate, as implemented in:

  - TripperDashPP/Tripper/WiFiAutoConnector.swift
    (struct AutoConnectGate — the pure, dependency-free decision core
    behind SSID-aware auto-connect and suppress-after-manual-disconnect.)

This is a 1:1 Python mirror of `AutoConnectGate`, structured like the
other mirror suites (test_nav_connect_gate.py, test_nav_autostart.py).
Keep the two in lockstep: if you change the Swift gate, change this, and
vice-versa.

── Behaviour being locked down (rider-confirmed, June 2026) ────────────
 • If the phone is on a Wi-Fi whose SSID is in the saved known-networks
   list AND the link is idle, auto-connect fires.
 • After a manual Disconnect, auto-connect is SUPPRESSED for the SSID the
   rider was on, until that SSID changes (rode away) or Wi-Fi cycles
   off→on (drops to nil, which differs from the suppressed SSID).
 • Suppression is per-SSID: parking on bike A, disconnecting, then later
   joining bike B must still auto-connect to B.
 • On a free account the SSID is always nil (entitlement absent) → the
   gate degrades to never firing, which the nil-SSID cases cover.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Optional, Set


class LinkActivity:
    IDLE = "idle"   # .idle / .error — free to start
    BUSY = "busy"   # .connecting / .handshaking / .connected / .reconnecting


@dataclass
class AutoConnectGate:
    """Mirror of the Swift struct AutoConnectGate.

    `evaluate` and `note_manual_disconnect` reproduce the Swift mutating
    methods exactly — same suppression-lift ordering, same guards.
    """

    suppressed_ssid: Optional[str] = None

    # --- mirror of noteManualDisconnect(currentSSID:knownSSIDs:) ---------
    def note_manual_disconnect(self, current_ssid: Optional[str],
                               known_ssids: Set[str]) -> None:
        if current_ssid is not None and current_ssid in known_ssids:
            self.suppressed_ssid = current_ssid
        else:
            # Disconnect while not on a known network clears suppression —
            # nothing meaningful to suppress.
            self.suppressed_ssid = None

    # --- mirror of evaluate(currentSSID:knownSSIDs:link:) ---------------
    def evaluate(self, current_ssid: Optional[str], known_ssids: Set[str],
                 link: str) -> Optional[str]:
        """Returns the SSID to connect to, or None for 'do nothing'."""
        # Lift suppression once we're no longer on the suppressed SSID
        # (changed network, or disassociated → None).
        if self.suppressed_ssid is not None and current_ssid != self.suppressed_ssid:
            self.suppressed_ssid = None

        if current_ssid is None or current_ssid not in known_ssids:
            return None
        if self.suppressed_ssid == current_ssid:
            return None
        if link != LinkActivity.IDLE:
            return None
        return current_ssid


KNOWN = {"RE_1A2B3C", "RE_999999"}


# --- Core auto-connect ------------------------------------------------------


def test_connects_when_on_known_ssid_and_idle():
    g = AutoConnectGate()
    assert g.evaluate("RE_1A2B3C", KNOWN, LinkActivity.IDLE) == "RE_1A2B3C"


def test_does_nothing_when_ssid_unknown():
    g = AutoConnectGate()
    assert g.evaluate("Starbucks", KNOWN, LinkActivity.IDLE) is None


def test_does_nothing_when_no_ssid_free_account():
    """Free account: SSID always nil → never fires."""
    g = AutoConnectGate()
    assert g.evaluate(None, KNOWN, LinkActivity.IDLE) is None


def test_does_nothing_when_link_busy():
    g = AutoConnectGate()
    for _ in range(2):
        assert g.evaluate("RE_1A2B3C", KNOWN, LinkActivity.BUSY) is None


# --- Suppress-after-manual-disconnect ---------------------------------------


def test_suppressed_after_manual_disconnect_on_same_ssid():
    g = AutoConnectGate()
    # Rider is on the bike, taps Disconnect.
    g.note_manual_disconnect("RE_1A2B3C", KNOWN)
    # Still parked on the same Wi-Fi → must NOT reconnect.
    assert g.evaluate("RE_1A2B3C", KNOWN, LinkActivity.IDLE) is None
    # And repeatedly so — suppression is sticky while the SSID holds.
    assert g.evaluate("RE_1A2B3C", KNOWN, LinkActivity.IDLE) is None


def test_suppression_lifts_when_ssid_changes():
    g = AutoConnectGate()
    g.note_manual_disconnect("RE_1A2B3C", KNOWN)
    assert g.evaluate("RE_1A2B3C", KNOWN, LinkActivity.IDLE) is None
    # Rode away to a different (unknown) network — suppression lifts, but
    # the new network isn't known so still nothing.
    assert g.evaluate("HomeWiFi", KNOWN, LinkActivity.IDLE) is None
    # Come back to the bike later → eligible again.
    assert g.evaluate("RE_1A2B3C", KNOWN, LinkActivity.IDLE) == "RE_1A2B3C"


def test_suppression_lifts_on_wifi_cycle_off_on():
    g = AutoConnectGate()
    g.note_manual_disconnect("RE_1A2B3C", KNOWN)
    assert g.evaluate("RE_1A2B3C", KNOWN, LinkActivity.IDLE) is None
    # Wi-Fi toggled off → SSID drops to None (differs from suppressed) →
    # suppression lifts.
    assert g.evaluate(None, KNOWN, LinkActivity.IDLE) is None
    # Wi-Fi back on, same bike → now eligible.
    assert g.evaluate("RE_1A2B3C", KNOWN, LinkActivity.IDLE) == "RE_1A2B3C"


def test_suppression_is_per_ssid():
    """Disconnect from bike A must not suppress bike B."""
    g = AutoConnectGate()
    g.note_manual_disconnect("RE_1A2B3C", KNOWN)
    # Immediately joining a DIFFERENT known bike should connect.
    assert g.evaluate("RE_999999", KNOWN, LinkActivity.IDLE) == "RE_999999"


def test_disconnect_while_on_unknown_network_clears_suppression():
    g = AutoConnectGate()
    # First suppress a real bike.
    g.note_manual_disconnect("RE_1A2B3C", KNOWN)
    assert g.suppressed_ssid == "RE_1A2B3C"
    # Then a disconnect while on some unknown Wi-Fi clears it entirely.
    g.note_manual_disconnect("HotelWiFi", KNOWN)
    assert g.suppressed_ssid is None
    # So the bike is eligible again on next sight.
    assert g.evaluate("RE_1A2B3C", KNOWN, LinkActivity.IDLE) == "RE_1A2B3C"


def test_disconnect_with_nil_ssid_clears_suppression():
    g = AutoConnectGate()
    g.note_manual_disconnect("RE_1A2B3C", KNOWN)
    g.note_manual_disconnect(None, KNOWN)  # e.g. Wi-Fi already off
    assert g.suppressed_ssid is None


# --- Interaction: busy link doesn't accidentally lift suppression -----------


def test_busy_then_idle_still_suppressed_on_same_ssid():
    g = AutoConnectGate()
    g.note_manual_disconnect("RE_1A2B3C", KNOWN)
    # A stray busy-state evaluation on the same SSID...
    assert g.evaluate("RE_1A2B3C", KNOWN, LinkActivity.BUSY) is None
    # ...must not have lifted suppression; idle on same SSID still blocked.
    assert g.evaluate("RE_1A2B3C", KNOWN, LinkActivity.IDLE) is None
    assert g.suppressed_ssid == "RE_1A2B3C"
