"""
Drift guard: the saved-route thumbnail follows edits made on the detail screen.

`SavedRoutePreviewMap` re-snapshotted only on appear, size or colour-scheme
changes, and its key held just the point count and the first/last ids. Adding,
deleting or reordering a stop left the old shape on screen until the screen
was closed and reopened.
"""

from __future__ import annotations

import pathlib
import unittest

from tests.swift_source import decl_body, strip_comments

SRC = (pathlib.Path(__file__).resolve().parents[3]
       / "TripperDashPP/UI/Navigation/SavedRoutePreviewMap.swift")


class PreviewFollowsEdits(unittest.TestCase):
    def setUp(self):
        self.src = strip_comments(SRC.read_text(encoding="utf-8"))

    def test_rerenders_on_point_change(self):
        self.assertIn(".onChange(of: points)", self.src)

    def test_key_covers_every_point(self):
        body = decl_body(self.src, "private func renderIfNeeded")
        self.assertIn("points.hashValue", body)

    def test_stale_snapshot_dropped(self):
        body = decl_body(self.src, "private func render(")
        self.assertIn("renderedKey == key", body)


if __name__ == "__main__":
    unittest.main()
