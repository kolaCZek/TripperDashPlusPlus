"""
Pure-Python mirror of MapViewSource's manual zoom-bias math (dash LEFT/
RIGHT buttons). Lets us unit-test the bias/clamp/auto-revert behaviour
without an Xcode/iOS runtime.

Keep in lock-step with `TripperDashPP/Map/MapViewSource.swift`:
  - `applyZoomButton(zoomIn:)`  → `nudge(zoom_in)`
  - `decayZoomBias()`           → `decay(now)`
  - `targetZoom` bias factor    → `effective_target(auto_zoom)`

Constants MUST match the Swift `let`s exactly.
"""

from __future__ import annotations

from dataclasses import dataclass, field

# --- Constants mirrored from MapViewSource.swift ------------------------
ZOOM_BIAS_STEP = 1.15
ZOOM_BIAS_MIN = 0.5
ZOOM_BIAS_MAX = 2.5
ZOOM_BIAS_HOLD_SECONDS = 15.0
ZOOM_BIAS_REVERT_FACTOR = 0.04
# Autozoom clamps the raw speed curve to this band before the bias is
# applied (targetZoom: `min(max(raw, 0.8), 2.0)`).
SPEED_ZOOM_MIN = 0.8
SPEED_ZOOM_MAX = 2.0


def _clamp(v: float, lo: float, hi: float) -> float:
    return min(max(v, lo), hi)


@dataclass
class ZoomBias:
    """Mirror of the userZoomBias state machine."""

    bias: float = 1.0
    last_nudge: float | None = None  # monotonic seconds, None = neutral/idle

    def nudge(self, zoom_in: bool, now: float) -> None:
        """RIGHT (zoom_in=True) multiplies the bias up, LEFT divides it
        down; result is clamped and the auto-revert timer is reset."""
        factor = ZOOM_BIAS_STEP if zoom_in else 1.0 / ZOOM_BIAS_STEP
        self.bias = _clamp(self.bias * factor, ZOOM_BIAS_MIN, ZOOM_BIAS_MAX)
        self.last_nudge = now

    def decay(self, now: float) -> None:
        """Ease the bias back toward 1.0 once the hold window elapses.
        No-op while still holding or already neutral."""
        if self.last_nudge is None:
            return
        if now - self.last_nudge < ZOOM_BIAS_HOLD_SECONDS:
            return
        if abs(self.bias - 1.0) < 0.01:
            self.bias = 1.0
            self.last_nudge = None
            return
        self.bias += (1.0 - self.bias) * ZOOM_BIAS_REVERT_FACTOR

    def effective_target(self, auto_zoom: float, maneuver_boost: float = 1.0) -> float:
        """The zoom target the map actually lerps toward: the clamped
        speed zoom × maneuver boost × the manual bias."""
        speed_zoom = _clamp(auto_zoom, SPEED_ZOOM_MIN, SPEED_ZOOM_MAX)
        return speed_zoom * maneuver_boost * self.bias
