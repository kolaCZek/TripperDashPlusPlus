"""
Regression net for the tile-cache namespace logic of `TileDiskCache.swift`
AFTER the move to a single shared OSM tile cache (June 2026).

History: an earlier revision fetched two *different* basemaps (CARTO
Positron for light, Darkmatter for dark) and the load-bearing invariant
was the OPPOSITE of this file's — light and dark had to be ISOLATED so a
dark tile couldn't clobber the light PNG at the same (z, x, y). That test
(`test_tile_cache_style_isolation.py`) is gone.

Now both palettes render from the SAME raw OSM Carto tile — the dark map
is produced by a composite-time colour transform (`TileColorTransform`),
not a second download — so `MapStyle.tileCacheNamespace` returns the SAME
string (`"osm"`) for both. The new invariant this file pins:

  * both styles resolve to the one `"osm"` namespace;
  * light and dark therefore SHARE one file at a given (z, x, y) — a write
    under one palette is readable under the other (the whole efficiency
    win: one fetch, one cached PNG serves both);
  * the namespace is a single stable, filesystem-safe path component;
  * clearing the cache removes the one shared tree.

If `MapStyle.tileCacheNamespace` or `TileDiskCache.url(style:z:x:y:)` ever
changes shape, mirror it in the helpers below and these assertions still
pin the behaviour.
"""

import shutil
import tempfile
import unittest
from pathlib import Path


# --- Mirror of MapStyle.tileCacheNamespace + TileDiskCache.url ---------

def tile_cache_namespace(style: str) -> str:
    """Mirror of `MapStyle.tileCacheNamespace`.

    Both palettes share ONE namespace because the dark map is a
    composite-time recolour of the same OSM tile, not a separate fetch.
    """
    assert style in ("light", "dark"), f"unknown style {style!r}"
    return "osm"


def disk_cache_path(base: Path, style: str, z: int, x: int, y: int) -> Path:
    """Python mirror of the Swift on-disk tile path."""
    ns = tile_cache_namespace(style)
    return base / ns / str(z) / str(x) / f"{y}.png"


def write_tile(base: Path, style: str, z: int, x: int, y: int, data: bytes) -> None:
    p = disk_cache_path(base, style, z, x, y)
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_bytes(data)


def read_tile(base: Path, style: str, z: int, x: int, y: int) -> bytes | None:
    p = disk_cache_path(base, style, z, x, y)
    return p.read_bytes() if p.exists() else None


def clear_all(base: Path) -> None:
    if base.exists():
        shutil.rmtree(base)
    base.mkdir(parents=True, exist_ok=True)


def stats_all(base: Path) -> tuple[int, int]:
    if not base.exists():
        return (0, 0)
    pngs = list(base.rglob("*.png"))
    return (len(pngs), sum(p.stat().st_size for p in pngs))


# --- Tests -------------------------------------------------------------


class TestSharedNamespace(unittest.TestCase):
    def setUp(self):
        self.base = Path(tempfile.mkdtemp(prefix="routetiles_"))

    def tearDown(self):
        shutil.rmtree(self.base, ignore_errors=True)

    def test_both_styles_resolve_to_one_osm_namespace(self):
        """The crux of the shared-cache design: light and dark map to the
        SAME namespace, so the fetcher/disk never double-stores a tile."""
        self.assertEqual(tile_cache_namespace("light"), "osm")
        self.assertEqual(tile_cache_namespace("dark"), "osm")
        self.assertEqual(
            tile_cache_namespace("light"), tile_cache_namespace("dark")
        )

    def test_same_zxy_is_one_shared_file_across_styles(self):
        z, x, y = 15, 8800, 5512
        light_path = disk_cache_path(self.base, "light", z, x, y)
        dark_path = disk_cache_path(self.base, "dark", z, x, y)
        # Same file on disk — one tile serves both palettes.
        self.assertEqual(light_path, dark_path)

    def test_write_under_one_style_is_readable_under_the_other(self):
        """The efficiency win: a tile fetched while in light mode is the
        exact same raw OSM PNG dark mode will recolour — so reading it
        back under the other style returns the same bytes, no re-fetch."""
        z, x, y = 15, 8800, 5512
        write_tile(self.base, "light", z, x, y, b"RAW-OSM-PNG-BYTES")
        # Dark reads the very bytes light wrote.
        self.assertEqual(read_tile(self.base, "dark", z, x, y), b"RAW-OSM-PNG-BYTES")

    def test_last_write_wins_within_the_shared_file(self):
        """Both styles address one file, so the most recent write is what
        either palette reads — there is no per-palette divergence."""
        z, x, y = 16, 100, 200
        write_tile(self.base, "light", z, x, y, b"V1")
        write_tile(self.base, "dark", z, x, y, b"V2")
        self.assertEqual(read_tile(self.base, "light", z, x, y), b"V2")
        self.assertEqual(read_tile(self.base, "dark", z, x, y), b"V2")

    def test_clear_removes_the_shared_cache(self):
        z, x, y = 15, 1, 1
        write_tile(self.base, "light", z, x, y, b"L")
        write_tile(self.base, "dark", z, x, y, b"D")  # same file, overwrites
        clear_all(self.base)
        self.assertIsNone(read_tile(self.base, "light", z, x, y))
        self.assertIsNone(read_tile(self.base, "dark", z, x, y))

    def test_aggregate_stats_count_one_tile_per_zxy(self):
        """Three distinct (z,x,y) written via mixed styles = three files,
        not six — proves light+dark don't double-count on disk."""
        write_tile(self.base, "light", 15, 10, 0, b"xxxx")
        write_tile(self.base, "dark", 15, 10, 0, b"yyyy")   # same coord → same file
        write_tile(self.base, "light", 15, 10, 1, b"zzzz")
        write_tile(self.base, "dark", 15, 10, 2, b"wwww")
        count, total = stats_all(self.base)
        self.assertEqual(count, 3)          # (10,0),(10,1),(10,2) — not 4
        self.assertEqual(total, 12)         # 3 * 4 bytes

    def test_namespace_is_a_safe_single_path_component(self):
        ns = tile_cache_namespace("light")
        self.assertTrue(ns)
        self.assertNotIn("/", ns)
        self.assertNotIn("..", ns)
        self.assertEqual(ns, ns.strip())


if __name__ == "__main__":
    unittest.main()
