"""Guards for the AVAudioSession main-thread hang risk.

`setCategory` and `setActive` are synchronous IPC to `mediaserverd`. Called
on the main thread they can block long enough to drop frames, which is what
Xcode's "AVAudioSession Hang Risk" diagnostic reports. `VoiceNavigator` is
`@MainActor` — it has to be, it drives `AVSpeechSynthesizer` — so every
session mutation must hop onto a queue instead.

This is a runtime diagnostic, not a compiler one: nothing in CI fails if it
regresses, and the app keeps working (just with a stutter under load). These
guards are the only automated thing that notices.

Apple's suggested fix, `activate(options:completionHandler:)`, is **watchOS
only** and does not exist on iOS — and it would not cover `setCategory`,
which is two of the three flagged call sites. Hence the queue.
"""

from __future__ import annotations

import pathlib

import pytest

from tests.swift_source import decl_body, strip_comments

REPO = pathlib.Path(__file__).resolve().parents[3]
VOICE_NAV = REPO / "TripperDashPP" / "App" / "VoiceNavigator.swift"

# Every function that touches the shared AVAudioSession.
SESSION_FUNCS = (
    "func startSession()",
    "func stopSession()",
    "private func duckOthers(_ duck: Bool)",
)

# The blocking calls themselves.
BLOCKING_CALLS = ("setCategory", "setActive")


@pytest.fixture(scope="module")
def src() -> str:
    return strip_comments(VOICE_NAV.read_text(encoding="utf-8"))


@pytest.fixture(scope="module")
def raw_src() -> str:
    return VOICE_NAV.read_text(encoding="utf-8")


def test_session_queue_exists_and_is_serial(src):
    """A serial DispatchQueue, not a concurrent one and not an actor.

    Ordering is load-bearing: duck-on/duck-off and activate/deactivate are
    pairs, and running them out of order leaves the rider's music
    permanently ducked or the session active after teardown. A serial queue
    is FIFO; `.concurrent` is not, and Swift actors make no ordering promise
    about tasks awaiting them.
    """
    assert "private let sessionQueue = DispatchQueue(" in src, (
        "VoiceNavigator must own a DispatchQueue for AVAudioSession work"
    )
    body = src[src.index("private let sessionQueue = DispatchQueue("):]
    body = body[: body.index(")")]
    assert "attributes: .concurrent" not in body, (
        "the audio session queue must stay serial — concurrent dispatch can "
        "reorder a duck-on/duck-off pair and leave music ducked forever"
    )


@pytest.mark.parametrize("anchor", SESSION_FUNCS)
def test_session_mutations_are_dispatched_off_the_main_thread(src, anchor):
    """Every AVAudioSession mutation must run inside sessionQueue.async."""
    body = decl_body(src, anchor)
    if not any(call in body for call in BLOCKING_CALLS):
        return  # nothing blocking here
    assert "sessionQueue.async {" in body, (
        f"{anchor} calls AVAudioSession synchronously on the main actor. "
        f"setCategory/setActive are blocking IPC to mediaserverd and cause "
        f"the 'AVAudioSession Hang Risk' diagnostic. Wrap them in "
        f"sessionQueue.async."
    )


@pytest.mark.parametrize("anchor", SESSION_FUNCS)
def test_no_blocking_call_escapes_the_queue(src, anchor):
    """The blocking calls must appear *after* the dispatch, never before it.

    Catches the half-fix where a queue is introduced but one call site is
    left on the main thread.
    """
    body = decl_body(src, anchor)
    for call in BLOCKING_CALLS:
        if call not in body:
            continue
        assert "sessionQueue.async {" in body, f"{anchor}: {call} not dispatched"
        assert body.index("sessionQueue.async {") < body.index(call), (
            f"{anchor} calls {call} before entering sessionQueue.async — it "
            f"is still running on the main thread."
        )


def test_voice_navigator_is_still_main_actor(raw_src):
    """The fix must not be 'move the whole class off the main actor'.

    VoiceNavigator drives AVSpeechSynthesizer and receives its delegate
    callbacks; those belong on the main actor. Only the session mutations
    were meant to move.
    """
    assert "@MainActor\nfinal class VoiceNavigator" in raw_src, (
        "VoiceNavigator must stay @MainActor — only the AVAudioSession calls "
        "belong off the main thread, not the synthesizer plumbing."
    )


def test_watchos_only_api_is_not_used(src):
    """`activate(options:completionHandler:)` does not exist on iOS.

    Xcode's diagnostic suggests it, but it is watchOS 5.0+ only. Using it
    would not compile for this target.
    """
    assert "activate(options:" not in src, (
        "activate(options:completionHandler:) is watchOS-only and unavailable "
        "on iOS, despite being what Xcode's hang-risk diagnostic suggests."
    )
