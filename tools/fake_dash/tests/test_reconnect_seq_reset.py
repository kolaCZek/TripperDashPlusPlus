"""
Regression for the power-cycle reconnect bug (6/2026 ride): after the
bike is switched OFF then ON again, the app never reconnects and times out
after the 10-minute budget.

Root cause: the K1G rolling sequence byte was not reset between connection
episodes. The better-dash authority builds a FRESH `RollingSeq` per
connection:

  - tripper_app_like_nav.py:  seq = RollingSeq(args.k1g_seq_start)  # top of main()
  - dash_ui/bike_link.py:     seq = _nav.RollingSeq(cfg.k1g_seq_start) # per connect()

The Swift port keeps ONE long-lived `RollingSeq` on `BikeLink`
(`private let seq = RollingSeq()`), created at init and shared across
every connect/reconnect. The first connect after launch starts at 0 (it
happens to match the authority), but after a ride the counter has climbed
to a high mid-stream value. When the dash is power-cycled it resets its
own K1G state and expects the handshake to begin from a fresh sequence;
the phone instead replays the stale seq, the dash drops the initial burst,
and every reconnect attempt fails until the deadline.

Fix: `RollingSeq.reset()` + a `seq.reset()` call at the top of
`runConnectFlow` (every connect attempt, fresh or reconnect), restoring
the "new connection → fresh sequence" contract the authority guarantees
by construction.

This file models the connect-episode seq behaviour in Python (the bug and
the fix), and adds a Swift-source drift guard so the reset call can't be
silently removed. We can't run Swift here (no Xcode); the drift guard is
the standard substitute used across this test suite.
"""

from __future__ import annotations

import re
from pathlib import Path

from fake_dash.protocol import RollingSeq


# --- Model of BikeLink's long-lived seq across connect episodes --------------
#
# BikeLink owns ONE RollingSeq for its whole lifetime. Each "connect
# episode" (fresh connect, or a reconnect retry) runs the handshake, which
# consumes a handful of seq values for the initial burst + pubkey request.
# We model just the first byte emitted by an episode's handshake — that's
# the one the freshly-rebooted dash latches onto.

_HANDSHAKE_SEQ_CONSUMES = 12  # initial burst (9) + pubkey + a couple status


def _run_episode(seq: RollingSeq, *, reset_first: bool) -> int:
    """Simulate one connect episode. Returns the FIRST seq byte the
    handshake puts on the wire (what the dash sees first)."""
    if reset_first:
        seq.reset()
    first = seq.consume()
    for _ in range(_HANDSHAKE_SEQ_CONSUMES - 1):
        seq.consume()
    return first


def test_rolling_seq_reset_returns_to_zero():
    s = RollingSeq(start=0)
    for _ in range(200):
        s.consume()
    s.reset()
    assert s.consume() == 0


def test_rolling_seq_reset_to_explicit_start():
    s = RollingSeq(start=0)
    for _ in range(50):
        s.consume()
    s.reset(0x10)
    assert s.consume() == 0x10


def test_bug_without_reset_reconnect_replays_stale_seq():
    """WITHOUT a per-episode reset, the second episode (a reconnect after a
    power-cycle) starts from a stale high seq instead of a fresh one — the
    exact condition that makes the rebooted dash drop our burst."""
    seq = RollingSeq(start=0)
    first_connect = _run_episode(seq, reset_first=False)
    reconnect = _run_episode(seq, reset_first=False)
    assert first_connect == 0
    # Reconnect did NOT start fresh — it continued the mid-ride sequence.
    assert reconnect == _HANDSHAKE_SEQ_CONSUMES
    assert reconnect != 0


def test_fix_with_reset_every_episode_starts_fresh():
    """WITH the fix, every connect episode resets first, so a reconnect
    after a power-cycle begins the handshake from the same fresh sequence
    the dash expects — identical to a first connect."""
    seq = RollingSeq(start=0)
    first_connect = _run_episode(seq, reset_first=True)
    # ... rider completes a long ride here, seq climbs ...
    for _ in range(5000):
        seq.consume()
    reconnect = _run_episode(seq, reset_first=True)
    assert first_connect == 0
    assert reconnect == 0
    assert reconnect == first_connect


# --- Swift-source drift guards -----------------------------------------------

def _repo_root() -> Path:
    return Path(__file__).resolve().parents[3]


def _read(rel: str) -> str:
    return (_repo_root() / rel).read_text(encoding="utf-8")


def test_swift_rollingseq_has_reset():
    """`RollingSeq` must expose a `reset(...)` method for episode reset."""
    src = _read("TripperDashPP/Tripper/K1GPacket.swift")
    assert re.search(r"func\s+reset\s*\(", src), (
        "RollingSeq.reset() missing — reconnect can't restore a fresh seq"
    )


def test_swift_connect_flow_resets_seq():
    """`runConnectFlow` must call `seq.reset()` so every connect episode
    (fresh OR reconnect) starts the handshake from a fresh sequence. This
    is the power-cycle reconnect fix; removing it reintroduces the 10-min
    reconnect timeout after the bike is switched off and on."""
    src = _read("TripperDashPP/Tripper/BikeLink.swift")
    idx = src.index("func runConnectFlow")
    # Guard against the reset being far away / in a different function.
    body = src[idx:idx + 1600]
    assert "seq.reset()" in body, (
        "runConnectFlow must call seq.reset() before the handshake — "
        "otherwise a reconnect after a power-cycle replays a stale seq and "
        "the rebooted dash drops the initial burst (blank-reconnect timeout)"
    )
