"""
Tests for GPX EXPORT serialisation (`GPXExporter.swift`) via
`gpx_export_mirror.py`, plus the export→import ROUND-TRIP contract
against the import mirror (`gpx_geometry_mirror.py`).

GPXExporter serialises a `SavedRoute` (ordered coordinate points, each
with an optional name) — this is the "Save ride → Saved routes → Export
as GPX" path. SavedRoute points carry no elevation / time / speed, so
those per-point fields are not emitted.

These pin, without booting Xcode:
  - element structure + ordering (metadata/trk/trkseg/trkpt)
  - 7 dp coords, '.' decimal separator
  - ISO-8601 UTC `<metadata><time>`
  - optional per-point <name> (named vias) vs anonymous trackpoints
  - XML escaping of the track name
  - empty route → no document (None)
  - filesystem-safe slug
  - ROUND-TRIP: a document the exporter writes re-imports as a `.track`
    with byte-identical coordinates (7 dp) — the "save ride, re-open it,
    export it, re-import it" symmetry.
"""

from __future__ import annotations

import xml.etree.ElementTree as ET

import pytest

from tests.gpx_export_mirror import (
    COORDINATE_PRECISION,
    Point,
    file_base_name,
    gpx,
)
from tests.gpx_geometry_mirror import import_route

# ─────────────────────────── helpers ────────────────────────────────

ISO = "2026-07-27T09:41:03Z"


def _local(tag: str) -> str:
    return tag.split("}", 1)[1] if "}" in tag else tag


# Prague-area sample route (a few hundred metres apart).
SAMPLE = [
    Point(50.0870000, 14.4200000),
    Point(50.0880000, 14.4215000, name="Rest stop"),
    Point(50.0895000, 14.4230000),
]


# ────────────────────────── structure ───────────────────────────────


def test_empty_route_produces_no_document():
    assert gpx([], "Ride", ISO) is None


def test_wellformed_xml_and_namespaces():
    doc = gpx(SAMPLE, "Ride 2026-07-27 09:41", ISO)
    root = ET.fromstring(doc)  # raises if malformed
    assert _local(root.tag) == "gpx"
    assert root.get("version") == "1.1"
    assert root.get("creator") == "TripperDashPP"


def test_track_structure_and_point_count():
    doc = gpx(SAMPLE, "Ride", ISO)
    root = ET.fromstring(doc)
    trkpts = [el for el in root.iter() if _local(el.tag) == "trkpt"]
    assert len(trkpts) == len(SAMPLE)


def test_metadata_and_trk_name_present():
    doc = gpx(SAMPLE, "Ride", ISO)
    root = ET.fromstring(doc)
    # metadata/name and trk/name (the named point also has a <name>).
    names = [el.text for el in root.iter() if _local(el.tag) == "name"]
    assert names[:2] == ["Ride", "Ride"]
    assert "Rest stop" in names


def test_coordinate_precision_is_7dp():
    doc = gpx([Point(50.123456789, 14.987654321)], "R", ISO)
    root = ET.fromstring(doc)
    tp = next(el for el in root.iter() if _local(el.tag) == "trkpt")
    assert tp.get("lat") == "50.1234568"
    assert tp.get("lon") == "14.9876543"


def test_timestamp_in_metadata():
    doc = gpx(SAMPLE, "R", ISO)
    root = ET.fromstring(doc)
    t = next(el for el in root.iter() if _local(el.tag) == "time")
    assert t.text == ISO


def test_anonymous_point_has_no_name():
    doc = gpx([Point(50.0, 14.0)], "R", ISO)
    root = ET.fromstring(doc)
    trkpt = next(el for el in root.iter() if _local(el.tag) == "trkpt")
    child_names = [el for el in trkpt if _local(el.tag) == "name"]
    assert child_names == []


def test_named_point_emits_name():
    doc = gpx([Point(50.0, 14.0, name="Castle")], "R", ISO)
    assert "<name>Castle</name>" in doc


def test_track_name_is_xml_escaped():
    doc = gpx(SAMPLE, 'Ride "A&B" <weird>', ISO)
    ET.fromstring(doc)  # must still parse
    assert "&amp;" in doc and "&lt;weird&gt;" in doc and "&quot;" in doc


def test_decimal_separator_is_always_dot():
    doc = gpx([Point(50.5, 14.5)], "R", ISO)
    assert "," not in doc.split("<trkseg>")[1]


# ────────────────────────── naming ──────────────────────────────────


@pytest.mark.parametrize(
    "name,expected",
    [
        ("Ride 2026-07-27 09:41", "Ride-2026-07-27-0941"),
        ("", "route"),
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
    write/read symmetry behind 'save ride → export → re-import'."""
    doc = gpx(SAMPLE, "Ride 2026-07-27 09:41", ISO)
    result = import_route(doc, filename="Ride.gpx")
    assert result["kind"] == "track"
    assert result["name"] == "Ride 2026-07-27 09:41"
    got = [(round(p.lat, COORDINATE_PRECISION), round(p.lon, COORDINATE_PRECISION))
           for p in result["points"]]
    want = [(round(p.lat, COORDINATE_PRECISION), round(p.lon, COORDINATE_PRECISION))
            for p in SAMPLE]
    # A 3-point track is under the reduction cap, so every point survives
    # unchanged and in order.
    assert got == want
