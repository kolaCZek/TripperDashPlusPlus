"""
Spoken speed-limit warning wiring (no Swift compiler on the host).

The decision itself (`SpeedLimitWarner`) is covered by Swift tests; this
pins the wiring that a refactor could silently drop:
  - the voice reuses the renderer's `isOverSpeedLimit` (no second threshold)
    and the sign's `displayLimit` number;
  - it is called from BOTH the navigating and the free-ride branch of `tick`;
  - it is gated on the global voice switch and its own OFF-by-default toggle;
  - it speaks at the lowest (`.advisory`) priority so a turn prompt cuts it
    off, and only a phrase that was actually spoken ends the episode;
  - the tolerance stepper is visible whenever the voice uses it;
  - every language has a non-empty phrase.
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
                   "VoicePhrase.speedLimit(", "priority: .advisory",
                   "speedLimitWarner.didSpeak(limit: limit"):
        assert needle in emit, needle
    assert "if voice.speak(" in emit, "commit only when the phrase was spoken"
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

    voice = strip_comments(_src("App/VoiceNavigator.swift"))
    assert "case advisory = 0" in voice and "case maneuver = 1" in voice
    assert "func speak(_ phrase: String, language: String, priority: Priority) -> Bool" in voice

    ui = strip_comments(_src("UI/StreamingView.swift"))
    stepper = ui[:ui.index('"Speeding tolerance')]
    stepper = stepper[stepper.rindex("if status.dashNavSettings"):]
    assert "voiceSpeedLimitEnabled" in stepper, "tolerance must show when the voice uses it"
    assert "speedLimitDisplay != .off" in stepper, "no tolerance for a voice that can't speak"

    warner = strip_comments(_src("RideAlerts/SpeedCameraAnnouncer.swift"))
    change = warner[warner.index("if limit != lastLimit {"):]
    change = change[:change.index("}")]
    assert "overTicks = 0" in change, "a new limit must be debounced too"
    assert "armed = true" not in change, "a flicker must not re-arm the episode"
    assert "guard armed || limit != spokenLimit, overTicks >= Self.overTicksNeeded" in warner
    assert "mutating func didSpeak(limit: Int, now: Date)" in warner
    assert "spokenLimit = limit" in warner

    phrases = _src("Navigation/VoicePhrase.swift")
    assert phrases.count("        speedLimit: \"") == 10
    assert 'speedLimit: ""' not in phrases


def test_maneuver_prompts_follow_the_unit_setting():
    # A rider on miles heard "In 300 metres": the tier prompt must get the
    # unit setting, and the English table must carry the imperial phrases.
    loop = _src("Navigation/ActiveNavLoop.swift")
    assert ("VoicePhrase.maneuver(kind, tier: tier, language: lang,\n"
            "                                                imperial: settings.units == .imperial)") in loop
    phrases = _src("Navigation/VoicePhrase.swift")
    assert 'farImperial: "In half a mile", nearImperial: "In a quarter of a mile"' in phrases
