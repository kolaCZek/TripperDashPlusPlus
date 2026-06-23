"""
Regression net for the load-bearing "don't mix light and dark tiles"
invariant of `TileDiskCache.swift`.

The Swift cache stores every tile at
`Caches/RouteTiles/<style.cacheNamespace>/<z>/<x>/<y>.png`. Light and
dark share the same (z, x, y) slippy address, so the ONLY thing keeping a
dark tile from overwriting the light PNG at the same coordinate is the
per-style namespace path component. This test mirrors that path logic in
Python and proves, against a real temp filesystem, that:

  * the two styles write to different files for the same (z, x, y);
  * each style reads back exactly its own bytes;
  * clearing one style leaves the other intact;
  * a per-style stats walk only counts that style's tiles.

If `TileDiskCache.url(style:z:x:y:)` ever changes shape, mirror it in
`disk_cache_path()` below and these assertions still pin the behaviour.
"""

import shutil
import tempfile
import unittest
from pathlib import Path


# --- Mirror of TileDiskCache.url(style:z:x:y:) path construction --------

# Mirror of MapStyle.cacheNamespace (rawValue: "light" / "dark").
STYLE_NAMESPACES = {"light": "light", "dark": "dark"}


def disk_cache_path(base: Path, style: str, z: int, x: int, y: int) -> Path:
    """Python mirror of the Swift on-disk tile path."""
    ns = STYLE_NAMESPACES[style]
    return base / ns / str(z) / str(x) / f"{y}.png"


def write_tile(base: Path, style: str, z: int, x: int, y: int, data: bytes) -> None:
    p = disk_cache_path(base, style, z, x, y)
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_bytes(data)


def read_tile(base: Path, style: str, z: int, x: int, y: int) -> bytes | None:
    p = disk_cache_path(base, style, z, x, y)
    return p.read_bytes() if p.exists() else None


def clear_style(base: Path, style: str) -> None:
    d = base / STYLE_NAMESPACES[style]
    if d.exists():
        shutil.rmtree(d)
    d.mkdir(parents=True, exist_ok=True)


def stats_style(base: Path, style: str) -> tuple[int, int]:
    d = base / STYLE_NAMESPACES[style]
    if not d.exists():
        return (0, 0)
    pngs = list(d.rglob("*.png"))
    return (len(pngs), sum(p.stat().st_size for p in pngs))


# --- Tests -------------------------------------------------------------


class TestStyleIsolation(unittest.TestCase):
    def setUp(self):
        self.base = Path(tempfile.mkdtemp(prefix="routetiles_"))

    def tearDown(self):
        shutil.rmtree(self.base, ignore_errors=True)

    def test_same_zxy_different_styles_are_distinct_files(self):
        z, x, y = 15, 8800, 5512
        write_tile(self.base, "light", z, x, y, b"LIGHT-PNG-BYTES")
        write_tile(self.base, "dark", z, x, y, b"DARK-PNG-BYTES")

        light_path = disk_cache_path(self.base, "light", z, x, y)
        dark_path = disk_cache_path(self.base, "dark", z, x, y)

        # Different files on disk.
        self.assertNotEqual(light_path, dark_path)
        self.assertTrue(light_path.exists())
        self.assertTrue(dark_path.exists())

    def test_reader_never_gets_the_other_palette(self):
        """The core requirement: writing dark must NOT clobber light at
        the same (z, x, y), and each read returns its own bytes."""
        z, x, y = 15, 8800, 5512
        write_tile(self.base, "light", z, x, y, b"LIGHT-PNG-BYTES")
        write_tile(self.base, "dark", z, x, y, b"DARK-PNG-BYTES")

        self.assertEqual(read_tile(self.base, "light", z, x, y), b"LIGHT-PNG-BYTES")
        self.assertEqual(read_tile(self.base, "dark", z, x, y), b"DARK-PNG-BYTES")

    def test_write_order_does_not_matter(self):
        """Dark-then-light and light-then-dark both keep both palettes —
        proves last-write-wins can never cross the namespace boundary."""
        z, x, y = 16, 100, 200
        write_tile(self.base, "dark", z, x, y, b"D")
        write_tile(self.base, "light", z, x, y, b"L")
        write_tile(self.base, "dark", z, x, y, b"D2")  # rewrite dark again

        self.assertEqual(read_tile(self.base, "light", z, x, y), b"L")
        self.assertEqual(read_tile(self.base, "dark", z, x, y), b"D2")

    def test_clear_one_style_keeps_the_other(self):
        z, x, y = 15, 1, 1
        write_tile(self.base, "light", z, x, y, b"L")
        write_tile(self.base, "dark", z, x, y, b"D")

        clear_style(self.base, "dark")

        self.assertEqual(read_tile(self.base, "light", z, x, y), b"L")
        self.assertIsNone(read_tile(self.base, "dark", z, x, y))

    def test_per_style_stats_count_only_that_style(self):
        # 3 light tiles, 1 dark tile.
        for y in range(3):
            write_tile(self.base, "light", 15, 10, y, b"xxxx")
        write_tile(self.base, "dark", 15, 10, 0, b"yy")

        l_count, l_bytes = stats_style(self.base, "light")
        d_count, d_bytes = stats_style(self.base, "dark")

        self.assertEqual(l_count, 3)
        self.assertEqual(l_bytes, 12)  # 3 * 4 bytes
        self.assertEqual(d_count, 1)
        self.assertEqual(d_bytes, 2)


if __name__ == "__main__":
    unittest.main()
