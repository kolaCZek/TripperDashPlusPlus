"""
Guard for the "free ride after arrival" behaviour, wired in:

  - TripperDashPP/UI/MapPickerView.swift (`finishArrival` drops into
    `startFreeRide()` when `resumeFreeRideAfterArrival` is on and the dash
    link is still connected)
  - TripperDashPP/Navigation/Models/DashNavSettings.swift
    (`resumeFreeRideAfterArrival` knob, default ON, persisted in v12)
  - TripperDashPP/UI/StreamingView.swift (settings toggle)

Rider feedback (8/2026): after arriving at a destination (having lost/regained
signal near the end) the dash sat on the blank nav-logo screen, because
arrival tears down the stream and nothing restarts it. The fix keeps the live
map on the dash by switching to free-ride on arrival, unless the rider opts
out.

Static-source guard (no Xcode / MapKit in CI): parse the Swift sources and
assert the wiring is present and correctly gated.
"""

from __future__ import annotations

import re
from pathlib import Path


def _repo_root() -> Path:
    return Path(__file__).resolve().parents[3]


def _read(rel: str) -> str:
    return (_repo_root() / rel).read_text(encoding="utf-8")


def _settings_src() -> str:
    return _read("TripperDashPP/Navigation/Models/DashNavSettings.swift")


def _map_picker_src() -> str:
    return _read("TripperDashPP/UI/MapPickerView.swift")


def _finish_arrival_body() -> str:
    src = _map_picker_src()
    start = src.index("private func finishArrival()")
    nxt = src.index("private func ", start + 10)
    body = src[start:nxt]
    # Strip // comment tails so prose mentioning startFreeRide() in the
    # explanation doesn't get mistaken for the actual call site.
    return "\n".join(
        re.sub(r"//.*$", "", line) for line in body.splitlines()
    )


# --- Settings model ---------------------------------------------------------


def test_setting_exists_and_defaults_on():
    src = _settings_src()
    m = re.search(
        r"var resumeFreeRideAfterArrival: Bool = (true|false)", src
    )
    assert m, "resumeFreeRideAfterArrival knob missing from DashNavSettings"
    assert m.group(1) == "true", (
        "resumeFreeRideAfterArrival must default to ON (rider-requested "
        "behaviour); flip only with an explicit decision"
    )


def test_setting_is_persisted():
    """The knob must round-trip: appear in Persisted, load(), and persist()."""
    src = _settings_src()
    assert "var resumeFreeRideAfterArrival: Bool?" in src, (
        "resumeFreeRideAfterArrival missing from the Persisted struct — it "
        "won't survive an app restart"
    )
    assert "self.resumeFreeRideAfterArrival = p.resumeFreeRideAfterArrival ?? true" in src, (
        "resumeFreeRideAfterArrival missing from load() (with an ON default "
        "for older blobs)"
    )
    assert "resumeFreeRideAfterArrival: resumeFreeRideAfterArrival" in src, (
        "resumeFreeRideAfterArrival missing from persist()"
    )


def test_store_key_bumped_to_v12():
    """Adding a field with an ON default means older (v11) blobs must be
    re-keyed so the new default takes effect cleanly."""
    src = _settings_src()
    assert 'storeKey = "dashNavSettings.v12"' in src, (
        "store key must be bumped to v12 when adding resumeFreeRideAfterArrival"
    )


# --- Arrival wiring ---------------------------------------------------------


def test_finish_arrival_starts_free_ride_when_enabled():
    body = _finish_arrival_body()
    assert "resumeFreeRideAfterArrival" in body, (
        "finishArrival must consult the resumeFreeRideAfterArrival setting"
    )
    assert "startFreeRide()" in body, (
        "finishArrival must call startFreeRide() so the dash keeps the live "
        "map instead of the nav-logo splash"
    )


def test_free_ride_resume_is_gated_on_connection():
    """We must only resume free-ride while the dash link is up — otherwise
    startFreeRide is a no-op at best. Assert the guard is present."""
    body = _finish_arrival_body()
    assert ".connected" in body, (
        "free-ride resume must be gated on bikeLink.state == .connected"
    )
    # The setting check and the connection check must both precede the call.
    call_idx = body.index("startFreeRide()")
    guard_region = body[:call_idx]
    assert "resumeFreeRideAfterArrival" in guard_region
    assert ".connected" in guard_region


# --- Settings UI ------------------------------------------------------------


def test_settings_toggle_present():
    src = _read("TripperDashPP/UI/StreamingView.swift")
    assert "resumeFreeRideAfterArrival" in src, (
        "Settings screen must expose a toggle for resumeFreeRideAfterArrival"
    )
