//
//  MapStyle.swift
//  TripperDashPP
//
//  The single source of truth for a rendered map palette: where its
//  raster tiles come from and what colours the renderer paints in the
//  "no tile" gaps so a dark map doesn't glow with light-coloured voids.
//
//  `MapStyle` is the RESOLVED palette the tile pipeline actually fetches
//  and paints (`.light` / `.dark`). It is NOT the user's preference —
//  that's `MapStyleSettings.mode`, which can additionally be `.auto`
//  (sunrise/sunset). `MapStyleResolver` turns a mode + GPS + time into
//  one of these concrete styles.
//
//  Why tiles come from CARTO:
//  both palettes use CARTO's keyless raster basemaps (Positron `light_all`
//  + Darkmatter `dark_all`) so Light and Dark are the SAME cartography,
//  just recoloured — Auto dusk/dawn transitions read as a smooth fade
//  rather than a jump between two different-looking maps. Both are free
//  for fair use and need no API key, keeping the project's "no map SDK,
//  no key, no quota" rule intact. The per-style provider URL lives here
//  in one table so swapping a provider later (self-host, back to OSM
//  Carto, …) is a one-line change with no ripple.
//
//  Attribution: CARTO basemaps require "© OpenStreetMap contributors
//  © CARTO". `RouteTileCache.drawAttribution` bakes `style.attribution`
//  into the composite corner so it survives heading-up rotation.
//

import CoreGraphics
import Foundation

/// A concrete rendered map palette. The tile pipeline (fetcher, disk
/// cache, composite) is parameterised on this. Each case is bound to a
/// provider URL, an on-disk cache namespace, and a set of style-aware
/// chrome colours.
enum MapStyle: String, Codable, Sendable, CaseIterable, Identifiable {
    case light
    case dark

    var id: String { rawValue }

    /// On-disk cache namespace — a directory component in `TileDiskCache`
    /// (`Caches/RouteTiles/<namespace>/<z>/<x>/<y>.png`). MUST be stable
    /// and filesystem-safe. This is the load-bearing isolation key: light
    /// and dark tiles share the same (z, x, y) slippy address, so without
    /// a per-style namespace a dark tile would overwrite the light PNG at
    /// the same coordinate (last write wins) and the reader would get the
    /// wrong palette. Never reuse a namespace value across providers.
    var cacheNamespace: String { rawValue }   // "light" / "dark"

    /// Tile provider URL template. `{s}` (optional) is a subdomain shard,
    /// `{z}`/`{x}`/`{y}` the slippy-map address. Substituted in
    /// `OSMTileFetcher`.
    var tileURLTemplate: String {
        switch self {
        case .light:
            // CARTO Positron (light_all) — keyless raster XYZ, the light
            // half of the matched Positron/Darkmatter pair. Clean, muted
            // cartography optimised for data overlays (our route line).
            return "https://{s}.basemaps.cartocdn.com/light_all/{z}/{x}/{y}.png"
        case .dark:
            // CARTO Darkmatter (dark_all) — keyless raster XYZ, the dark
            // half of the pair. Same road/label geometry as Positron, just
            // recoloured, so Auto transitions are a smooth fade.
            return "https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}.png"
        }
    }

    /// Subdomain shards for the `{s}` placeholder. Both CARTO basemaps
    /// shard across a/b/c/d; the fetcher picks one deterministically per
    /// tile so the same (x, y) always maps to the same host
    /// (URLCache-friendly).
    var subdomains: [String] {
        switch self {
        case .light: return ["a", "b", "c", "d"]
        case .dark:  return ["a", "b", "c", "d"]
        }
    }

    /// Attribution string baked into the composite corner. Both CARTO
    /// basemaps are OSM-derived and require crediting CARTO.
    var attribution: String {
        switch self {
        case .light: return "© OpenStreetMap © CARTO"
        case .dark:  return "© OpenStreetMap © CARTO"
        }
    }

    // MARK: - Style-aware chrome colours
    //
    // Every "background / no-tile / void" colour in the render pipeline
    // must come from the style. A light-beige void on a dark map reads as
    // glowing holes; a dark slate behind a light map reads as black bars.
    // The map content itself (tiles), the route polyline, and the user
    // puck are legible on both palettes and stay hard-coded at their draw
    // sites.

    /// Land fill painted behind missing tiles inside a composite bitmap.
    /// Light = CARTO Positron land colour (~#FAFAF8) so gaps blend with
    /// real tiles. Dark = CARTO Darkmatter land colour (~#26282B).
    var landFill: CGColor {
        switch self {
        case .light: return CGColor(red: 250.0/255, green: 250.0/255, blue: 248.0/255, alpha: 1.0)
        case .dark:  return CGColor(red:  38.0/255, green:  40.0/255, blue:  43.0/255, alpha: 1.0)
        }
    }

    /// Frame clear colour in `renderMapViewToPixelBuffer`, visible at the
    /// corners outside the rotated tile composite. Near-black both ways;
    /// dark style nudges it a touch cooler/darker.
    var voidColor: CGColor {
        switch self {
        case .light: return CGColor(red: 0.10, green: 0.10, blue: 0.10, alpha: 1.0)
        case .dark:  return CGColor(red: 0.06, green: 0.06, blue: 0.07, alpha: 1.0)
        }
    }

    /// Background for the pre-navigation / off-corridor vector-only frame
    /// (`drawVectorOnlyFrame`). Light = pale Positron stone (matches the
    /// land fill), dark = Darkmatter slate.
    var vectorBackground: CGColor {
        switch self {
        case .light: return CGColor(red: 0.90, green: 0.90, blue: 0.89, alpha: 1.0)
        case .dark:  return CGColor(red: 0.10, green: 0.12, blue: 0.16, alpha: 1.0)
        }
    }

    /// Ink colour for the baked-in attribution text. Dark ink over the
    /// light land fill, light ink over the dark land fill.
    var attributionInk: CGColor {
        switch self {
        case .light: return CGColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 0.75)
        case .dark:  return CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.70)
        }
    }

    /// Backing colour for the attribution pill behind the text — inverse
    /// of the ink so the text always has contrast over busy map content.
    var attributionPill: CGColor {
        switch self {
        case .light: return CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.70)
        case .dark:  return CGColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 0.55)
        }
    }
}
