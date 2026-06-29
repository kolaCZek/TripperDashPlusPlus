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

    /// Exit-noun alternation, per locale. The ordinal that names the exit
    /// ALWAYS sits immediately before this noun in every Apple Maps
    /// emission ("2nd **exit**", "2. **výjezdem**", "2. **Ausfahrt**",
    /// "2. **výjazd**", "2. **zjazd**"). Anchoring the digit to this noun
    /// is what stops a road number ("silnici 3") or an "Nth roundabout"
    /// prefix from hijacking the exit count.
    private static let exitNoun =
        #"(?:exits?|v[ýy]jezd\w*|v[ýy]jazd\w*|ausfahrt\w*|zjazd\w*|sortie\w*|uscita\w*)"#

    /// Digit immediately before the exit noun: "2 exit", "2nd exit",
    /// "2. výjezdem", "2.výjezdem". Captures the digits in group 1.
    private static let digitBeforeExitRegex: NSRegularExpression = {
        let pattern = #"(\d{1,2})(?:-?(?:st|nd|rd|th))?\.?\s*"# + exitNoun + #"\b"#
        // swiftlint:disable:next force_try
        return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    /// Does the instruction contain an exit noun at all? When it does we
    /// REFUSE to fall back to a free-floating digit (that's how a road
    /// number leaked in as the exit count). When it doesn't, the string
    /// is degenerate and a bare number is the best we can do.
    private static let hasExitNounRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        return try! NSRegularExpression(pattern: exitNoun + #"\b"#, options: [.caseInsensitive])
    }()

    /// Bare-number form ("2") used only when there is NO exit noun.
    private static let bareNumberRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        return try! NSRegularExpression(pattern: #"^\s*(\d{1,2})\s*$"#, options: [])
    }()

    /// Extract the exit number from an instructions string. Returns
    /// `nil` if no recognisable ordinal is present — caller should fall
    /// back to a generic roundabout glyph (exit 0).
    ///
    /// Strategy (order matters):
    ///   1. Digit anchored to the exit noun — covers ~every real Apple
    ///      Maps emission, and is immune to road numbers / "3rd roundabout"
    ///      prefixes because the digit must sit right before the noun.
    ///   2. Spelled-out ordinal followed (within a couple words) by the
    ///      exit noun — the rare "second exit" / "druhým výjezdem" form.
    ///   3. Bare number, ONLY when there is no exit noun at all (degenerate
    ///      input). Never used when a noun is present, so a stray number
    ///      elsewhere in a real instruction can't win.
    static func parseExitNumber(from instructions: String) -> Int? {
        let lowered = instructions.lowercased()
        let nsString = lowered as NSString
        let full = NSRange(location: 0, length: nsString.length)

        // 1. Digit anchored to the exit noun.
        if let match = digitBeforeExitRegex.firstMatch(in: lowered, options: [], range: full),
           match.numberOfRanges >= 2 {
            let digitsRange = match.range(at: 1)
            if digitsRange.location != NSNotFound,
               let n = Int(nsString.substring(with: digitsRange)),
               (1...20).contains(n) {
                return n
            }
        }

        let hasExitNoun =
            hasExitNounRegex.firstMatch(in: lowered, options: [], range: full) != nil

        // 2. Spelled-out ordinal near the exit noun.
        if hasExitNoun {
            for n in wordOrdinals.keys.sorted() {
                for form in wordOrdinals[n] ?? [] {
                    let escaped = NSRegularExpression.escapedPattern(for: form)
                    // ordinal, then up to two words, then the exit noun.
                    let pattern = "\\b\(escaped)\\b\\s*(?:\\w+\\s+){0,2}?" + exitNoun + "\\b"
                    if lowered.range(of: pattern, options: .regularExpression) != nil {
                        return n
                    }
                }
            }
            // Exit noun present but no parseable ordinal → generic glyph.
            return nil
        }

        // 3. Bare number only (no exit noun anywhere).
        if let match = bareNumberRegex.firstMatch(in: lowered, options: [], range: full),
           match.numberOfRanges >= 2 {
            let digitsRange = match.range(at: 1)
            if digitsRange.location != NSNotFound,
               let n = Int(nsString.substring(with: digitsRange)),
               (1...20).contains(n) {
                return n
            }
        }

        return nil
    }

    /// Last-resort exit estimate from the turn DIRECTION when no ordinal is
    /// in the text. Apple Maps frequently emits a roundabout step with NO
    /// exit number at all ("At the roundabout, turn left onto Silnice 608",
    /// "…continue onto…", "…turn right onto…") — `parseExitNumber` returns
    /// nil and the dash drew a numberless circle for the whole maneuver
    /// (every tick exit 0; field ride 6/2026, the 608 run was 659 ticks of
    /// blank circle). A direction word IS present, so for right-hand
    /// traffic (CCW circle) we map it to the typical exit slot:
    ///   right  → 1st exit   (peel off early)
    ///   straight/continue → 2nd exit  (across)
    ///   left   → 3rd exit   (most of the way round)
    /// A guess, not gospel: prefer `parseExitNumber`; use this only when
    /// that yields nil. Beats a numberless glyph, and the arc direction
    /// matches the rider's actual path. Returns nil when no direction word
    /// is present (then the caller's generic exit-0 circle stands).
    static func inferExitFromDirection(_ instructions: String) -> Int? {
        let s = instructions.lowercased()
        let li = Keywords.firstIndex(s, Keywords.leftTokens)
        let ri = Keywords.firstIndex(s, Keywords.rightTokens)
        switch (li, ri) {
        case let (l?, r?): return l <= r ? 3 : 1
        case (_?, nil):    return 3
        case (nil, _?):    return 1
        case (nil, nil):   return 2   // "continue"/"straight" → across
        }
    }
}
