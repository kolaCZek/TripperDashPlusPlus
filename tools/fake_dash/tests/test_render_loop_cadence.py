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


def _deadline_loop(work, seconds=60.0, late=lambda _: 0.0, min_gap=True, skip=True):
    """Mirror of startTimer.

    `late(i)`: how long the main actor was busy when tick i's sleep fired,
    i.e. the tick STARTS that late. `work(i)`: the tick's own render time.
    `min_gap=False` / `skip=False` model the loop without each guard.
    Returns the times frames reach the encoder (end of each tick).
    """
    t = deadline = 0.0
    out = []
    i = 0
    while t < seconds - 1e-9:  # float grid: 360 × (1/6) lands a hair under 60
        t += late(i)
        t += work(i)
        out.append(t)            # onFrame fires at the END of the tick
        i += 1
        deadline += INTERVAL
        while skip and deadline <= t:
            deadline += INTERVAL
        wake = max(deadline, t + INTERVAL / 2) if min_gap else deadline
        t = max(t, wake)         # sleeping until a past instant returns at once
    return out


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


def _every_10th(ms, base=0.0):
    return lambda i: ms / 1000 if i % 10 == 9 else base


def _short_runs(out):
    """Longest run of consecutive frame gaps shorter than one interval."""
    run = best = 0
    for g in _gaps(out):
        run = run + 1 if g < INTERVAL - 1e-9 else 0
        best = max(best, run)
    return best


def test_overrun_skips_slots_instead_of_bursting():
    # Every 10th tick renders 400 ms: afterwards ONE short gap at most, not
    # a catch-up burst of back-to-back frames.
    work = _every_10th(400, 0.026)
    assert _short_runs(_deadline_loop(work)) <= 1
    assert _short_runs(_deadline_loop(work, skip=False)) >= 2


def test_slow_or_overrunning_tick_never_bunches_frames():
    # Review 2 of #150: the gap must hold between frames SENT (tick end),
    # not tick starts — a 150 ms render inside its slot used to leave the
    # next frame 42.7 ms behind it, a 490 ms overrun ~36 ms.
    for ms in (150, 490):
        work = _every_10th(ms, 0.026)
        assert min(_gaps(_deadline_loop(work))) >= INTERVAL / 2 - 1e-9, ms
        assert min(_gaps(_deadline_loop(work, min_gap=False))) < 0.05, ms


def test_late_start_never_puts_two_frames_closer_than_half_an_interval():
    for ms in (50, 100, 140, 160):
        out = _deadline_loop(lambda _: 0.026, late=_every_10th(ms))
        assert min(_gaps(out)) >= INTERVAL / 2 - 1e-9, ms  # never above 12 fps
        assert len(out) >= 60 * FPS * 0.9 - 1, ms
    no_guard = _deadline_loop(lambda _: 0.026, late=_every_10th(140), min_gap=False)
    assert min(_gaps(no_guard)) < 0.03  # ~27 ms pair without the guard


def test_steady_lateness_degrades_gradually():
    # Review 2 of #150: skipping a slot on every late start halved the rate
    # at 85 ms steady lateness (6 → 3 fps). Delaying instead degrades softly.
    fps = len(_deadline_loop(lambda _: 0.026, late=lambda _: 0.085)) / 60.0
    assert fps > 4.0, fps


def test_ordinary_jitter_keeps_exact_fps():
    # A few ms of main-actor latency on every tick must not trip the guard.
    assert len(_deadline_loop(lambda _: 0.026, late=lambda _: 0.005)) == 60 * FPS


def test_swift_start_timer_sleeps_until_deadline():
    body = _start_timer()
    assert "let interval = Duration.seconds(1) / targetFps" in body
    assert "deadline += interval" in body
    assert "let clock = SuspendingClock()" in body, "same uptime clock as HeartbeatLoop / PTS"
    # min gap measured from the tick's END (after tickOnMain), not its start
    assert body.index("await self?.tickOnMain()") < body.index("let now = clock.now")
    assert "while deadline <= now { deadline += interval }" in body
    assert "try? await Task.sleep(until: max(deadline, now + interval / 2), clock: clock)" in body
    assert "tickStart" not in body
    assert "while !Task.isCancelled, self != nil {" in body, "stop once the source is freed"
    assert "Task.sleep(nanoseconds:" not in body, "relative sleep drifts below targetFps"
