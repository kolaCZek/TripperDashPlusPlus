//
//  TileColorTransform.swift
//  TripperDashPP
//
//  A CPU-side, background-safe recolour applied to an assembled tile
//  composite. The dark map palette is NOT a second set of tiles — it is
//  the light OSM raster run through one colour matrix at composite time.
//
//  Why a CPU matrix and not CoreImage / Metal:
//  the whole tile pipeline is CPU-only on purpose. CoreImage's default
//  CIContext is GPU-backed and Metal/GPU work is killed the moment the
//  phone locks (`IOGPUMetalError`) — the exact "phone in pocket while
//  riding" case this app exists for (see `OSMTileFetcher` header). So the
//  recolour is a single integer 4×4 matrix multiply over interleaved
//  ARGB8888 pixels via Accelerate's vImage, which runs fine in the
//  background and is fast enough to do per composite (one 1024×1024 pass).
//
//  Why invert *and* hue-rotate, not just invert:
//  a plain lightness invert flips hue too — OSM water (#AAD3DF, blue)
//  would come out orange, forests magenta. Composing invert with a
//  180° hue-rotate cancels the hue flip, so the dark map keeps OSM's
//  semantics: water reads blue, parks green, roads warm — just tonally
//  inverted onto a dark ground. The two operations are both affine in
//  RGB, so they collapse into ONE matrix (no two-pass cost).
//
//  The matrix + its integer form were derived and verified against a
//  float reference AND a real OSM tile before shipping; the Python
//  mirror `tools/fake_dash/tests/test_tile_color_transform.py` pins the
//  exact coefficients so a future edit can't silently drift them.
//

import Accelerate
import CoreGraphics

/// A recolour applied in place to an assembled tile composite. Currently
/// the only instance is `.darkInvert`; `.light` uses `nil` (no transform,
/// no work). Parameterised as a vImage integer matrix so it stays on the
/// CPU and runs while the device is locked.
struct TileColorTransform: Sendable {

    /// Row-major 4×4 Int16 coefficients in **R, G, B, A channel-memory
    /// order** — the byte order of the `premultipliedLast` ARGB8888
    /// bitmap that `RouteTileCache.composite` allocates on little-endian
    /// iOS. vImage computes, per pixel and per output channel `i`:
    ///
    ///     out[i] = clamp( ( Σ_j matrix[i*4 + j] · src[j] ) / divisor, 0, 255 )
    ///
    /// with no pre/post bias vector.
    let matrix: [Int16]   // exactly 16 entries
    let divisor: Int32

    /// invert(1) ∘ hue-rotate(180°).
    ///
    /// Derivation: invert is `out = 1 − in`; hue-rotate(180°) is the W3C
    /// `feColorMatrix type="hueRotate"` luma-preserving matrix with
    /// cos = −1, sin = 0. Composing them (`HueRotate · (1 − in)`) gives a
    /// linear part `−HueRotate` plus a constant `HueRotate · [1,1,1] =
    /// [1,1,1]` (luma rows sum to 1). The composite bitmap is fully
    /// opaque (alpha = 255 everywhere after the land fill), so that
    /// `+1.0` constant is folded into the **alpha column** of each RGB
    /// row (`256` → `256·255/256 = 255` added) instead of a separate
    /// post-bias. The alpha row is identity so opacity is preserved.
    ///
    /// Float→Int (×256) coefficients, verified to within 1/255 of the
    /// float reference on real OSM pixels:
    ///
    ///     R' = ( 147·R − 366·G −  37·B + 256·A ) / 256
    ///     G' = (−109·R − 110·G −  37·B + 256·A ) / 256
    ///     B' = (−109·R − 366·G + 219·B + 256·A ) / 256
    ///     A' = A
    static let darkInvert = TileColorTransform(
        matrix: [
             147, -366,  -37, 256,
            -109, -110,  -37, 256,
            -109, -366,  219, 256,
               0,    0,    0, 256,
        ],
        divisor: 256
    )

    /// Recolour the pixels backing `context` **in place**.
    ///
    /// Requirements (all satisfied by `RouteTileCache.composite`'s
    /// context): 8-bit ARGB8888, `premultipliedLast`, a readable backing
    /// store (`context.data != nil`, true for a CG-allocated bitmap
    /// context). Safe to call *between* the tile draw and the attribution
    /// draw — vImage reads and writes the same buffer (a per-pixel matrix
    /// multiply is order-independent, so in-place is defined), and any
    /// CoreGraphics drawing that follows sees the recoloured pixels and
    /// is itself untouched. No-op cost is zero because `.light` returns a
    /// `nil` transform upstream and never calls this.
    func applyInPlace(to context: CGContext) {
        guard let data = context.data else { return }
        var buffer = vImage_Buffer(
            data: data,
            height: vImagePixelCount(context.height),
            width: vImagePixelCount(context.width),
            rowBytes: context.bytesPerRow
        )
        matrix.withUnsafeBufferPointer { m in
            // src == dest: in-place. nil pre/post bias — the only constant
            // (the invert's +1.0) already lives in the alpha column.
            _ = vImageMatrixMultiply_ARGB8888(
                &buffer, &buffer,
                m.baseAddress!, divisor,
                nil, nil,
                vImage_Flags(kvImageNoFlags)
            )
        }
    }
}
