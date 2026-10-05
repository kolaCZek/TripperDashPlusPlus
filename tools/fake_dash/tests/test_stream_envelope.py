"""
The dash video stream follows the stock Royal Enfield app's shape.

Field report 10/2026: at 6 fps / 1024 kbps / a keyframe every 2 s / a burst
cap of 3x the average, the picture sometimes froze and broke into fragments
until the next keyframe repaired it, the signature of a lost RTP packet. The
stock app streams 4 fps, an IDR every 1 s, and caps bursts at the average
rate (better-dash `DASH_FPS` / `DASH_GOP_SEC`, ffmpeg `-maxrate` = `-b:v`).
We follow that shape at 512 kbps (2.5x its 204.8 kbps) to keep labels legible.

Swift-source guard: there is no Swift runtime on the CI Linux host, so this
pins the literals that make up the envelope.
"""

from __future__ import annotations

import re
from pathlib import Path

from tests.swift_source import strip_comments

_APP = Path(__file__).resolve().parents[3] / "TripperDashPP"


def _src(rel: str) -> str:
    return strip_comments((_APP / rel).read_text())


def _encoder_defaults() -> dict[str, int]:
    src = _src("Stream/H264Encoder.swift")
    init = src[src.index("    init(\n        width: Int32"):]
    init = init[: init.index(")")]
    return {k: int(v.replace("_", "")) for k, v in re.findall(r"(\w+): Int32 = ([\d_]+)", init)}


def test_frame_rate_is_four():
    assert "    let targetFps = 4\n" in _src("Map/MapViewSource.swift")
    # The streamer hands the source's rate to the encoder, not the default.
    assert "fps: Int32(source.targetFps)" in _src("Stream/RtpStreamer.swift")


def test_encoder_defaults():
    d = _encoder_defaults()
    assert d["bitrate"] == 512_000, d
    assert d["fps"] == 4, d


def test_keyframe_interval_follows_fps():
    """One IDR per second at whatever fps the source hands in: the GOP
    defaults to fps (not a literal that only matches 4 fps), and the
    duration is float division (Int32 4/5 == 0 = "no limit")."""
    src = _src("Stream/H264Encoder.swift")
    assert "keyframeInterval: Int32? = nil" in src
    assert "self.keyframeInterval = keyframeInterval ?? fps" in src
    assert "(kVTCompressionPropertyKey_MaxKeyFrameInterval, NSNumber(value: keyframeInterval))" in src
    assert (
        "(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, "
        "NSNumber(value: Double(keyframeInterval) / Double(fps)))"
    ) in src
    # The streamer must not pin a GOP of its own.
    rtp = _src("Stream/RtpStreamer.swift")
    assert "keyframeInterval" not in rtp


def test_no_burst_headroom_above_the_average_rate():
    src = _src("Stream/H264Encoder.swift")
    # bytes-per-second limit over a 1 s window == the average bitrate / 8
    assert (
        "(kVTCompressionPropertyKey_DataRateLimits, "
        "[NSNumber(value: bitrate / 8), NSNumber(value: 1)] as CFArray)"
    ) in src
    assert "bitrate / 8 *" not in src, "burst multiplier is back"


def test_per_frame_lerps_match_target_fps():
    """The heading / zoom / zoom-bias-revert lerps are per frame. Their
    per-second effect (1 - (1 - f) ** fps) must stay what it was tuned to
    at 6 fps, so a future fps change can't silently speed up or slow down
    the map's turning and zooming."""
    src = _src("Map/MapViewSource.swift")
    fps = int(re.search(r"let targetFps = (\d+)", src).group(1))
    heading = float(re.search(r"private func updateHeading\(\) \{\s*let factor: Double = ([\d.]+)", src).group(1))
    zin, zout = map(float, re.search(r"zoomingIn \? ([\d.]+) : ([\d.]+)", src).groups())
    revert = float(re.search(r"zoomBiasRevertFactor: CGFloat = ([\d.]+)", src).group(1))
    per_s = lambda f: 1 - (1 - f) ** fps
    tuned = lambda f: 1 - (1 - f) ** 6  # the 6-fps originals
    for name, f, orig in [("heading", heading, 0.15), ("zoom in", zin, 0.15),
                          ("zoom out", zout, 0.05), ("bias revert", revert, 0.04)]:
        assert abs(per_s(f) - tuned(orig)) <= 0.03 * tuned(orig), (name, f, fps)
    # The Python zoom-bias mirror must carry the same constant.
    from tests.zoom_bias_mirror import ZOOM_BIAS_REVERT_FACTOR
    assert ZOOM_BIAS_REVERT_FACTOR == revert


def test_frame_budget_is_smaller_than_before():
    """Average coded frame at 512 kbps / 4 fps vs the old 1024 / 6, in
    1200-byte RTP packets (RtpPacketizer default)."""
    d = _encoder_defaults()
    pkts = lambda bps, fps: bps / 8 / fps / 1200
    assert pkts(d["bitrate"], d["fps"]) < pkts(1_024_000, 6)
    assert round(pkts(d["bitrate"], d["fps"])) == 13
