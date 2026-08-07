//
//  String+DashSafe.swift
//  TripperDashPP
//
//  The Royal Enfield Tripper TFT renders its on-dash text with a
//  firmware font that only handles bare ASCII. A Czech place name like
//  "Nižbor" comes across with mojibake ("ž" is 2 UTF-8 bytes), and
//  names with heavier diacritics ("Okoř", "Křivoklát", "Zvoleněves")
//  can make the firmware DROP the whole text field — which is exactly
//  what a rider saw on a Zvoleněves→Okoř→Nižbor→Křivoklát→Zvoleněves
//  loop: only "Nižbor" showed up, and with broken diacritics
//  (Martin, 8/2026).
//
//  `dashSafe` folds any string down to plain 7-bit ASCII: diacritics
//  are stripped to their base letter (á→a, ř→r, ž→z, ě→e), a handful of
//  common typographic characters are mapped to ASCII equivalents, and
//  anything still outside printable ASCII is dropped. Applied at the two
//  points where text actually leaves for the dash — `K1GPacket.tlvRoadName`
//  (the control-plane road-name TLV) and `MapViewSource.drawText` (the
//  video overlay) — so EVERY on-dash string is sanitised regardless of
//  where it originated. It's a no-op on strings that are already ASCII,
//  so distances/times/etc. pass through untouched.
//

import Foundation

extension String {

    /// Fold to plain printable 7-bit ASCII for the Tripper dash font.
    /// Strips diacritics, maps common typographic punctuation to ASCII,
    /// and drops any remaining non-ASCII code points. No-op for strings
    /// already within printable ASCII.
    var dashSafe: String {
        // Fast path: already clean.
        if allSatisfy({ $0.isASCII && ($0 == " " || !$0.isNewline) }) {
            // Still need to run the punctuation map below for things like
            // a literal "…" that is technically non-ASCII, so only bail
            // when there is genuinely nothing outside ASCII.
            if utf8.allSatisfy({ $0 < 0x80 }) { return self }
        }

        // 1. Map a few common typographic characters that fold poorly or
        //    not at all, BEFORE the diacritic fold.
        var mapped = self
        let replacements: [Character: String] = [
            "…": "...",
            "–": "-", "—": "-", "―": "-",   // en/em/horizontal-bar dashes
            "’": "'", "‘": "'", "‚": "'",
            "“": "\"", "”": "\"", "„": "\"",
            "•": "*", "·": "-", "×": "x",
            "ß": "ss", "æ": "ae", "Æ": "AE", "ø": "o", "Ø": "O", "œ": "oe", "Œ": "OE",
            "°": " deg", "€": "EUR", "£": "GBP", "©": "(c)",
            "\u{00A0}": " ",                 // non-breaking space → space
        ]
        if mapped.contains(where: { replacements[$0] != nil }) {
            mapped = String(mapped.map { replacements[$0].map(Array.init) ?? [$0] }.joined())
        }

        // 2. Strip diacritics to base letters (á→a, ř→r, ž→z, ě→e, ü→u…).
        let folded = mapped.folding(options: .diacriticInsensitive,
                                    locale: Locale(identifier: "en_US_POSIX"))

        // 3. Drop anything still outside printable ASCII (0x20–0x7E),
        //    keeping ordinary spaces. Tabs/newlines collapse to a space.
        let out = folded.unicodeScalars.map { scalar -> Character in
            if scalar.value == 0x09 || scalar.value == 0x0A || scalar.value == 0x0D {
                return " "
            }
            return (scalar.value >= 0x20 && scalar.value <= 0x7E)
                ? Character(scalar) : " "
        }
        // Collapse any runs of spaces the drops may have introduced and
        // trim the ends so a stripped char doesn't leave a ragged gap.
        return String(out)
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
    }
}
