"""
Nav-info TLV sniffer — decode & diff the phone's `0x05` active-nav fields.

The active-nav packet the phone streams to the dash is a family of
`05 <sub> <len_BE> <payload>` TLV fields (see `TripperDashPP/Tripper/
K1GPacket.swift`, `tlv*` builders). They are **plaintext** — only the
initial session-key handshake is RSA-encrypted — so the emulator can read
every field directly off the wire.

Two of the phone's user settings currently have NO confirmed wire effect:

  * **12/24-hour ETA format** — `tlvEtaFormat` always emits `05 54 0001 30`
    regardless of the toggle (`0x31` was field-confirmed to blank the dash).
  * **Bubble bottom row (ETA vs distance)** — no longer gated on the wire;
    the phone sends ETA + total-distance + remaining-time every tick and the
    dash picks which to show (dash-side, byte unknown — likely `05 0C`).

To learn the real bytes we point the **original Royal Enfield app** at this
emulator, capture the nav-info fields, flip the toggle in the OEM app, and
diff the two snapshots. Whatever field changes IS the control byte.

This module provides:
  * ``FIELD_CATALOG`` — (type, sub) → human label, from the Swift builders.
  * ``describe_field`` — pretty one-line dump of a single nav-info segment.
  * ``NavSnapshot`` — the latest value of every nav-info field seen from a
    peer, with ``diff`` to compare two snapshots field-by-field.

It is import-only side-effect-free; ``server.py`` calls into it when the
``--sniff`` flag (or ``FAKE_DASH_SNIFF``) is set.
"""

from __future__ import annotations

from dataclasses import dataclass, field

# ---------------------------------------------------------------------------
# Field catalog — mirror of TripperDashPP/Tripper/K1GPacket.swift `tlv*`.
# Key is (type, sub); type 0x05 = navInfo, 0x06 = status. Value is a short
# human label. Keep in sync with the Swift builders when they change (the
# repo's docs-in-lockstep rule applies here too).
# ---------------------------------------------------------------------------
FIELD_CATALOG: dict[tuple[int, int], str] = {
    (0x05, 0x02): "primaryManeuver (turn glyph)",
    (0x05, 0x04): "primaryDistance (m, u16 BE)",
    (0x05, 0x06): "primaryUnit",
    (0x05, 0x03): "secondaryManeuver (code+flags)",
    (0x05, 0x05): "secondaryDistance (m, u16 BE)",
    (0x05, 0x07): "secondaryUnit",
    (0x05, 0x09): "totalDistance (m, u16 BE)",
    (0x05, 0x46): "totalDistanceUnit",
    (0x05, 0x0A): "decimalSeparator (0x55='.' 0xAA=',')",
    (0x05, 0x08): "eta (ascii HHMM, 24h)",
    (0x05, 0x54): "etaFormat (**suspected 12/24h byte**)",
    (0x05, 0x0B): "remainingTime (ascii DDHHMM)",
    (0x05, 0x55): "remainingUnit",
    (0x05, 0x0C): "**UNDECODED — suspected bottom-row selector**",
    (0x05, 0x4C): "volume/mute baseline (Q3C_N1)",
    (0x05, 0x22): "roadName / hostname",
    (0x06, 0x05): "projectionFlag (on/off)",
    (0x06, 0x0D): "decimalFlag (on/off)",
}

# Fields whose payload is printable ASCII — render as text alongside hex.
_ASCII_SUBS = {0x08, 0x0B, 0x22}


def _payload_repr(sub: int, payload: bytes) -> str:
    """Best-effort human rendering of a payload: hex, plus ascii/int hints."""
    hexs = payload.hex().upper() or "(empty)"
    extra = ""
    if sub in _ASCII_SUBS:
        try:
            txt = payload.decode("ascii")
            if txt.isprintable():
                extra = f'  ascii="{txt}"'
        except UnicodeDecodeError:
            pass
    elif len(payload) == 1:
        extra = f"  u8={payload[0]}"
    elif len(payload) == 2:
        extra = f"  u16={int.from_bytes(payload, 'big')}"
    return f"{hexs}{extra}"


def describe_field(seg_type: int, sub: int, payload: bytes) -> str:
    """One-line human description of a nav-info/status segment."""
    label = FIELD_CATALOG.get((seg_type, sub), "unknown field")
    return f"{seg_type:02X} {sub:02X}  {label:<44} {_payload_repr(sub, payload)}"


@dataclass
class NavSnapshot:
    """
    Latest value of every nav-info/status field seen from one peer.

    Keyed by (type, sub) so a re-sent field overwrites the previous value —
    a snapshot therefore always holds the *current* wire state, which is
    exactly what we diff across an OEM-app toggle flip.
    """

    fields: dict[tuple[int, int], bytes] = field(default_factory=dict)
    packets_seen: int = 0

    def observe(self, seg_type: int, sub: int, payload: bytes) -> bool:
        """
        Record a field. Returns True if the value is NEW or CHANGED vs what
        we last saw for this (type, sub) — the caller can log only changes.
        """
        key = (seg_type, sub)
        changed = self.fields.get(key) != payload
        self.fields[key] = payload
        return changed

    def mark_packet(self) -> None:
        self.packets_seen += 1

    def copy(self) -> "NavSnapshot":
        return NavSnapshot(fields=dict(self.fields), packets_seen=self.packets_seen)

    def diff(self, other: "NavSnapshot") -> list[str]:
        """
        Human-readable field-by-field diff: what changed going from `self`
        (the baseline) to `other` (after the toggle flip). Lists added,
        removed, and changed fields — added/changed are the interesting ones.
        """
        lines: list[str] = []
        keys = sorted(set(self.fields) | set(other.fields))
        for key in keys:
            a = self.fields.get(key)
            b = other.fields.get(key)
            if a == b:
                continue
            t, s = key
            label = FIELD_CATALOG.get(key, "unknown field")
            if a is None:
                assert b is not None
                lines.append(f"  + ADDED   {t:02X} {s:02X} {label}: {b.hex().upper()}")
            elif b is None:
                lines.append(f"  - REMOVED {t:02X} {s:02X} {label}: {a.hex().upper()}")
            else:
                lines.append(
                    f"  ~ CHANGED {t:02X} {s:02X} {label}: "
                    f"{a.hex().upper()} -> {b.hex().upper()}"
                )
        return lines
