//
//  RoundaboutInstructionParser.swift
//  TripperDashPP
//
//  Extracts the exit number from an `MKRoute.Step.instructions` string
//  for roundabout (kruhový objezd / rondel / Kreisverkehr) maneuvers.
//
//  Apple Maps emits localised strings like:
//    - EN: "At the roundabout, take the 2nd exit"
//    - CZ: "Na kruhovém objezdu vyjeďte 2. výjezdem"
//    - DE: "Im Kreisverkehr, nehmen Sie die 2. Ausfahrt"
//    - SK: "Na kruhovom objazde použite 2. výjazd"
//    - PL: "Na rondzie wybierz 2. zjazd"
//
//  We want to map "2nd / 2. / druhým / druhý / second" → Int(2) so the
//  K1G maneuver byte can address the right slot in the dash glyph
//  catalog (0x0A..0x13 CCW, 0x31..0x3A CW, …).
//
//  Strategy: a regex that hunts for arabic digits followed by an
//  optional ordinal suffix or period, plus a word table for spelled-out
//  ordinals up to 10 in CZ/EN/SK/DE/PL. Returns `nil` if no number is
//  parseable (caller falls back to a generic roundabout glyph).
//

import Foundation

enum RoundaboutInstructionParser {
    /// Spelled-out ordinals (lowercased) per exit number. One entry per
    /// number; each value lists every CZ/EN/SK/DE/PL form we want to
    /// recognise. Apple Maps almost always emits the digit form so this
    /// is a fallback for the rare spelled-out instruction. Extend the
    /// lists as field tests surface new languages or grammatical cases.
    private static let wordOrdinals: [Int: [String]] = [
        1: ["first", "1st",
            "první", "prvním",
            "prvý", "prvým",
            "erste", "ersten",
            "pierwszy", "pierwszym"],
        2: ["second", "2nd",
            "druhý", "druhým",
            "zweite", "zweiten",
            "drugi", "drugim"],
        3: ["third", "3rd",
            "třetí", "třetím",
            "tretí", "tretím",
            "dritte", "dritten",
            "trzeci", "trzecim"],
        4: ["fourth", "4th",
            "čtvrtý", "čtvrtým",
            "štvrtý", "štvrtým",
            "vierte", "vierten",
            "czwarty", "czwartym"],
        5: ["fifth", "5th",
            "pátý", "pátým",
            "piaty", "piatym",
            "fünfte", "fünften",
            "piąty", "piątym"],
        6: ["sixth", "6th",
            "šestý", "šestým",
            "siedme",
            "sechste", "sechsten",
            "szósty", "szóstym"],
        7: ["seventh", "7th",
            "sedmý", "sedmým",
            "siedmy", "siedmym",
            "siebte", "siebten",
            "siódmy", "siódmym"],
        8: ["eighth", "8th",
            "osmý", "osmým",
            "ôsmy", "ôsmym",
            "achte", "achten",
            "ósmy", "ósmym"],
        9: ["ninth", "9th",
            "devátý", "devátým",
            "deviaty", "deviatym",
            "neunte", "neunten",
            "dziewiąty", "dziewiątym"],
        10: ["tenth", "10th",
             "desátý", "desátým",
             "desiaty", "desiatym",
             "zehnte", "zehnten",
             "dziesiąty", "dziesiątym"],
    ]

    /// Digit-form regex: matches "2", "2.", "2nd", "2-nd", "2.výjezdem".
    /// Captures the digits. Lookahead ensures we don't bleed into the
    /// next word's digits (e.g. road numbers like "Hwy 25" still match
    /// "25" but they're filtered downstream by the 1..20 range check).
    private static let digitOrdinalRegex: NSRegularExpression = {
        let pattern = #"\b(\d{1,2})(?:-?(?:st|nd|rd|th))?\.?(?=\s|\b|$)"#
        // swiftlint:disable:next force_try
        return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    /// Extract the exit number from an instructions string. Returns
    /// `nil` if no recognisable ordinal is present — caller should fall
    /// back to a generic roundabout glyph (exit 0).
    ///
    /// Order: try the digit regex first (Apple Maps almost always emits
    /// the arabic digit), then fall back to the word-ordinal table for
    /// the rare "second exit" / "druhým výjezdem" form.
    static func parseExitNumber(from instructions: String) -> Int? {
        let lowered = instructions.lowercased()

        // Digit form.
        let nsString = lowered as NSString
        let range = NSRange(location: 0, length: nsString.length)
        if let match = digitOrdinalRegex.firstMatch(in: lowered, options: [], range: range),
           match.numberOfRanges >= 2 {
            let digitsRange = match.range(at: 1)
            if digitsRange.location != NSNotFound,
               let n = Int(nsString.substring(with: digitsRange)),
               (1...20).contains(n) {
                return n
            }
        }

        // Word form fallback. Iterate sorted by number so behaviour is
        // deterministic if two forms collide (shouldn't happen but cheap
        // insurance).
        for n in wordOrdinals.keys.sorted() {
            for form in wordOrdinals[n] ?? [] {
                let escaped = NSRegularExpression.escapedPattern(for: form)
                if lowered.range(of: "\\b\(escaped)\\b",
                                 options: .regularExpression) != nil {
                    return n
                }
            }
        }

        return nil
    }
}
