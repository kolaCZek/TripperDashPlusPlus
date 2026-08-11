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
    """Wire codes the bike sends inside a `09 00 0001 XX` segment.

    The dash sends CONTEXT-DEPENDENT codes, not raw stick directions — the
    same physical stick emits different codes depending on which dash
    screen is up. All confirmed from on-bike captures 2026-08-11
    (btn-*.jsonl):
      Map screen:        RIGHT 0x13 / LEFT 0x14 / DOWN 0x15 / CLICK 0x18
      Now-playing:       PREV_TRACK 0x0a / NEXT_TRACK 0x09
      In-menu:           REMOVE_WAYPOINT 0x20 / EXIT_NAV 0x12
    """

    RIGHT = 0x13
    LEFT = 0x14
    DOWN = 0x15
    CLICK = 0x18
    # Now-playing screen (same left/right stick, different codes).
    NEXT_TRACK = 0x09
    PREV_TRACK = 0x0A
    # In-menu actions.
    REMOVE_WAYPOINT = 0x20
    EXIT_NAV = 0x12

    @classmethod
    def from_name(cls, name: str) -> "Button":
        try:
            return cls[name.upper()]
        except KeyError as exc:  # pragma: no cover — CLI validation handles this
            valid = ", ".join(b.name for b in cls)
            raise ValueError(f"unknown button {name!r}; valid: {valid}") from exc


def build_button_segment(button: Button) -> Segment:
    """Build the inner `09 00` TLV.

    The real dash sends `09 00 0001 XX`: type=0x09, sub=0x00, a 2-byte
    TLV length field of 0x0001, and a SINGLE payload byte XX (the button
    code). Confirmed against an on-bike wire capture (2026-08-11): every
    press is a 13-byte packet ending `...0900 0001 XX`.

    The `00 01` in the better-dash notation is the TLV LENGTH field, not
    payload data — `Segment.hex` emits `len(payload)` as that field, so
    the payload here must be just the one code byte. (The earlier
    `[0x00, 0x01, XX]` payload double-encoded the length as data, making
    the harness emit `0900 0003 0001XX` — a shape the real dash never
    sends, which is exactly why the phone's decoder passed tests yet
    dropped every real button.)
    """
    return Segment(
        type=0x09,
        sub=0x00,
        payload=bytes([int(button) & 0xFF]),
    )


def build_button_packet(button: Button, seq: int = 0) -> bytes:
    """Wrap a button segment in a complete K1G envelope ready to send."""
    return build_envelope([build_button_segment(button)], seq=seq)


def build_button_ack_segment(code: int) -> Segment:
    """Mirror of Swift `K1GPacket.makeButtonAck`: the phone echoes each
    joystick event back as a `06 80 0001 XX` status segment with the SAME
    trailing byte, otherwise some firmwares stop emitting further events."""
    return Segment(type=0x06, sub=0x80, payload=bytes([code & 0xFF]))


def build_button_ack_packet(code: int, seq: int = 0) -> bytes:
    """Wrap a button ack segment in a complete K1G envelope."""
    return build_envelope([build_button_ack_segment(code)], seq=seq)

