#!/usr/bin/env python3
"""
Convert a GPX track/route into an Xcode location-simulation GPX.

WHY THIS EXISTS
---------------
Xcode's "Simulate Location" (scheme > Run > Options > Default Location,
or Debug > Simulate Location) plays back a GPX file so the app receives a
moving stream of CLLocation fixes. But Xcode reads ONLY `<wpt>` elements
— a file built from `<trk>/<trkpt>` (what Kurviger, Komoot, Garmin and
most planners export) is silently ignored or treated as empty.

Xcode paces the playback from the `<time>` deltas between consecutive
waypoints: it interpolates fixes over exactly that wall-clock gap. So the
riding SPEED is set purely by how we stamp the times.

This converter therefore does two things:
  1. `<trkpt>`/`<rtept>` -> `<wpt>` (the format Xcode accepts)
  2. re-stamps `<time>` for a chosen constant speed, so a 52 km route can
     be ridden in the simulator in a couple of minutes instead of an hour

USAGE
-----
    python3 tools/gpx_to_xcode_sim.py IN.gpx OUT.gpx --kmh 50
    python3 tools/gpx_to_xcode_sim.py IN.gpx OUT.gpx --kmh 50 --densify 25

`--densify N` inserts interpolated points so consecutive fixes are at most
N metres apart. Worth doing: a planner's track can have 300 m gaps between
vertices, and `ActiveNavigator` decides `nearestSegment` / `nextStepIndex`
per fix — sparse fixes make the rider "teleport" past a maneuver node and
mask exactly the kind of per-fix bug this file was written to reproduce.

Then in Xcode: add the output file to the project, Product > Scheme >
Edit Scheme > Run > Options > Default Location > pick it.
"""

from __future__ import annotations

import argparse
import math
import sys
import xml.etree.ElementTree as ET
from datetime import datetime, timedelta, timezone
from pathlib import Path

EARTH_R = 6_371_000.0


def haversine(a: tuple[float, float], b: tuple[float, float]) -> float:
    lat1, lat2 = math.radians(a[0]), math.radians(b[0])
    dlat = math.radians(b[0] - a[0])
    dlon = math.radians(b[1] - a[1])
    h = (math.sin(dlat / 2) ** 2
         + math.cos(lat1) * math.cos(lat2) * math.sin(dlon / 2) ** 2)
    return 2 * EARTH_R * math.asin(min(1.0, math.sqrt(h)))


def read_points(path: Path) -> list[tuple[float, float]]:
    """The track/route geometry: every trkpt + rtept in document order.

    Standalone <wpt> are only used when the file has no track or route —
    in a planner export they are POIs (fuel, cafe, …), and splicing them into
    the geometry would add phantom legs across the map.
    """
    root = ET.parse(path).getroot()
    # Namespace-agnostic: GPX 1.0 and 1.1 use different namespace URIs and
    # some exporters emit none at all.
    by_tag: dict[str, list[tuple[float, float]]] = {"line": [], "wpt": []}
    for el in root.iter():
        tag = el.tag.rsplit("}", 1)[-1]
        if tag in ("trkpt", "rtept", "wpt"):
            lat, lon = el.get("lat"), el.get("lon")
            if lat is None or lon is None:
                continue
            try:
                p = (float(lat), float(lon))
            except ValueError:
                continue
            by_tag["wpt" if tag == "wpt" else "line"].append(p)
    return by_tag["line"] or by_tag["wpt"]


def densify(pts: list[tuple[float, float]],
            max_gap_m: float) -> list[tuple[float, float]]:
    """Linearly interpolate so no two consecutive points exceed max_gap_m."""
    if max_gap_m <= 0 or len(pts) < 2:
        return pts
    out: list[tuple[float, float]] = [pts[0]]
    for a, b in zip(pts, pts[1:]):
        d = haversine(a, b)
        n = int(d // max_gap_m)
        for i in range(1, n + 1):
            t = i / (n + 1)
            out.append((a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t))
        out.append(b)
    return out


def build(pts: list[tuple[float, float]], kmh: float,
          start: datetime) -> str:
    """Emit an Xcode-compatible GPX: <wpt> only, timestamps pacing speed."""
    mps = kmh / 3.6
    lines = [
        '<?xml version="1.0" encoding="UTF-8"?>',
        '<gpx version="1.1" creator="TripperDashPP gpx_to_xcode_sim">',
        '',  # summary comment, filled in below
        '  <!-- Xcode reads <wpt> ONLY; <trk>/<trkpt> is ignored. -->',
    ]
    # Xcode only takes whole-second <time> values and wants them strictly
    # increasing. Points closer than ~1 s of travel (tight --densify, or a
    # dense track) would share a stamp, so a later point in the same second
    # REPLACES the earlier one. Rounding the cumulative time keeps each fix
    # within 0.5 s of ideal and the average speed exact.
    # ponytail: per-gap speed still jitters by up to 1 s per gap (Xcode's
    # whole-second limit); keep --densify at >= ~2 s of travel to damp it.
    elapsed = 0.0
    prev: tuple[float, float] | None = None
    last_stamp = ""
    for p in pts:
        if prev is not None:
            elapsed += haversine(prev, p) / mps
        stamp = (start + timedelta(seconds=round(elapsed))).strftime("%Y-%m-%dT%H:%M:%SZ")
        line = f'  <wpt lat="{p[0]:.6f}" lon="{p[1]:.6f}"><time>{stamp}</time></wpt>'
        if stamp == last_stamp:
            lines[-1] = line
        else:
            lines.append(line)
        last_stamp = stamp
        prev = p
    lines[2] = f'  <!-- {len(lines) - 4} waypoints, constant {kmh:g} km/h -->'
    lines.append('</gpx>')
    return "\n".join(lines) + "\n"


def _positive(s: str) -> float:
    v = float(s)
    if not v > 0:
        raise argparse.ArgumentTypeError(f"must be > 0, got {s}")
    return v


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("input", type=Path)
    ap.add_argument("output", type=Path)
    ap.add_argument("--kmh", type=_positive, default=50.0,
                    help="constant playback speed (default 50)")
    ap.add_argument("--densify", type=float, default=0.0, metavar="METRES",
                    help="insert points so gaps are at most this far apart")
    args = ap.parse_args(argv)

    pts = read_points(args.input)
    if len(pts) < 2:
        print(f"error: {args.input} has {len(pts)} usable points", file=sys.stderr)
        return 1

    raw_len = sum(haversine(a, b) for a, b in zip(pts, pts[1:]))
    pts = densify(pts, args.densify)

    start = datetime(2026, 1, 1, 9, 0, 0, tzinfo=timezone.utc)
    out = build(pts, args.kmh, start)
    args.output.write_text(out, encoding="utf-8")

    ride_s = raw_len / (args.kmh / 3.6)
    print(f"{args.input.name}: {raw_len/1000:.1f} km")
    print(f"  -> {args.output} : {out.count('<wpt ')} <wpt> points at {args.kmh:g} km/h")
    print(f"  -> simulated ride time {ride_s/60:.1f} min")
    if args.densify:
        print(f"  -> densified to <= {args.densify:g} m between fixes")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
