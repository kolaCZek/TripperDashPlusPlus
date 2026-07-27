"""
Python mirror of GPX EXPORT serialisation (`GPXExporter.swift`).

The Swift `GPXExporter` builds a GPX 1.1 `<trk>` document from a
`SavedRoute` (ordered coordinate points, each with an optional name).
This module reproduces that byte-for-byte so the exporter's string math
is unit-tested without a Mac — the same discipline as the import mirror
(`gpx_geometry_mirror.py`).

Kept deliberately in lockstep with GPXExporter.swift:
  * 7-decimal fixed coordinates (`f"{v:.7f}"`)
  * `<metadata><name><time>` header (ISO-8601 UTC)
  * one `<trk>` / one `<trkseg>` / `<trkpt lat lon>` with optional `<name>`
  * XML escaping of &, <, >, ", '
  * `fileBaseName`: spaces->'-', ':' dropped, then strip to [A-Za-z0-9-_]

SavedRoute points carry NO elevation / time / speed, so no <ele>/<time>
is emitted per point (unlike the earlier ride-centric version).
"""

from dataclasses import dataclass, field
from typing import Optional

COORDINATE_PRECISION = 7

_ALLOWED_FILENAME = set(
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_"
)


@dataclass
class Point:
    lat: float
    lon: float
    name: Optional[str] = None


def fixed(value: float, places: int = COORDINATE_PRECISION) -> str:
    return f"{value:.{places}f}"


def escape(s: str) -> str:
    return (
        s.replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace('"', "&quot;")
        .replace("'", "&apos;")
    )


def file_base_name(track_name: str) -> str:
    collapsed = track_name.replace(" ", "-").replace(":", "")
    name = "".join(c for c in collapsed if c in _ALLOWED_FILENAME)
    return name if name else "route"


def _trkpt(p: Point) -> str:
    s = f'      <trkpt lat="{fixed(p.lat)}" lon="{fixed(p.lon)}">\n'
    if p.name:
        s += f"        <name>{escape(p.name)}</name>\n"
    s += "      </trkpt>\n"
    return s


def gpx(points, track_name: str, iso_time: str) -> Optional[str]:
    """Mirror of GPXExporter.gpx(points:trackName:now:).

    `iso_time` is the pre-formatted ISO-8601 UTC string (the Swift side
    formats the Date; here we take it ready-made so the test controls it).
    Returns None for an empty point list.
    """
    if not points:
        return None

    xml = ""
    xml += '<?xml version="1.0" encoding="UTF-8"?>\n'
    xml += '<gpx version="1.1" creator="TripperDashPP" '
    xml += 'xmlns="http://www.topografix.com/GPX/1/1">\n'
    xml += "  <metadata>\n"
    xml += f"    <name>{escape(track_name)}</name>\n"
    xml += f"    <time>{iso_time}</time>\n"
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
