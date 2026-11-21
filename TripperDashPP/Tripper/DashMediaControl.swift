//
//  DashMediaControl.swift
//  TripperDashPP
//
//  Next / previous track control for the dash now-playing screen.
//
//  The Tripper's joystick, while the now-playing screen is up, emits
//  CONTEXT-DEPENDENT button codes (see `K1GPacket.DashButton`): left/right
//  become `prevTrack` (0x0a) / `nextTrack` (0x09) instead of the map's
//  zoom codes. `AppStatus.wireDashButtons()` routes those two cases here.
//
//  IMPLEMENTATION NOTE — what this can and cannot control:
//  `MPMusicPlayerController.systemMusicPlayer` is the skip API used here; it
//  needs no special entitlement. It drives
//  the SYSTEM music player — Apple Music / the built-in Music app queue.
//  It does NOT control third-party players (Spotify, YouTube Music, etc.);
//  Apple exposes no public API to send next/previous to an arbitrary
//  now-playing app. If the rider streams from a third-party app, these
//  presses are a safe no-op (the call just does nothing to that app).
//  Matches the app's keyless stance elsewhere (CLAUDE.md).
//
//  Concurrency: `systemMusicPlayer` is a main-actor UIKit-adjacent
//  singleton, so the whole type is `@MainActor` — the button callback in
//  AppStatus already hops to the main actor before invoking it.
//

import Foundation
import MediaPlayer
import os.log

/// Thin wrapper over the system music player for dash-driven track skip.
/// Stateless: it holds no queue of its own, it just forwards skip commands
/// to whatever the system Music app is currently playing.
@MainActor
final class DashMediaControl {

    private let player = MPMusicPlayerController.systemMusicPlayer
    private let log = Logger(subsystem: "eu.kolaczek.tripperdashpp", category: "DashMediaControl")

    init() {}

    /// Dash "next track" (button 0x09). Skips the system player to the next
    /// item in its queue. No-op against third-party players (see file note).
    func skipToNext() {
        log.info("Dash → skip to NEXT track (system music player)")
        player.skipToNextItem()
    }

    /// Dash "previous track" (button 0x0a). Calls `skipToPreviousItem` on
    /// the system player. Not checked on a device whether a press well into
    /// a song goes to the previous item or only restarts the current one.
    /// No-op against third-party players (see file note).
    func skipToPrevious() {
        log.info("Dash → skip to PREVIOUS track (system music player)")
        player.skipToPreviousItem()
    }
}
