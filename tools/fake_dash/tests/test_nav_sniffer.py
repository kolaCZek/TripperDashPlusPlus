"""
Tests for the nav-info TLV sniffer (`fake_dash.nav_sniffer` + server hook).

The sniffer exists to capture the wire effect of two OEM-app settings that
currently have NO confirmed byte on our side (12/24h ETA format, bubble
bottom row). It decodes the phone's `0x05` active-nav fields, snapshots
them, and diffs two snapshots across a toggle flip so the changed field is
obvious.

We ground the tests in the same real-phone capture the ETA-format test
uses (better-dash `_NAV_FULL`), then simulate a toggle flip by mutating one
field and asserting the diff isolates exactly that field.
"""

from __future__ import annotations

import binascii

from fake_dash.nav_sniffer import (
    FIELD_CATALOG,
    NavSnapshot,
    describe_field,
)
from fake_dash.protocol import decode_packet

# Real-phone active-nav capture, verbatim from better-dash `_NAV_FULL`
# (same fixture as test_eta_format_capture.py). Road "Taille de Mas du Gr",
# ETA "0303", ETA-format 0x30, decimal-separator 0x55.
NAV_FULL_HEX = (
    "007e001100000000020100054b31472025050100145461696c6c65206465204d617320647520477200"
    "050200013c050300013405050002000a05060001300507000130050800043033303305540001300509"
    "0002004f0546000110050a000155050c000104050b0006303031303030055500012006050001aa060d0001aa"
)


def _nav_full_segments():
    return decode_packet(binascii.unhexlify(NAV_FULL_HEX))


def _load(snap: NavSnapshot, segs) -> None:
    for s in segs:
        if s.type == 0x05:
            snap.observe(s.type, s.sub, s.payload)


# --- catalog / describe ------------------------------------------------------


def test_catalog_covers_the_suspect_fields():
    """The two undecoded settings we're hunting must be labelled so the
    operator recognises them in a dump/diff."""
    assert (0x05, 0x54) in FIELD_CATALOG  # ETA format (12/24h suspect)
    assert (0x05, 0x0C) in FIELD_CATALOG  # bottom-row selector suspect
    assert "12/24h" in FIELD_CATALOG[(0x05, 0x54)]
    assert "bottom-row" in FIELD_CATALOG[(0x05, 0x0C)]


def test_describe_field_renders_ascii_and_ints():
    """describe_field should surface a readable hint, not just hex."""
    eta = describe_field(0x05, 0x08, b"0303")
    assert "0303" in eta  # ascii hint for the ETA value
    unit = describe_field(0x05, 0x06, bytes([0x30]))
    assert "u8=48" in unit  # single-byte int hint (0x30 == 48)


def test_describe_unknown_field_does_not_crash():
    line = describe_field(0x05, 0x99, bytes([0x01, 0x02]))
    assert "unknown field" in line
    assert "0102" in line


# --- snapshot / observe ------------------------------------------------------


def test_observe_reports_new_then_quiet_then_changed():
    snap = NavSnapshot()
    # First sighting is "new" → changed True.
    assert snap.observe(0x05, 0x54, bytes([0x30])) is True
    # Same value again → not changed (steady-state field goes quiet).
    assert snap.observe(0x05, 0x54, bytes([0x30])) is False
    # New value → changed True (this is the toggle-flip signal).
    assert snap.observe(0x05, 0x54, bytes([0x31])) is True


def test_snapshot_holds_current_state_of_every_field():
    snap = NavSnapshot()
    _load(snap, _nav_full_segments())
    # A representative spread of fields from the capture must be present.
    assert snap.fields[(0x05, 0x08)] == b"0303"          # ETA value
    assert snap.fields[(0x05, 0x54)] == bytes([0x30])     # ETA format
    assert snap.fields[(0x05, 0x0A)] == bytes([0x55])     # decimal separator '.'
    assert snap.fields[(0x05, 0x0C)] == bytes([0x04])     # bottom-row suspect


# --- diff (the actual capture workflow) --------------------------------------


def test_diff_isolates_a_single_toggle_flip():
    """
    Simulate the real capture workflow: baseline the wire state, then flip
    ONE setting in the (emulated) OEM app and diff. The diff must name only
    the changed field — this is what tells Martin which byte a toggle drives.
    """
    baseline = NavSnapshot()
    _load(baseline, _nav_full_segments())
    snapshot_before = baseline.copy()

    # OEM app flips 12h→24h: only the 05 54 byte changes on the wire.
    baseline.observe(0x05, 0x54, bytes([0x31]))

    lines = snapshot_before.diff(baseline)
    assert len(lines) == 1
    assert "05 54" in lines[0]
    assert "CHANGED" in lines[0]
    assert "30 -> 31" in lines[0]


def test_diff_empty_when_nothing_changed():
    baseline = NavSnapshot()
    _load(baseline, _nav_full_segments())
    other = baseline.copy()
    assert baseline.diff(other) == []


def test_diff_flags_added_field():
    """A field that only appears after the flip (e.g. a bottom-row byte the
    OEM app starts sending) shows up as ADDED."""
    baseline = NavSnapshot()
    baseline.observe(0x05, 0x08, b"0303")
    after = baseline.copy()
    after.observe(0x05, 0x0C, bytes([0x04]))
    lines = baseline.diff(after)
    assert len(lines) == 1
    assert "ADDED" in lines[0]
    assert "05 0C" in lines[0]


# --- server integration ------------------------------------------------------


def test_server_sniff_hook_records_fields():
    """The server's _sniff_segment must populate a peer snapshot so the
    control-socket `snap` commands have data to diff."""
    from fake_dash.server import FakeDashServer, PhonePeer

    srv = FakeDashServer(enable_sniff=True, enable_beacon=False)
    peer = PhonePeer(addr=("127.0.0.1", 5555), first_seen=0.0)
    for s in _nav_full_segments():
        if s.type == 0x05:
            srv._sniff_segment(s, peer)
    assert peer.snap is not None
    assert peer.snap.fields[(0x05, 0x54)] == bytes([0x30])
    assert peer.snap.fields[(0x05, 0x0C)] == bytes([0x04])


def test_server_sniff_disabled_by_default():
    """Without --sniff the hook is inert (no snapshot side-effects) so
    normal harness runs are unchanged."""
    from fake_dash.server import FakeDashServer

    srv = FakeDashServer(enable_beacon=False)
    assert srv.enable_sniff is False
    # The sniff command handler is not wired into the control server.
    assert srv._control._on_sniff is None
