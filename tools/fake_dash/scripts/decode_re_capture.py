#!/usr/bin/env python3
"""
decode_re_capture.py — pull the K1G nav fields out of a Royal Enfield
phone<->dash packet capture, with ZERO third-party deps (no scapy/dpkt).

WHY THIS EXISTS
---------------
When you sniff the *official* RE app talking to the Tripper dash (e.g. on a
Mac:  rvictl -s <iPhone-UDID>  then
      sudo tcpdump -i rvi0 -w re.pcap 'udp and (port 2000 or port 2002 or port 5000)'
)
you get a pcap full of K1G control packets. This tool decodes them and, most
importantly, HIGHLIGHTS the two bytes we still don't have ground truth for:

  * 05 54  — the ETA-format byte. 0x30 = 24h (the only value we've proven the
             dash accepts). We need to see what the OFFICIAL app puts here when
             the phone/app is switched to 12-hour mode. If it's NOT 0x30, that's
             the real 12h render byte; if it IS 0x30, the dash genuinely can't
             do AM/PM and the app just sends 24h.
  * 05 0C  — the undecoded "extra counter"/bottom-row selector suspect. We need
             to see if/how this changes when the official app's bubble bottom
             row is switched between ETA and distance-to-destination.

It also dumps every other 05 xx active-nav TLV (08 ETA, 09 total-dist,
0B remaining-time, 06/46 unit bytes, 0A decimal-sep) so you get the whole
active-nav picture per packet.

USAGE
-----
    python3 decode_re_capture.py re.pcap
    python3 decode_re_capture.py re.pcap --ports 2000,2002
    python3 decode_re_capture.py re.pcap --only-nav   # only packets with a 05 xx TLV
    python3 decode_re_capture.py re.pcap --watch 0554,050C   # highlight these, diff over time

Supports classic pcap (both byte orders) and the common pcapng shape that
`tcpdump -w` / Wireshark export. Link layer is auto-detected per packet by
scanning for the IPv4/IPv6 header, so it works for Ethernet, raw-IP (rvi0),
BSD-loopback and PKTAP captures without you telling it which.
"""

from __future__ import annotations

import argparse
import struct
import sys
from pathlib import Path

# Reuse the project's proven K1G splitter so we decode segments exactly the
# way fake_dash / the Swift app do — single source of truth.
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
try:
    from fake_dash.protocol import decode_packet  # type: ignore
except Exception:  # pragma: no cover - fallback if run outside the tree
    decode_packet = None  # type: ignore


# --- human labels for the active-nav 05 xx TLVs -----------------------------
NAV_SUB_LABELS = {
    0x06: "primary-unit",
    0x08: "ETA (HH:MM)",
    0x09: "total-distance",
    0x0A: "decimal-separator",
    0x0B: "remaining-time (DDHHMM)",
    0x0C: "extra/bottom-row? (UNDECODED)",
    0x46: "total-unit",
    0x54: "ETA-format flag",
}

# Bytes we care most about, as 4-hex-digit type+sub keys.
DEFAULT_WATCH = {"0554", "050C"}


def _color(s: str, code: str) -> str:
    if not sys.stdout.isatty():
        return s
    return f"\033[{code}m{s}\033[0m"


# ---------------------------------------------------------------------------
# Minimal pcap / pcapng reader (no deps)
# ---------------------------------------------------------------------------
def iter_raw_packets(raw: bytes):
    """Yield link-layer frame payloads from a classic-pcap or pcapng blob."""
    if len(raw) < 4:
        return
    magic = raw[:4]
    if magic in (b"\xd4\xc3\xb2\xa1", b"\xa1\xb2\xc3\xd4"):
        yield from _iter_classic_pcap(raw)
    elif magic == b"\x0a\x0d\x0d\x0a":
        yield from _iter_pcapng(raw)
    else:
        raise ValueError(
            f"unrecognized capture magic {magic.hex()} — not classic pcap or pcapng"
        )


def _iter_classic_pcap(raw: bytes):
    le = raw[:4] == b"\xd4\xc3\xb2\xa1"
    end = "<" if le else ">"
    # global header is 24 bytes; snaplen/linktype we don't strictly need
    off = 24
    rec = struct.Struct(end + "IIII")
    while off + 16 <= len(raw):
        ts_sec, ts_usec, caplen, origlen = rec.unpack_from(raw, off)
        off += 16
        if caplen == 0 or off + caplen > len(raw):
            break
        yield raw[off : off + caplen]
        off += caplen


def _iter_pcapng(raw: bytes):
    off = 0
    end = "<"  # refined from the section header's byte-order magic below
    while off + 12 <= len(raw):
        btype = struct.unpack_from(end + "I", raw, off)[0]
        # The Section Header Block type 0x0A0D0D0A is byte-order invariant, so
        # we can recognize it before we know the endianness. Read its BOM and
        # lock `end` BEFORE trusting any length field.
        if btype == 0x0A0D0D0A:
            bom = raw[off + 8 : off + 12]
            # 0x1A2B3C4D on the wire: big-endian file => bytes 1a 2b 3c 4d,
            # little-endian file => bytes 4d 3c 2b 1a.
            if bom == b"\x1a\x2b\x3c\x4d":
                end = ">"
            elif bom == b"\x4d\x3c\x2b\x1a":
                end = "<"
            # else: leave previous endianness (defensive)
        blen = struct.unpack_from(end + "I", raw, off + 4)[0]
        if blen < 12 or off + blen > len(raw):
            break
        body = raw[off + 8 : off + blen - 4]
        if btype == 0x00000006:  # Enhanced Packet Block
            # body: iface_id(4) ts_hi(4) ts_lo(4) caplen(4) origlen(4) data...
            if len(body) >= 20:
                caplen = struct.unpack_from(end + "I", body, 12)[0]
                yield body[20 : 20 + caplen]
        elif btype == 0x00000003:  # Simple Packet Block
            if len(body) >= 4:
                origlen = struct.unpack_from(end + "I", body, 0)[0]
                yield body[4 : 4 + origlen]
        off += blen


# ---------------------------------------------------------------------------
# Find the IP header regardless of link layer, then carve UDP
# ---------------------------------------------------------------------------
def extract_udp(frame: bytes):
    """Return (src_port, dst_port, udp_payload) or None.

    Auto-detects the link-layer offset by scanning the first handful of bytes
    for a plausible IPv4 header (version 4, sane IHL, protocol 17 = UDP). This
    transparently handles Ethernet (14B), raw IP (0B, rvi0), BSD loopback (4B)
    and PKTAP without needing the pcap link-type.
    """
    for base in (0, 14, 4, 16, 2, 108):  # common L2 header sizes + PKTAP
        if base >= len(frame):
            continue
        b0 = frame[base]
        ver = b0 >> 4
        if ver == 4:
            ihl = (b0 & 0x0F) * 4
            if ihl < 20 or base + ihl + 8 > len(frame):
                continue
            proto = frame[base + 9]
            if proto != 17:  # UDP
                continue
            ip_total = struct.unpack_from(">H", frame, base + 2)[0]
            udp_off = base + ihl
            sport, dport, ulen = struct.unpack_from(">HHH", frame, udp_off)
            payload = frame[udp_off + 8 : base + ip_total]
            if not payload:
                payload = frame[udp_off + 8 : udp_off + ulen]
            return sport, dport, payload
    return None


# ---------------------------------------------------------------------------
# Decode + report
# ---------------------------------------------------------------------------
def segment_key(seg) -> str:
    return f"{seg.type:02X}{seg.sub:02X}"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("pcap", help="path to .pcap / .pcapng")
    ap.add_argument(
        "--ports",
        default="2000,2002,5000",
        help="comma-separated UDP ports to keep (default: K1G + RTP)",
    )
    ap.add_argument(
        "--only-nav",
        action="store_true",
        help="only show packets that carry at least one 05 xx active-nav TLV",
    )
    ap.add_argument(
        "--watch",
        default=",".join(sorted(DEFAULT_WATCH)),
        help="comma-separated type+sub hex keys to highlight & track changes "
        "(default: 0554,050C — the 12h byte and the bottom-row suspect)",
    )
    args = ap.parse_args()

    if decode_packet is None:
        print(
            "ERROR: could not import fake_dash.protocol.decode_packet — run this "
            "from inside tools/fake_dash/scripts/ in the TripperDashPlusPlus tree.",
            file=sys.stderr,
        )
        return 2

    keep_ports = {int(p) for p in args.ports.split(",") if p.strip()}
    watch = {w.strip().upper() for w in args.watch.split(",") if w.strip()}

    raw = Path(args.pcap).read_bytes()
    last_watch_val: dict[str, str] = {}

    n_total = n_udp = n_k1g = n_nav = 0
    for frame in iter_raw_packets(raw):
        n_total += 1
        got = extract_udp(frame)
        if got is None:
            continue
        sport, dport, payload = got
        if keep_ports and sport not in keep_ports and dport not in keep_ports:
            continue
        n_udp += 1

        segs = decode_packet(payload)
        if not segs:
            continue
        n_k1g += 1

        nav_segs = [s for s in segs if s.type == 0x05]
        if args.only_nav and not nav_segs:
            continue
        if nav_segs:
            n_nav += 1

        dir_label = f"{sport}->{dport}"
        print(_color(f"\n# K1G packet  {dir_label}  ({len(payload)} B)", "1;36"))
        for s in segs:
            key = segment_key(s)
            label = NAV_SUB_LABELS.get(s.sub, "") if s.type == 0x05 else ""
            line = f"  {s.type:02X} {s.sub:02X}  len={len(s.payload):>3}  {s.payload.hex().upper()}"
            if label:
                line += f"   {label}"
            if key in watch:
                # Track whether this watched field changed since last seen.
                cur = s.payload.hex().upper()
                changed = key in last_watch_val and last_watch_val[key] != cur
                last_watch_val[key] = cur
                tag = "  <<< CHANGED" if changed else "  <<< WATCH"
                print(_color(line + tag, "1;33"))
            else:
                print(line)

    print(_color("\n=== summary ===", "1;32"))
    print(f"frames read:        {n_total}")
    print(f"UDP on {sorted(keep_ports)}: {n_udp}")
    print(f"valid K1G packets:  {n_k1g}")
    print(f"with 05 xx nav TLV: {n_nav}")
    if last_watch_val:
        print("\nlast value of watched fields:")
        for k, v in sorted(last_watch_val.items()):
            lbl = NAV_SUB_LABELS.get(int(k[2:], 16), "") if k.startswith("05") else ""
            print(f"  {k[:2]} {k[2:]}  = {v}   {lbl}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
