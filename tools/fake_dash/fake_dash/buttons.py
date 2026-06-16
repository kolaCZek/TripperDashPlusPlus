"""
Joystick button emulation — bike → phone.

Real Trippers have a 4-way joystick (LEFT / RIGHT / DOWN / CLICK).
Pressing a button sends a K1G segment of type=0x09 sub=0x00 with payload
`00 01 XX` where XX is the button code (better-dash/dash_ui/bike_link.py
lines 80-103).

This module exposes:
  - `Button` enum mirroring the four codes
  - `build_button_packet(button, seq)` producing the wire bytes ready
    for `sock.sendto`
  - a tiny CLI entry point so `docker compose exec fake_dash python -m
    fake_dash button --left` injects events into a running server's RX
    socket via loopback (the server forwards to all known phone peers).
"""

from __future__ import annotations

import enum

from .protocol import Segment, build_envelope


class Button(enum.IntEnum):
    """Wire codes the bike sends inside a `09 00 0001 XX` segment."""

    RIGHT = 0x13
    LEFT = 0x14
    DOWN = 0x15
    CLICK = 0x18

    @classmethod
    def from_name(cls, name: str) -> "Button":
        try:
            return cls[name.upper()]
        except KeyError as exc:  # pragma: no cover — CLI validation handles this
            valid = ", ".join(b.name for b in cls)
            raise ValueError(f"unknown button {name!r}; valid: {valid}") from exc


def build_button_segment(button: Button) -> Segment:
    """Build the inner `09 00` TLV. Payload is `00 01 XX`."""
    return Segment(
        type=0x09,
        sub=0x00,
        payload=bytes([0x00, 0x01, int(button) & 0xFF]),
    )


def build_button_packet(button: Button, seq: int = 0) -> bytes:
    """Wrap a button segment in a complete K1G envelope ready to send."""
    return build_envelope([build_button_segment(button)], seq=seq)
