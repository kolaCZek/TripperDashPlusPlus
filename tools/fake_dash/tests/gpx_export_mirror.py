"""
Python mirror of GPX EXPORT serialisation (`GPXExporter.swift`).

The Swift `GPXExporter` builds a GPX 1.1 `<trk>` document from a recorded
ride (`RideStats.trackPoints`). This module reproduces the exact string-
building rules so the writer is pinned without booting Xcode — the same
approach `gpx_geometry_mirror.py` takes for the IMPORT side.

What is mirrored 1:1 (keep in sync with GPXExporter.swift):
  - element structure: <gpx><metadata><name><time>… <trk><name><trkseg>
    <trkpt lat lon><ele><time>[<extensions><gpxtpx:speed>]…
  - coordinate precision (7 dp), elevation (1 dp), speed (2 dp), all with
    a '.' decimal separator (locale-independent — GPX is machine-read)
  - ISO-8601 UTC timestamps ("…Z")
  - speed only emitted when >= 0 (Doppler "unknown" == -1 is dropped)
  - XML escaping of the track name
  - default track name + filesystem-safe base name slug
  - the round-trip contract: a document this writer emits re-imports via
    the IMPORT mirror as a `.track` with the same coordinates.

Keep in sync with GPXExporter.swift.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Optional

COORDINATE_PRECISION = 7
ELEVATION_PRECISION = 1
SPEED_PRECISION = 2


@dataclass
class TrackPoint:
    """Mirror of RideStats.TrackPoint."""
    latitude: float
    longitude: float
    altitude: float
    timestamp: datetime           # tz-aware; serialised as UTC "…Z"
    speed_mps: float              # -1 == unknown


def _iso(ts: datetime) -> str:
    """ISO-8601 UTC with a trailing Z, matching ISO8601DateFormatter
    `.withInternetDateTime`. Seconds resolution, no fractional part."""
    return ts.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _fixed(value: float, places: int) -> str:
    return f"{value:.{places}f}"


def escape(s: str) -> str:
    out = s
    out = out.replace("&", "&amp;")
    out = out.replace("<", "&lt;")
    out = out.replace(">", "&gt;")
    out = out.replace('"', "&quot;")
    out = out.replace("'", "&apos;")
    return out


def _trkpt(p: TrackPoint) -> str:
    lat = _fixed(p.latitude, COORDINATE_PRECISION)
    lon = _fixed(p.longitude, COORDINATE_PRECISION)
    s = f'      <trkpt lat="{lat}" lon="{lon}">\n'
    s += f"        <ele>{_fixed(p.altitude, ELEVATION_PRECISION)}</ele>\n"
    s += f"        <time>{_iso(p.timestamp)}</time>\n"
    if p.speed_mps >= 0:
        s += "        <extensions>\n"
        s += "          <gpxtpx:TrackPointExtension>\n"
        s += f"            <gpxtpx:speed>{_fixed(p.speed_mps, SPEED_PRECISION)}</gpxtpx:speed>\n"
        s += "          </gpxtpx:TrackPointExtension>\n"
        s += "        </extensions>\n"
    s += "      </trkpt>\n"
    return s


def gpx(points: list[TrackPoint], track_name: str) -> Optional[str]:
    """Mirror of GPXExporter.gpx(points:trackName:). None for empty."""
    if not points:
        return None
    xml = ""
    xml += '<?xml version="1.0" encoding="UTF-8"?>\n'
    xml += '<gpx version="1.1" creator="TripperDashPP" '
    xml += 'xmlns="http://www.topografix.com/GPX/1/1" '
    xml += 'xmlns:gpxtpx="http://www.garmin.com/xmlschemas/TrackPointExtension/v1">\n'
    xml += "  <metadata>\n"
    xml += f"    <name>{escape(track_name)}</name>\n"
    xml += f"    <time>{_iso(points[0].timestamp)}</time>\n"
    xml += "  </metadata>\n"
    xml += "  <trk>\n"
    xml += f"    <name>{escape(track_name)}</name>\n"
    xml += "    <trkseg>\n"
    for p in points:
        xml += _trkpt(p)
    xml += "    </trkseg>\n"
    xml += "  </trk>\n"
    xml += "</gpx>\n"
    return xml


def default_track_name(start: Optional[datetime], now: Optional[datetime] = None) -> str:
    """Mirror of GPXExporter.defaultTrackName. Local-time 'Ride yyyy-MM-dd HH:mm'."""
    when = start or now or datetime.now()
    return "Ride " + when.strftime("%Y-%m-%d %H:%M")


def file_base_name(track_name: str) -> str:
    """Mirror of GPXExporter.fileBaseName: spaces→'-', strip ':' , keep
    [A-Za-z0-9-_]; empty → 'ride'."""
    collapsed = track_name.replace(" ", "-").replace(":", "")
    name = re.sub(r"[^A-Za-z0-9\-_]", "", collapsed)
    return name if name else "ride"
