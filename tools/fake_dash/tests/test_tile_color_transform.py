"""
Pins the dark-map colour transform of `TileColorTransform.swift`.

The dark palette is NOT a second basemap — it is the light OSM raster run
through ONE integer colour matrix (`invert ∘ hue-rotate(180°)`) at
composite time, on the CPU (vImage) so it survives the screen locking.
This test is the mirror the Swift header promises: it (a) re-parses the
exact Int16 coefficients straight out of the Swift source so a future edit
can't silently drift them, (b) re-derives that matrix from first
principles (W3C `feColorMatrix` hueRotate ∘ invert) so the magic numbers
are explained not just asserted, and (c) runs the integer transform over
real OSM colours to prove the visual contract: white↔black flip, greys
stay neutral, and — the whole reason for the hue-rotate — water/forest
keep their hue instead of flipping to orange/magenta.

CRITICAL — column-major (the bug this guards):
`vImageMatrixMultiply_ARGB8888` reads its coefficient array **column-major**:
output channel `i` is the dot product of the input pixel with the i-th
*column* of the flat 4×4 array, i.e. `out[i] = Σ_j matrix[j*4 + i]·src[j]`.
A first cut of this feature stored the mathematical (row-major) matrix and a
mirror test that ALSO applied it row-major — so the test was green while the
device rendered an all-blue map (every land/water/white pixel collapsed to
~(0,0,130)). The fix transposed the literal in Swift; this test now applies
the matrix the way vImage actually does (column-major) against the SHIPPED
literal, so a non-transposed matrix fails loudly here instead of on the bike.

If the coefficients change in Swift, the parse + the derived-reference
checks here fail loudly.
"""

import re
import unittest
from pathlib import Path

# tools/fake_dash/tests/ -> repo root is three parents up.
REPO_ROOT = Path(__file__).resolve().parents[3]
SWIFT_SRC = REPO_ROOT / "TripperDashPP" / "Map" / "TileColorTransform.swift"


# --- Parse the real coefficients out of the Swift source ---------------

def parse_swift_matrix() -> tuple[list[int], int]:
    """Pull the `darkInvert` matrix + divisor straight from the Swift file
    so this test guards the actual shipped numbers, not a copy."""
    src = SWIFT_SRC.read_text()
    # Grab the `static let darkInvert = TileColorTransform( ... )` call.
    block = re.search(
        r"static let darkInvert\s*=\s*TileColorTransform\((.*?)\)",
        src,
        re.DOTALL,
    )
    assert block, "could not find darkInvert in TileColorTransform.swift"
    body = block.group(1)
    matrix_block = re.search(r"matrix:\s*\[(.*?)\]", body, re.DOTALL)
    assert matrix_block, "could not find matrix: [...] literal"
    nums = [int(n) for n in re.findall(r"-?\d+", matrix_block.group(1))]
    assert len(nums) == 16, f"expected 16 matrix entries, got {len(nums)}"
    divisor_m = re.search(r"divisor:\s*(\d+)", body)
    assert divisor_m, "could not find divisor"
    return nums, int(divisor_m.group(1))


def transpose(flat16: list[int]) -> list[int]:
    """Transpose a flat 4×4 matrix. Used to turn the SHIPPED column-major
    vImage literal back into the mathematical (row-major) matrix so it can
    be compared against the W3C derivation, and vice-versa."""
    return [flat16[j * 4 + i] for i in range(4) for j in range(4)]


# --- Independent re-derivation from W3C hueRotate ∘ invert -------------

def w3c_hue_rotate_180() -> list[list[float]]:
    """W3C `feColorMatrix type="hueRotate"` 3x3 for angle=180°
    (cos=-1, sin=0). Luma constants per the spec."""
    base = [
        [0.213, 0.715, 0.072],
        [0.213, 0.715, 0.072],
        [0.213, 0.715, 0.072],
    ]
    cosm = [
        [0.787, -0.715, -0.072],
        [-0.213, 0.285, -0.072],
        [-0.213, -0.715, 0.928],
    ]
    sinm = [
        [-0.213, -0.285, -0.072],
        [0.143, 0.140, -0.283],
        [-0.787, 0.715, 0.072],
    ]
    cos, sin = -1.0, 0.0
    return [
        [base[i][j] + cos * cosm[i][j] + sin * sinm[i][j] for j in range(3)]
        for i in range(3)
    ]


def derived_int_matrix() -> list[int]:
    """invert ∘ hueRotate(180°), scaled ×256, with the +1.0 invert
    constant folded into the alpha column (×256). This produces the
    MATHEMATICAL (row-major) matrix: row i is the formula for output
    channel i. The Swift literal is this transposed (see module docstring).
    Mirrors the Swift derivation comment exactly."""
    hue = w3c_hue_rotate_180()
    rows = []
    for i in range(3):
        # Linear part of (HueRotate · (1 - in)) is  -HueRotate.
        r = [round(-hue[i][j] * 256) for j in range(3)]
        # Constant part HueRotate · [1,1,1] == 1.0 per row (luma rows sum
        # to 1) -> folded into alpha column as 256.
        const = round(sum(hue[i]) * 256)
        r.append(const)
        rows.append(r)
    rows.append([0, 0, 0, 256])  # identity alpha row
    return [c for row in rows for c in row]


# --- Integer transform, mirroring vImageMatrixMultiply_ARGB8888 --------

def apply_matrix(px, matrix, divisor):
    """Apply the integer colour matrix to one RGBA pixel **exactly like
    vImageMatrixMultiply_ARGB8888**: column-major (output channel `i` reads
    the i-th column, `matrix[j*4 + i]`), rounded integer divide, clamp to
    [0, 255]. Channel-memory order is R, G, B, A (premultipliedLast on
    little-endian iOS). Feeding this the SHIPPED Swift literal reproduces
    what the device renders — so the all-blue transpose bug would fail the
    behaviour assertions below."""
    r, g, b, a = px
    src = (r, g, b, a)
    out = []
    half = divisor // 2
    for i in range(4):
        # column-major: output channel i is the dot product with column i.
        acc = sum(matrix[j * 4 + i] * src[j] for j in range(4))
        # vImage rounds (adds half divisor) then clamps.
        val = (acc + half) // divisor if acc >= 0 else -((-acc + half) // divisor)
        out.append(max(0, min(255, val)))
    return tuple(out)


MATRIX, DIVISOR = parse_swift_matrix()


class TestColorMatrixCoefficients(unittest.TestCase):
    def test_swift_matrix_matches_documented_coefficients(self):
        """Drift guard: the shipped Int16 matrix must be exactly this
        column-major (vImage) literal — the math matrix transposed."""
        self.assertEqual(
            MATRIX,
            [
                147, -109, -109, 0,
                -366, -110, -366, 0,
                -37, -37, 219, 0,
                256, 256, 256, 256,
            ],
        )
        self.assertEqual(DIVISOR, 256)

    def test_matrix_matches_w3c_derivation(self):
        """The magic numbers ARE invert ∘ hueRotate(180°), not arbitrary.
        `derived_int_matrix` builds the row-major math matrix; the shipped
        Swift literal is that transposed for vImage, so transpose it back
        before comparing (within ×256 fixed-point rounding)."""
        derived = derived_int_matrix()
        shipped_math = transpose(MATRIX)
        for shipped, ref in zip(shipped_math, derived):
            self.assertLessEqual(
                abs(shipped - ref), 1,
                f"coefficient drift: shipped {shipped} vs derived {ref}",
            )

    def test_alpha_output_is_identity(self):
        """Opacity must be preserved — the alpha OUTPUT channel (column 3
        in the column-major literal) must pass A through untouched."""
        alpha_col = [MATRIX[j * 4 + 3] for j in range(4)]
        self.assertEqual(alpha_col, [0, 0, 0, 256])

    def test_grey_axis_columns_are_consistent(self):
        """A neutral grey (v,v,v) must map to a neutral grey. In the
        column-major layout output channel i reads column i, so that holds
        iff the three RGB output columns act IDENTICALLY on the grey axis:
        equal sums over the RGB input rows AND equal alpha constants. Here
        every RGB column sums to -divisor (the `-HueRotate` linear part;
        HueRotate columns sum to 1.0) and every alpha constant is +divisor
        (the folded invert constant), so each channel computes 255-v ->
        grey in, grey out."""
        col_sums = [
            MATRIX[0 * 4 + i] + MATRIX[1 * 4 + i] + MATRIX[2 * 4 + i]
            for i in range(3)
        ]
        # All three identical -> no hue cast on the grey axis.
        self.assertEqual(len(set(col_sums)), 1, f"grey-axis cast: {col_sums}")
        # And equal to -divisor, i.e. the invert maps v -> 255 - v.
        self.assertEqual(col_sums[0], -DIVISOR)
        # Alpha constants feeding the three RGB output channels match.
        alpha_consts = [MATRIX[3 * 4 + i] for i in range(3)]
        self.assertEqual(set(alpha_consts), {DIVISOR})


class TestColorMatrixBehaviour(unittest.TestCase):
    OPAQUE = 255

    def t(self, r, g, b):
        return apply_matrix((r, g, b, self.OPAQUE), MATRIX, DIVISOR)

    def test_white_becomes_black(self):
        self.assertEqual(self.t(255, 255, 255), (0, 0, 0, 255))

    def test_black_becomes_white(self):
        self.assertEqual(self.t(0, 0, 0), (255, 255, 255, 255))

    def test_mid_grey_stays_mid_grey(self):
        """Neutral greys must invert to neutral greys — no colour cast."""
        out = self.t(128, 128, 128)
        r, g, b, a = out
        self.assertAlmostEqual(r, 127, delta=2)
        # Channels stay equal => still neutral.
        self.assertLessEqual(max(r, g, b) - min(r, g, b), 2)
        self.assertEqual(a, 255)

    def test_alpha_is_untouched(self):
        # Even at non-opaque alpha (defensive — composite is opaque), the
        # alpha channel must pass through unchanged.
        out = apply_matrix((10, 20, 30, 200), MATRIX, DIVISOR)
        self.assertEqual(out[3], 200)

    def test_osm_water_stays_blue_not_orange(self):
        """The whole reason for the hue-rotate: a PLAIN invert of OSM
        water (#AAD3DF, light blue) would yield orange (high R, low B).
        invert+hue keeps blue dominant => B must stay the largest channel
        and the result must be dark."""
        r, g, b, _ = self.t(0xAA, 0xD3, 0xDF)   # (170, 211, 223)
        self.assertGreater(b, r, "water lost its blue (plain-invert bug)")
        self.assertGreaterEqual(b, g)
        # Dark ground: all channels well below mid.
        self.assertLess(max(r, g, b), 110)
        # Sanity-pin the exact recolour (matches the shipped derivation).
        self.assertEqual((r, g, b), (19, 60, 72))

    def test_osm_forest_stays_green_not_magenta(self):
        """OSM woodland (#ADD19E, soft green): a plain invert would push
        it toward magenta (R,B up, G down). invert+hue must keep G the
        dominant channel."""
        r, g, b, _ = self.t(0xAD, 0xD1, 0x9E)   # (173, 209, 158)
        self.assertGreaterEqual(g, r, "forest lost its green")
        self.assertGreaterEqual(g, b, "forest lost its green")
        self.assertLess(max(r, g, b), 130)

    def test_dark_output_for_light_land(self):
        """OSM Carto land (#F2EFE9, near-white) must come out near-black so
        the dark map actually reads dark."""
        r, g, b, _ = self.t(0xF2, 0xEF, 0xE9)
        self.assertLess(max(r, g, b), 25)


if __name__ == "__main__":
    unittest.main()
