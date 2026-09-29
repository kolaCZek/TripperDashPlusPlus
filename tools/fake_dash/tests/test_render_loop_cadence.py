"""
The dash render loop must hold exactly `targetFps` (6) regardless of how long
a tick takes to render.

Field log 2026-09-28 21:41: 60 frames every ~11.6 s = 5.18 fps. The loop slept
a fixed 1/6 s AFTER each tick, so every period was render time (~26 ms) +
166.7 ms. MapViewSource.startTimer now sleeps until absolute deadlines on a
fixed grid (SuspendingClock, same uptime clock as HeartbeatLoop and the PTS).
A tick that overruns its slot skips the missed slots rather than bursting, and
a tick that STARTS late (main actor busy when the sleep fired) skips the next
slot if it would land closer than half an interval — so no two frames are ever
closer than 83 ms (≤ 12 fps even for one pair; the decoder blinks above ~12).
"""

from __future__ import annotations

from pathlib import Path

from tests.swift_source import decl_body, strip_comments

FPS = 6
INTERVAL = 1.0 / FPS


def _start_timer() -> str:
    src = (Path(__file__).resolve().parents[3] / "TripperDashPP" / "Map" / "MapViewSource.swift").read_text()
    return strip_comments(decl_body(src, "private func startTimer()"))


def _deadline_loop(work, seconds=60.0, late=lambda _: 0.0, min_gap=True):
    """Mirror of startTimer.

    `late(i)`: how long the main actor was busy when tick i's sleep fired,
    i.e. the tick STARTS that late. `work(i)`: the tick's own render time.
    `min_gap=False` models the loop without the half-interval guard.
    Returns tick START times (when the frame is produced).
    """
    t = deadline = 0.0
    ticks = []
    i = 0
    while t < seconds - 1e-9:  # float grid: 360 × (1/6) lands a hair under 60
        t += late(i)
        tick_start = t
        ticks.append(tick_start)
        t += work(i)
        i += 1
        deadline += INTERVAL
        earliest = tick_start + INTERVAL / 2
        while deadline <= t or (min_gap and deadline < earliest):
            deadline += INTERVAL
        t = deadline
    return ticks


def _gaps(ticks):
    return [b - a for a, b in zip(ticks, ticks[1:])]


def _relative_loop(work, seconds=60.0):
    """The old loop: tick, then sleep a fixed interval."""
    t, ticks, i = 0.0, [], 0
    while t < seconds - 1e-9:  # float grid: 360 × (1/6) lands a hair under 60
        ticks.append(t)
        t += work(i) + INTERVAL
        i += 1
    return ticks


def test_old_relative_sleep_reproduces_field_fps():
    fps = len(_relative_loop(lambda _: 0.026)) / 60.0
    assert 5.1 < fps < 5.3, fps


def test_deadline_loop_holds_exact_fps_under_render_load():
    assert len(_deadline_loop(lambda _: 0.026)) == 60 * FPS


def test_overrun_skips_slots_instead_of_bursting():
    # Every 10th tick renders 400 ms (main actor busy mid-tick).
    ticks = _deadline_loop(lambda i: 0.4 if i % 10 == 9 else 0.026)
    assert min(_gaps(ticks)) >= INTERVAL - 1e-9
    assert len(ticks) <= 60 * FPS


def _late_every_10th(ms):
    return lambda i: ms / 1000 if i % 10 == 9 else 0.0


def test_late_start_would_bunch_frames_without_the_min_gap_guard():
    # Review of #150: the sleep fires on time but the main actor is busy,
    # so the tick starts 140 ms late; the next deadline is still on grid.
    ticks = _deadline_loop(lambda _: 0.026, late=_late_every_10th(140), min_gap=False)
    assert min(_gaps(ticks)) < 0.03  # two frames ~27 ms apart (~37 fps pair)


def test_late_start_never_puts_two_frames_closer_than_half_an_interval():
    for ms in (50, 100, 140, 160):
        ticks = _deadline_loop(lambda _: 0.026, late=_late_every_10th(ms))
        assert min(_gaps(ticks)) >= INTERVAL / 2 - 1e-9, ms  # never above 12 fps
        assert len(ticks) >= 60 * FPS * 0.89, ms  # skips at most the 1-in-10 slot


def test_ordinary_jitter_keeps_exact_fps():
    # A few ms of main-actor latency on every tick must not trip the guard.
    assert len(_deadline_loop(lambda _: 0.026, late=lambda _: 0.005)) == 60 * FPS


def test_swift_start_timer_sleeps_until_deadline():
    body = _start_timer()
    assert "let interval = Duration.seconds(1) / targetFps" in body
    assert "deadline += interval" in body
    assert "try? await Task.sleep(until: deadline, clock: clock)" in body
    assert "let clock = SuspendingClock()" in body, "same uptime clock as HeartbeatLoop / PTS"
    assert "let tickStart = clock.now" in body
    assert "let earliest = tickStart + interval / 2" in body
    assert "while deadline <= now || deadline < earliest { deadline += interval }" in body
    assert "Task.sleep(nanoseconds:" not in body, "relative sleep drifts below targetFps"
