"""
Spoken speed-limit warning wiring (no Swift compiler on the host).

The decision itself (`SpeedLimitWarner`) is covered by Swift tests; this
pins the wiring that a refactor could silently drop:
  - the voice reuses the renderer's `isOverSpeedLimit` (no second threshold)
    and the sign's `displayLimit` number;
  - it is called from BOTH the navigating and the free-ride branch of `tick`;
  - it is gated on the global voice switch and its own OFF-by-default toggle;
  - every language has a phrase.
"""

from __future__ import annotations

from pathlib import Path

from tests.swift_source import decl_body, strip_comments

APP = Path(__file__).resolve().parents[3] / "TripperDashPP"


def _src(rel: str) -> str:
    return (APP / rel).read_text(encoding="utf-8")


def test_speed_limit_voice_wiring():
    loop = _src("Navigation/ActiveNavLoop.swift")
    emit = strip_comments(decl_body(loop, "private func emitSpeedLimitVoice()"))
    for needle in ("settings.voiceEnabled", "settings.voiceSpeedLimitEnabled",
                   "mapSource.isOverSpeedLimit", "mapSource.currentLimitKmh",
                   "MapViewSource.displayLimit(", "speedLimitWarner.shouldSpeak(",
                   "VoicePhrase.speedLimit("):
        assert needle in emit, needle
    assert "toleranceKmh" not in emit, "must reuse the renderer's over-limit state"

    tick = strip_comments(decl_body(loop, "private func tick()"))
    free_ride = tick[tick.index("guard nav.isNavigating else"):]
    free_ride = free_ride[:free_ride.index("return")]
    assert "emitSpeedLimitVoice()" in free_ride, "free ride must warn too"
    assert tick.count("emitSpeedLimitVoice()") == 2, "nav + free ride"

    settings = _src("Navigation/Models/DashNavSettings.swift")
    assert "var voiceSpeedLimitEnabled: Bool = false" in settings
    assert "p.voiceSpeedLimitEnabled ?? false" in settings
    assert "voiceSpeedLimitEnabled: voiceSpeedLimitEnabled" in settings

    phrases = _src("Navigation/VoicePhrase.swift")
    assert phrases.count("        speedLimit: \"") == 8
