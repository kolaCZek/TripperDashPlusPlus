//
//  MapStyle.swift
//  TripperDashPP
//
//  The single source of truth for a rendered map palette: where its
//  raster tiles come from, how (if at all) the assembled composite is
//  recoloured, and what colours the renderer paints in the "no tile"
//  gaps so a dark map doesn't glow with light-coloured voids.
//
//  `MapStyle` is the RESOLVED palette the tile pipeline actually fetches
//  and paints (`.light` / `.dark`). It is NOT the user's preference —
//  that's `MapStyleSettings.mode`, which can additionally be `.auto`
//  (sunrise/sunset). `MapStyleResolver` turns a mode + GPS + time into
//  one of these concrete styles.
//
//  Why ONE provider (OSM Carto) + a runtime recolour, not two providers:
//  Light and Dark are the SAME raster cartography — plain OSM Carto. The
//  dark palette is produced by running the assembled light composite
//  through one CPU colour matrix (`TileColorTransform.darkInvert`,
//  invert + 180° hue-rotate) at composite time. This beats fetching a
//  second "dark" basemap on two fronts:
//
//    1. One tile on the wire and on disk serves BOTH palettes (the raw
//       OSM bytes are palette-independent; the recolour is a local
//       post-process). Half the network traffic, half the disk, and
//       gentler on OSM's tile policy.
//    2. The light and dark maps are guaranteed to be the same geometry,
//       so an Auto dusk/dawn switch is a pure recolour with zero chance
//       of the two palettes disagreeing about where a road is.
//
//  History: an earlier revision shipped CARTO Positron/Darkmatter as two
//  separate providers. Both palettes came out almost contrast-free and
//  unreadable on the dash, so we reverted to OSM Carto for Light and
//  synthesise Dark with the invert/hue matrix (June 2026). Swapping the
//  provider later (self-host, a different XYZ source) is still a one-line
//  change to `tileURLTemplate`.
//
//  Attribution: OSM Carto requires "© OpenStreetMap contributors".
//  `RouteTileCache.drawAttribution` bakes `style.attribution` into the
//  composite corner (AFTER the recolour, so its ink is in final palette)
//  so it survives heading-up rotation.
//

import CoreGraphics
import Foundation

/// A concrete rendered map palette. The tile pipeline (fetcher, disk
/// cache, composite) is parameterised on this. Each case is bound to a
/// provider URL, an optional composite-time colour transform, and a set
/// of style-aware chrome colours.
enum MapStyle: String, Codable, Sendable, CaseIterable, Identifiable {
    case light
    case dark

    var id: String { rawValue }

    /// On-disk cache namespace — the FIRST directory component in
    /// `TileDiskCache` (`Caches/RouteTiles/<namespace>/<z>/<x>/<y>.png`)
    /// and the prefix of `OSMTileFetcher`'s in-flight dedupe key.
    ///
    /// Both palettes return the SAME namespace (`"osm"`) on purpose: they
    /// fetch the identical raw OSM tile and the dark recolour happens
    /// later, on the assembled composite, not on the cached tile. Sharing
    /// the namespace means a light and a dark request for the same
    /// (z, x, y) collapse onto ONE fetch and ONE cached PNG — the whole
    /// efficiency win of the runtime-recolour approach. MUST be stable
    /// and filesystem-safe. Change it only when the underlying tile
    /// PROVIDER changes (so stale tiles from the old provider don't get
    /// read as the new one).
    var tileCacheNamespace: String { "osm" }

    /// Tile provider URL template. `{s}` (optional) is a subdomain shard,
    /// `{z}`/`{x}`/`{y}` the slippy-map address. Substituted in
    /// `OSMTileFetcher`. Both palettes use the SAME source — OSM Carto —
    /// because Dark is synthesised from it (see `colorTransform`), not
    /// fetched separately.
    var tileURLTemplate: String {
        // OSM Carto standard raster, keyless XYZ. No `{s}` shard (the
        // canonical host is a single `tile.openstreetmap.org`). Same URL
        // for both palettes: the bytes are palette-independent.
        return "https://tile.openstreetmap.org/{z}/{x}/{y}.png"
    }

    /// Subdomain shards for the `{s}` placeholder. OSM Carto's canonical
    /// endpoint has no shard hostnames, so this is empty for both styles
    /// and the fetcher leaves `{s}` unsubstituted (there is none in the
    /// template).
    var subdomains: [String] {
        switch self {
        case .light: return []
        case .dark:  return []
        }
    }

    /// Optional recolour applied to the assembled composite bitmap after
    /// the tiles are drawn and before attribution. `nil` for Light (the
    /// raw OSM tiles ARE the light palette — no work). `.darkInvert` for
    /// Dark (invert + 180° hue-rotate, so the light map becomes a legible
    /// dark one without flipping hues — water stays blue, parks green).
    /// Runs on the CPU via Accelerate so it works while the phone is
    /// locked; see `TileColorTransform`.
    var colorTransform: TileColorTransform? {
        switch self {
        case .light: return nil
        case .dark:  return .darkInvert
        }
    }

    /// Attribution string baked into the composite corner. OSM Carto is
    /// OSM-derived and requires crediting OpenStreetMap. (No CARTO credit
    /// anymore — we no longer use CARTO basemaps.)
    var attribution: String {
        switch self {
        case .light: return "© OpenStreetMap contributors"
        case .dark:  return "© OpenStreetMap contributors"
        }
    }

    // MARK: - Style-aware chrome colours
    //
    // Some "background / no-tile / void" colours are painted INTO the
    // composite (before the dark recolour) and some are painted by the
    // renderer OUTSIDE it (never recoloured). They are handled
    // differently:
    //
    //   * `landFill` is drawn into the composite BEFORE `colorTransform`,
    //     so it is in the LIGHT (raw-tile) palette for both styles — the
    //     dark recolour inverts it along with the tiles, keeping
    //     missing-tile gaps matched to the visible (inverted) tiles.
    //   * `voidColor` / `vectorBackground` are drawn by `MapViewSource`
    //     OUTSIDE the composite and are NOT recoloured, so they carry
    //     explicit per-palette values.
    //   * `attribution*` ink/pill are drawn into the composite AFTER the
    //     recolour, so they are in the FINAL palette (dark ink on the
    //     light map, light ink on the dark map).
    //
    // The map content itself (tiles), the route polyline, and the user
    // puck are legible on both palettes and stay hard-coded at their draw
    // sites.

    /// Land fill painted behind missing tiles INSIDE a composite bitmap,
    /// before any colour transform. Always the OSM Carto land colour
    /// (~#F2EFE9) regardless of style: for Dark it is inverted by
    /// `colorTransform` to a near-black that matches the recoloured tiles,
    /// so network drop-outs blend in instead of glaring. Palette-
    /// independent precisely because it is a PRE-transform colour.
    var landFill: CGColor {
        // OSM Carto land / populated-area fill. The dark palette inverts
        // this to ~#0D0A06 via the composite recolour.
        return CGColor(red: 242.0/255, green: 239.0/255, blue: 233.0/255, alpha: 1.0)
    }

    /// Frame clear colour in `renderMapViewToPixelBuffer`, visible at the
    /// corners outside the rotated tile composite. Drawn OUTSIDE the
    /// composite so it is NOT recoloured — explicit per palette.
    /// Near-black both ways; dark style nudges it a touch cooler/darker.
    var voidColor: CGColor {
        switch self {
        case .light: return CGColor(red: 0.10, green: 0.10, blue: 0.10, alpha: 1.0)
        case .dark:  return CGColor(red: 0.06, green: 0.06, blue: 0.07, alpha: 1.0)
        }
    }

    /// Background for the pre-navigation / off-corridor vector-only frame
    /// (`drawVectorOnlyFrame`). Drawn OUTSIDE the composite so it is NOT
    /// recoloured — explicit per palette. Light = pale OSM stone (matches
    /// the land fill's visible tone), dark = slate.
    var vectorBackground: CGColor {
        switch self {
        case .light: return CGColor(red: 0.90, green: 0.90, blue: 0.89, alpha: 1.0)
        case .dark:  return CGColor(red: 0.10, green: 0.12, blue: 0.16, alpha: 1.0)
        }
    }

    /// Ink colour for the baked-in attribution text. Drawn AFTER the
    /// composite recolour, so it is in the FINAL palette: dark ink over
    /// the light map, light ink over the dark map.
    var attributionInk: CGColor {
        switch self {
        case .light: return CGColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 0.75)
        case .dark:  return CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.70)
        }
    }

    /// Backing colour for the attribution pill behind the text — inverse
    /// of the ink so the text always has contrast over busy map content.
    /// Also drawn AFTER the recolour (final palette).
    var attributionPill: CGColor {
        switch self {
        case .light: return CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.70)
        case .dark:  return CGColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 0.55)
        }
    }
}
