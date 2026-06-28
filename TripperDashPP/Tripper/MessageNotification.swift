//
//  MessageNotification.swift
//  TripperDashPP
//
//  Phone → dash incoming-message model + rolling feed, mirroring the stock
//  app's `km3.z()` behaviour (a 5-deep list of the most recent messages,
//  newest at slot 0, re-pushed on each new arrival).
//
//  SCOPE NOTE — this is the TRANSPORT/MODEL half of the feature. iOS has no
//  public API to read arbitrary incoming SMS/RCS bodies (unlike Android's
//  `SMS_RECEIVED` broadcast), so there is no automatic system-wide source.
//  `MessageFeed` is therefore fed explicitly — by the app's own push
//  Notification-Service-Extension, or a user/test-driven entry — and that
//  source wiring is a separate decision tracked in the skill reference
//  `message-notification-wire-protocol.md`. Everything below (model, rolling
//  list, K1G framing via `BikeLink.sendMessageNotification`) is fully
//  reproducible and round-trip-tested against `fake_dash` today.
//

import Foundation

/// A single incoming message to surface on the dash. Mirrors the stock
/// app's `x9g` (MessageContactDetails) data class: name, number, content,
/// timestamp.
struct MessageNotification: Sendable, Equatable, Identifiable {
    let id: UUID
    /// Contact display name. Empty → the wire builder falls back to `number`
    /// (matching `km3.h`'s "empty name ⇒ use phone number" rule).
    let senderName: String
    /// Raw phone number / address. Used as the sender field when `senderName`
    /// is empty.
    let number: String
    /// Message body. Trimmed + capped to 79 chars at encode time.
    let content: String
    /// Arrival time. Formatted `MMddhhmmss` at encode time.
    let timestamp: Date

    init(
        id: UUID = UUID(),
        senderName: String,
        number: String,
        content: String,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.senderName = senderName
        self.number = number
        self.content = content
        self.timestamp = timestamp
    }

    /// The string the wire builder encrypts into the sender field, applying
    /// the OEM `km3.h` rule: prefer the contact name, fall back to the
    /// number when the name is empty, then cap at 19 chars.
    var senderField: String {
        let base = senderName.isEmpty ? number : senderName
        if base.count > K1GPacket.MessageLimits.senderChars {
            return String(base.prefix(K1GPacket.MessageLimits.senderChars))
        }
        return base
    }

    /// The string the wire builder encrypts into the content field, applying
    /// the OEM `km3.c` rule: `trim()` then cap at 79 chars.
    var contentField: String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count > K1GPacket.MessageLimits.contentChars {
            return String(trimmed.prefix(K1GPacket.MessageLimits.contentChars))
        }
        return trimmed
    }
}

/// A rolling, newest-first list of the most recent messages, capped at the
/// dash's 5-slot capacity. `@MainActor @Observable` so the UI and the
/// `BikeLink` send path read a consistent snapshot.
///
/// The stock app re-sends the entire list on every arrival (slot-indexed).
/// We expose `slots` for that exact behaviour, plus an `unreadCount` the
/// builder ships as the plaintext `06 09` field.
@MainActor
@Observable
final class MessageFeed {

    /// Newest-first, capped at `K1GPacket.MessageSlot.count` (5). Index 0 is
    /// the most recent message and maps to slot 0 on the dash.
    private(set) var slots: [MessageNotification] = []

    /// Unread/missed count surfaced in the `06 09` plaintext field. Defaults
    /// to the number of tracked messages but can be set explicitly (e.g. to
    /// reflect a system unread badge). Reset to 0 by `clear()`.
    private(set) var unreadCount: Int = 0

    init() {}

    /// Push a new message to the front, evict anything past the 5-slot cap,
    /// and bump the unread count. Returns the resulting snapshot so a caller
    /// can immediately hand it to `BikeLink.sendMessageNotification`.
    @discardableResult
    func push(_ message: MessageNotification) -> [MessageNotification] {
        slots.insert(message, at: 0)
        if slots.count > K1GPacket.MessageSlot.count {
            slots = Array(slots.prefix(K1GPacket.MessageSlot.count))
        }
        unreadCount = min(unreadCount + 1, 0xFFFF)
        return slots
    }

    /// Override the unread count explicitly (e.g. from a real unread badge),
    /// clamped to the 16-bit wire field.
    func setUnreadCount(_ count: Int) {
        unreadCount = max(0, min(count, 0xFFFF))
    }

    /// Wipe the list and zero the count (e.g. user opened Messages, or the
    /// link dropped and we don't want to replay stale cards).
    func clear() {
        slots.removeAll()
        unreadCount = 0
    }
}
