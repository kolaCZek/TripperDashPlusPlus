"""
Python mirror of GPX import geometry + start-mode logic.

Mirrors two Swift files so the math is pinned without booting Xcode:

  - `TripperDashPP/Navigation/GPXParser.swift`  → GPXGeometry enum
        (haversine, pathLength, Douglas–Peucker reduce, perpendicular
        distance, isValid)
  - `TripperDashPP/Navigation/RouteStartPlanner.swift` → analyze /
        navigable_points

The Swift uses an equirectangular projection for perpendicular distance
(metres) and a great-circle haversine for point-to-point length. Both are
reproduced exactly here so the tests assert against the same numbers the
device computes.

Also includes a minimal GPX parser that mirrors the EXTRACTION PRIORITY
of `GPXImporter.parse` (rte → trk → wpt) so the Python suite can pin the
"which geometry wins" rule against real XML, using only stdlib
xml.etree. The Swift uses a SAX XMLParser; the priority + tolerance rules
are what we mirror, not the parser class.

Keep in sync with GPXParser.swift + RouteStartPlanner.swift.
"""

from __future__ import annotations

import math
import xml.etree.ElementTree as ET
from dataclasses import dataclass, field
from typing import Optional

# ── Mirror of RoutePoint.navigableCap + RouteStartPlanner constants ──
NAVIGABLE_CAP = 24
PROMPT_THRESHOLD_M = 300.0

EARTH_R = 6_371_000.0
M_PER_DEG = 111_320.0


@dataclass
class Pt:
    """Mirror of RoutePoint (id omitted — identity not needed in tests)."""
    lat: float
    lon: float
    name: Optional[str] = None


# ─────────────────────────── geometry ───────────────────────────────


def is_valid(lat: float, lon: float) -> bool:
    if not (math.isfinite(lat) and math.isfinite(lon)):
        return False
    return -90 <= lat <= 90 and -180 <= lon <= 180


def haversine(a: Pt, b: Pt) -> float:
    phi1 = math.radians(a.lat)
    phi2 = math.radians(b.lat)
    dphi = math.radians(b.lat - a.lat)
    dlam = math.radians(b.lon - a.lon)
    h = math.sin(dphi / 2) ** 2 + math.cos(phi1) * math.cos(phi2) * math.sin(dlam / 2) ** 2
    return EARTH_R * 2 * math.atan2(math.sqrt(h), math.sqrt(1 - h))


def path_length(pts: list[Pt]) -> float:
    if len(pts) < 2:
        return 0.0
    return sum(haversine(pts[i], pts[i + 1]) for i in range(len(pts) - 1))


def bounding_span(
    coords: list[Pt],
    padding_factor: float = 1.35,
    min_span_degrees: float = 0.004,
) -> Optional[tuple[float, float, float, float]]:
    """Mirror of GPXGeometry.boundingSpan — center + padded lat/lon deltas.

    Returns (center_lat, center_lon, lat_delta, lon_delta) or None for an
    empty input. Antimeridian crossing is intentionally NOT handled (same
    as Swift).
    """
    if not coords:
        return None
    lats = [c.lat for c in coords]
    lons = [c.lon for c in coords]
    min_lat, max_lat = min(lats), max(lats)
    min_lon, max_lon = min(lons), max(lons)
    center_lat = (min_lat + max_lat) / 2
    center_lon = (min_lon + max_lon) / 2
    lat_delta = max((max_lat - min_lat) * padding_factor, min_span_degrees)
    lon_delta = max((max_lon - min_lon) * padding_factor, min_span_degrees)
    return (center_lat, center_lon, lat_delta, lon_delta)


def perpendicular_distance(p: Pt, a: Pt, b: Pt) -> float:
    mid_lat = math.radians((a.lat + b.lat) / 2)
    m_per_deg_lat = M_PER_DEG
    m_per_deg_lon = M_PER_DEG * math.cos(mid_lat)

    ax, ay = a.lon * m_per_deg_lon, a.lat * m_per_deg_lat
    bx, by = b.lon * m_per_deg_lon, b.lat * m_per_deg_lat
    px, py = p.lon * m_per_deg_lon, p.lat * m_per_deg_lat

    dx, dy = bx - ax, by - ay
    len_sq = dx * dx + dy * dy
    if len_sq <= 0:
        return haversine(p, a)
    t = max(0.0, min(1.0, ((px - ax) * dx + (py - ay) * dy) / len_sq))
    proj_x, proj_y = ax + t * dx, ay + t * dy
    ex, ey = px - proj_x, py - proj_y
    return math.sqrt(ex * ex + ey * ey)


def douglas_peucker(points: list[Pt], epsilon: float, forced: set[int]) -> list[Pt]:
    n = len(points)
    if n < 3:
        return list(points)
    keep = [False] * n
    keep[0] = True
    keep[n - 1] = True
    for i in forced:
        if 0 <= i < n:
            keep[i] = True

    def simplify(start: int, end: int) -> None:
        if end <= start + 1:
            return
        max_dist = 0.0
        idx = start
        for i in range(start + 1, end):
            d = perpendicular_distance(points[i], points[start], points[end])
            if d > max_dist:
                max_dist = d
                idx = i
        if max_dist > epsilon:
            keep[idx] = True
            simplify(start, idx)
            simplify(idx, end)

    anchors = [i for i in range(n) if keep[i]]
    for j in range(len(anchors) - 1):
        simplify(anchors[j], anchors[j + 1])

    return [points[i] for i in range(n) if keep[i]]


def evenly_sample(points: list[Pt], cap: int) -> list[Pt]:
    n = len(points)
    if n <= cap or cap < 2:
        return list(points)
    out: list[Pt] = []
    step = (n - 1) / (cap - 1)
    for i in range(cap):
        out.append(points[round(i * step)])
    if out[-1] is not points[-1]:
        out[-1] = points[-1]
    return out


def reduce(points: list[Pt], cap: int = NAVIGABLE_CAP) -> list[Pt]:
    n = len(points)
    if n <= cap or cap < 2:
        return list(points)

    forced: set[int] = {0, n - 1}
    for i, p in enumerate(points):
        if p.name:
            forced.add(i)

    if len(forced) >= cap:
        return [points[i] for i in range(n) if i in forced]

    epsilon = 10.0
    kept = douglas_peucker(points, epsilon, forced)
    guard = 0
    while len(kept) > cap and guard < 40:
        epsilon *= 1.6
        kept = douglas_peucker(points, epsilon, forced)
        guard += 1

    if len(kept) > cap:
        kept = evenly_sample(kept, cap)
    return kept


# ─────────────────────── start-mode planner ─────────────────────────


@dataclass
class StartDecision:
    nearest_index: int
    distance_to_first: float
    distance_to_nearest: float
    should_prompt: bool


def analyze(points: list[Pt], rider: Optional[Pt]) -> StartDecision:
    if rider is None or not points:
        return StartDecision(0, 0.0, 0.0, False)

    dist_first = haversine(rider, points[0])
    nearest_idx = 0
    nearest_dist = dist_first
    for i, p in enumerate(points):
        d = haversine(rider, p)
        if d < nearest_dist:
            nearest_dist = d
            nearest_idx = i

    should_prompt = nearest_idx > 0 and (dist_first - nearest_dist) > PROMPT_THRESHOLD_M
    return StartDecision(nearest_idx, dist_first, nearest_dist, should_prompt)


def navigable_points(points: list[Pt], mode: str, nearest_index: int) -> list[Pt]:
    if mode == "from_first":
        return list(points)
    if mode == "from_nearest":
        if 0 < nearest_index < len(points):
            return list(points[nearest_index:])
        return list(points)
    raise ValueError(f"unknown mode {mode!r}")


# ─────────────────── GPX extraction-priority mirror ──────────────────


@dataclass
class ParsedGPX:
    name: str
    kind: str  # "track" | "waypoints"
    raw_points: list[Pt] = field(default_factory=list)


def _local(tag: str) -> str:
    """Strip an XML namespace ('{ns}trkpt' or 'gpx:trkpt' → 'trkpt')."""
    if "}" in tag:
        tag = tag.split("}", 1)[1]
    if ":" in tag:
        tag = tag.split(":", 1)[1]
    return tag


def _points_under(root, *, point_tag: str) -> list[Pt]:
    pts: list[Pt] = []
    for el in root.iter():
        if _local(el.tag) != point_tag:
            continue
        lat = el.get("lat")
        lon = el.get("lon")
        if lat is None or lon is None:
            continue
        try:
            la, lo = float(lat), float(lon)
        except ValueError:
            continue
        if not is_valid(la, lo):
            continue
        name = None
        for child in el:
            if _local(child.tag) == "name" and child.text:
                name = child.text.strip()
                break
        pts.append(Pt(la, lo, name))
    return pts


def parse(gpx_text: str, filename_fallback: Optional[str] = None) -> ParsedGPX:
    """Mirror GPXImporter.parse: rte → trk → wpt priority + name pick."""
    root = ET.fromstring(gpx_text)

    rte_pts = _points_under(root, point_tag="rtept")
    trk_pts = _points_under(root, point_tag="trkpt")
    wpt_pts = _points_under(root, point_tag="wpt")

    if rte_pts:
        kind, pts = "track", rte_pts
    elif trk_pts:
        kind, pts = "track", trk_pts
    else:
        kind, pts = "waypoints", wpt_pts

    # Name: <rte><name> / <trk><name> / <metadata><name> → fallback.
    route_name = _first_named_child(root, "rte")
    track_name = _first_named_child(root, "trk")
    meta_name = _first_named_child(root, "metadata")
    fallback = None
    if filename_fallback:
        fallback = filename_fallback.rsplit(".", 1)[0].replace("_", " ")
    name = next(
        (c for c in (route_name, track_name, meta_name, fallback) if c and c.strip()),
        "Imported route",
    )
    return ParsedGPX(name=name, kind=kind, raw_points=pts)


def _first_named_child(root, parent_tag: str) -> Optional[str]:
    for el in root.iter():
        if _local(el.tag) != parent_tag:
            continue
        for child in el:
            if _local(child.tag) == "name" and child.text:
                return child.text.strip()
    return None


def import_route(gpx_text: str, filename: Optional[str] = None):
    """Mirror GPXImporter.importRoute: parse → measure full trace → reduce."""
    parsed = parse(gpx_text, filename)
    if not parsed.raw_points:
        raise ValueError("no usable points")
    full_distance = path_length(parsed.raw_points)
    if parsed.kind == "waypoints":
        pts = parsed.raw_points
    else:
        pts = reduce(parsed.raw_points, NAVIGABLE_CAP)
    return {
        "name": parsed.name,
        "kind": parsed.kind,
        "points": pts,
        "total_distance_m": full_distance,
        "source_filename": filename,
    }
