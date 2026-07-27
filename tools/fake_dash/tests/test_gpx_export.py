"""
Tests for GPX EXPORT serialisation (`GPXExporter.swift`) via
`gpx_export_mirror.py`, plus the export→import ROUND-TRIP contract
against the import mirror (`gpx_geometry_mirror.py`).

These pin, without booting Xcode:
  - element structure + ordering (metadata/trk/trkseg/trkpt)
  - numeric formatting: 7 dp coords, 1 dp ele, 2 dp speed, '.' separator
  - ISO-8601 UTC timestamps ("…Z")
  - speed emitted only when known (>= 0); dropped for unknown (-1)
  - XML escaping of the track name
  - empty ride → no document (None)
  - default track name + filesystem-safe slug
  - ROUND-TRIP: a document the exporter writes re-imports as a `.track`
    with byte-identical coordinates (7 dp) — the write/read symmetry the
    "save ride, re-open it" workflow relies on.
"""

from __future__ import annotations

import xml.etree.ElementTree as ET
from datetime import datetime, timedelta, timezone

import pytest

from tests.gpx_export_mirror import (
    COORDINATE_PRECISION,
    TrackPoint,
    default_track_name,
    file_base_name,
    gpx,
)
from tests.gpx_geometry_mirror import import_route

# ─────────────────────────── helpers ────────────────────────────────

T0 = datetime(2026, 7, 27, 9, 41, 3, tzinfo=timezone.utc)


def pt(lat, lon, ele=200.0, dt_s=0, speed=10.0):
    return TrackPoint(lat, lon, ele, T0 + timedelta(seconds=dt_s), speed)


def _local(tag: str) -> str:
    return tag.split("}", 1)[1] if "}" in tag else tag


# Prague-area sample track (a few hundred metres apart).
SAMPLE = [
    pt(50.0870000, 14.4200000, ele=201.4, dt_s=0, speed=0.0),
    pt(50.0880000, 14.4215000, ele=203.9, dt_s=5, speed=8.3),
    pt(50.0895000, 14.4230000, ele=205.1, dt_s=11, speed=12.7),
]


# ────────────────────────── structure ───────────────────────────────


def test_empty_ride_produces_no_document():
    assert gpx([], "Ride") is None


def test_wellformed_xml_and_namespaces():
    doc = gpx(SAMPLE, "Ride 2026-07-27 09:41")
    root = ET.fromstring(doc)  # raises if malformed
    assert _local(root.tag) == "gpx"
    assert root.get("version") == "1.1"
    assert root.get("creator") == "TripperDashPP"


def test_track_structure_and_point_count():
    doc = gpx(SAMPLE, "Ride")
    root = ET.fromstring(doc)
    trkpts = [el for el in root.iter() if _local(el.tag) == "trkpt"]
    assert len(trkpts) == len(SAMPLE)
    # metadata + trk names both present
    names = [el.text for el in root.iter() if _local(el.tag) == "name"]
    assert names == ["Ride", "Ride"]


def test_coordinate_precision_is_7dp():
    doc = gpx([pt(50.123456789, 14.987654321)], "R")
    root = ET.fromstring(doc)
    tp = next(el for el in root.iter() if _local(el.tag) == "trkpt")
    # 7 dp, rounded, '.' separator
    assert tp.get("lat") == "50.1234568"
    assert tp.get("lon") == "14.9876543"


def test_elevation_and_speed_precision():
    doc = gpx([pt(50.0, 14.0, ele=205.14159, speed=12.6666)], "R")
    root = ET.fromstring(doc)
    ele = next(el for el in root.iter() if _local(el.tag) == "ele")
    spd = next(el for el in root.iter() if _local(el.tag) == "speed")
    assert ele.text == "205.1"
    assert spd.text == "12.67"


def test_timestamp_is_iso8601_utc_z():
    doc = gpx([pt(50.0, 14.0, dt_s=0)], "R")
    root = ET.fromstring(doc)
    t = next(el for el in root.iter() if _local(el.tag) == "time" and el.text.endswith("Z"))
    assert t.text == "2026-07-27T09:41:03Z"


def test_unknown_speed_is_omitted():
    doc = gpx([pt(50.0, 14.0, speed=-1.0)], "R")
    root = ET.fromstring(doc)
    speeds = [el for el in root.iter() if _local(el.tag) == "speed"]
    assert speeds == []
    # but a known-speed point still emits it
    doc2 = gpx([pt(50.0, 14.0, speed=5.0)], "R")
    assert "<gpxtpx:speed>5.00</gpxtpx:speed>" in doc2


def test_track_name_is_xml_escaped():
    doc = gpx(SAMPLE, 'Ride "A&B" <weird>')
    # Must still parse, and the raw string must be escaped in the bytes.
    ET.fromstring(doc)
    assert "&amp;" in doc and "&lt;weird&gt;" in doc and "&quot;" in doc


def test_decimal_separator_is_always_dot():
    # Even if a locale would use a comma, the serialiser must not.
    doc = gpx([pt(50.5, 14.5, ele=100.0, speed=1.5)], "R")
    assert "," not in doc.split("<trkseg>")[1]


# ────────────────────────── naming ──────────────────────────────────


def test_default_track_name_format():
    assert default_track_name(datetime(2026, 7, 27, 9, 41)) == "Ride 2026-07-27 09:41"


@pytest.mark.parametrize(
    "name,expected",
    [
        ("Ride 2026-07-27 09:41", "Ride-2026-07-27-0941"),
        ("", "ride"),
        ("čeština !@#", "etina-"),  # space→'-' first, then diacritics/punct stripped
        ("a/b\\c", "abc"),
    ],
)
def test_file_base_name_slug(name, expected):
    assert file_base_name(name) == expected


# ───────────────────────── round-trip ───────────────────────────────


def test_export_reimports_as_track_with_same_coords():
    """A document the exporter writes must re-import (import mirror) as a
    `.track` whose coordinates match the originals at 7 dp — the core
    write/read symmetry."""
    doc = gpx(SAMPLE, "Ride 2026-07-27 09:41")
    result = import_route(doc, filename="Ride.gpx")
    assert result["kind"] == "track"
    assert result["name"] == "Ride 2026-07-27 09:41"
    got = [(round(p.lat, COORDINATE_PRECISION), round(p.lon, COORDINATE_PRECISION))
           for p in result["points"]]
    want = [(round(p.latitude, COORDINATE_PRECISION), round(p.longitude, COORDINATE_PRECISION))
            for p in SAMPLE]
    # import may reduce a long track, but a 3-point track is under the cap,
    # so every point should survive unchanged and in order.
    assert got == want
