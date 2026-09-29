"""
The dash render loop must hold exactly `targetFps` (6) regardless of how long
a tick takes to render.

Field log 2026-09-28 21:41: 60 frames every ~11.6 s = 5.18 fps. The loop slept
a fixed 1/6 s AFTER each tick, so every period was render time (~26 ms) +
166.7 ms. MapViewSource.startTimer now sleeps until absolute deadlines on a
fixed grid; a tick that overruns its slot skips the missed slots rather than
bursting frames.
"""

from __future__ import annotations

from pathlib import Path

from tests.swift_source import decl_body, strip_comments

FPS = 6
INTERVAL = 1.0 / FPS


def _start_timer() -> str:
    src = (Path(__file__).resolve().parents[3] / "TripperDashPP" / "Map" / "MapViewSource.swift").read_text()
    return strip_comments(decl_body(src, "private func startTimer()"))


def _deadline_loop(work, seconds=60.0):
    """Mirror of startTimer: tick, advance deadline, skip missed slots, sleep."""
    t = deadline = 0.0
    ticks = []
    i = 0
    while t < seconds - 1e-9:  # float grid: 360 × (1/6) lands a hair under 60
        ticks.append(t)
        t += work(i)
        i += 1
        deadline += INTERVAL
        while deadline <= t:
            deadline += INTERVAL
        t = deadline
    return ticks


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
    # Every 10th tick stalls 400 ms (main actor busy / brief suspension).
    ticks = _deadline_loop(lambda i: 0.4 if i % 10 == 9 else 0.026)
    gaps = [b - a for a, b in zip(ticks, ticks[1:])]
    assert min(gaps) >= INTERVAL - 1e-9, "frames bunched up after an overrun"
    assert len(ticks) <= 60 * FPS


def test_swift_start_timer_sleeps_until_deadline():
    body = _start_timer()
    assert "let interval = Duration.seconds(1) / targetFps" in body
    assert "deadline += interval" in body
    assert "while deadline <= now { deadline += interval }" in body
    assert "try? await Task.sleep(until: deadline, clock: clock)" in body
    assert "Task.sleep(nanoseconds:" not in body, "relative sleep drifts below targetFps"
