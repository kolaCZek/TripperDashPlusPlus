//
//  ManeuverKeywords.swift
//  TripperDashPP
//
//  Locale keyword tables + the TEXT half of the hybrid maneuver
//  classifier (see `ManeuverKind.classify`). Geometry decides the
//  direction of a plain turn; this file decides the maneuver FAMILY
//  (roundabout / U-turn / merge / exit / ferry / railroad / arrive) and
//  provides a word-boundary textual direction fallback for the rare case
//  where geometry is unavailable (very first step, or a degenerate
//  zero-length polyline).
//
//  Why a dedicated type:
//  - Keeps the keyword lists in ONE place, mirrored 1:1 by the Python
//    `maneuver_keywords.py` so the fake_dash sync test can diff them.
//  - The old inline `s.contains("left")` checks matched ANY substring
//    anywhere in the clause (so "…onto Leftbank Road" tripped the left
//    branch) and checked left before right unconditionally. Both are
//    fixed here: direction tokens are matched on WORD BOUNDARIES and the
//    EARLIEST token in the string wins.
//

import Foundation

enum Keywords {

    // MARK: - Family keyword sets (substring match is fine — these are
    // verbs/nouns Apple Maps emits, not road-name fragments).

    static let roundabout = [
        // EN
        "roundabout", "rotary", "traffic circle",
        // CZ / SK
        "kruhový", "kruhovém", "kruhovým", "kruháč", "kruhák", "kruhovom",
        // PL
        "rondel", "rondo", "rondzie",
        // DE
        "kreisverkehr", "kreisel",
        // ES (rotonda / glorieta)
        "rotonda", "glorieta",
        // FR (rond-point / giratoire)
        "rond-point", "rond point", "giratoire",
        // IT (rotatoria / rotonda — shares "rotonda" with ES)
        "rotatoria",
        // PT (rotunda)
        "rotunda",
        // NL (rotonde)
        "rotonde",
        // Nordics: NO rundkjøring, SV rondell, DA rundkørsel, FI liikenneympyrä
        "rundkjøring", "rondell", "rundkørsel", "liikenneympyrä",
    ]

    static let uTurn = [
        // EN
        "u-turn", "u turn", "make a u-turn",
        // CZ
        "otočte se", "otočte", "otočit", "otočení",
        // DE / PL
        "wenden", "zawróć",
        // ES (cambio de sentido / media vuelta)
        "cambio de sentido", "media vuelta",
        // FR (demi-tour)
        "demi-tour", "demi tour",
        // IT (inversione a U)
        "inversione",
        // PT (retorno / inverta o sentido)
        "retorno", "inverta",
        // NL (keer om / U-bocht)
        "keer om", "u-bocht",
        // Nordics: NO u-sving, FI käänny ympäri. (Short SV "vänd" / NO
        // "snu" omitted — they collide as substrings inside common words
        // e.g. SV "användning", so they'd cause false U-turn matches.)
        "u-sving", "käänny ympäri",
    ]

    static let merge = [
        // EN
        "merge",
        // CZ
        "zařaďte se", "zařaďte", "připojte se", "připojit",
        // DE / PL
        "einfädeln", "auffahren", "włącz się",
        // ES (incorpórese)
        "incorpór",
        // FR (insérez-vous / rejoignez)
        "insérez", "rejoignez",
        // IT (immettiti / confluisci)
        "immett", "confluis",
        // PT (incorpore-se)
        "incorpore",
        // NL (voeg in)
        "voeg in",
        // Nordics: NO flett, SV anslut
        "flett", "anslut",
    ]

    static let exitRamp = [
        // EN
        "exit", "ramp", "off-ramp", "take the ramp",
        // CZ
        "sjeďte", "sjezd", "sjezdem", "nájezd",
        // DE
        "ausfahrt", "abfahrt",
        // SK / PL
        "zjazd", "zjazdem",
        // ES (salida)
        "salida",
        // FR (sortie)
        "sortie",
        // IT (uscita / esci)
        "uscita", "esci",
        // PT (saída)
        "saída",
        // NL (afrit / afslag)
        "afrit", "afslag",
        // Nordics: NO avkjørsel, SV avfart, DA frakørsel, FI poistu
        "avkjørsel", "avfart", "frakørsel", "poistu",
    ]

    static let ferry = [
        // EN
        "ferry", "board the ferry",
        // CZ / DE / PL
        "trajekt", "přívoz", "fähre", "prom",
        // ES transbordador, IT traghetto, PT balsa, NL veerboot
        // (short FR "bac" / NL "veer" omitted — they collide as substrings
        // inside ordinary words, so they'd cause false ferry matches).
        "transbordador", "traghetto", "balsa", "veerboot",
        // Nordics: NO ferge/ferje/ferja, SV färja, DA færge, FI lautta
        "ferge", "ferje", "ferja", "färja", "færge", "lautta",
    ]

    static let railroad = [
        // EN
        "railroad", "railway", "level crossing", "grade crossing",
        // CZ / DE / PL
        "železniční přejezd", "přejezd", "bahnübergang", "przejazd kolejowy",
        // ES paso a nivel, FR passage à niveau, IT passaggio a livello,
        // PT passagem de nível, NL overweg/spoorwegovergang
        "paso a nivel", "passage à niveau", "passaggio a livello",
        "passagem de nível", "overweg", "spoorwegovergang",
        // Nordics: NO planovergang, SV järnvägskorsning, DA jernbaneoverskæring
        "planovergang", "järnvägskorsning", "jernbaneoverskæring",
    ]

    static let arrive = [
        // EN
        "arrive", "arrival", "destination", "you have arrived",
        // CZ
        "cíl", "dorazíte", "dorazili", "u cíle",
        // DE / PL
        "ziel", "cel podróży",
        // ES (ha llegado / destino)
        "llegado", "llegada", "destino",
        // FR (arrivé / destination — shares "destination" with EN)
        "arrivé", "arrivée",
        // IT (arrivat / destinazione)
        "arrivat", "destinazione",
        // PT (chegou / chegada / destino — shares "destino" with ES)
        "chegou", "chegada",
        // NL (bestemming / gearriveerd / aankomst)
        "bestemming", "gearriveerd", "aankomst",
        // Nordics: NO framme/ankomst, SV framme, FI perillä/määränpää
        "framme", "ankomst", "perillä", "määränpää",
    ]

    // MARK: - Direction tokens. Matched on WORD BOUNDARIES (see
    // `firstIndex`) so a road NAME containing one of these can't flip the
    // turn. Order within each list does not matter — we use the earliest
    // MATCH POSITION in the instruction, not list order.
    //
    // Multi-language note: tokens are whole words Apple Maps emits as the
    // turn verb in each locale. Where a language fuses the direction into
    // a single word (NL "linksaf"/"rechtsaf", FI "vasemmalle"/"oikealle"),
    // the fused form is listed explicitly because the `\b...\b` matcher
    // won't find "links" inside "linksaf".

    static let leftTokens = [
        "left",                       // EN
        "vlevo", "doleva",            // CZ
        "vľavo", "doľava",            // SK
        "links", "linksaf",           // DE / NL
        "lewo",                       // PL
        "izquierda",                  // ES
        "gauche",                     // FR
        "sinistra",                   // IT
        "esquerda",                   // PT
        "venstre",                    // NO / DA
        "vänster",                    // SV
        "vasemmalle", "vasen",        // FI
    ]
    static let rightTokens = [
        "right",                      // EN
        "vpravo", "doprava",          // CZ / SK
        "rechts", "rechtsaf",         // DE / NL
        "prawo",                      // PL
        "derecha",                    // ES
        "droite",                     // FR
        "destra",                     // IT
        "direita",                    // PT
        "høyre", "højre",             // NO / DA
        "höger",                      // SV
        "oikealle", "oikea",          // FI
    ]
    static let sharpTokens  = [
        "sharp",                      // EN
        "ostře", "ostro",             // CZ / SK
        "scharf",                     // DE
        "cerrada",                    // ES
        "serré",                      // FR
        "secca",                      // IT
        "acentuada",                  // PT
        "scherp",                     // NL
        "skarp",                      // NO / SV
    ]
    static let slightTokens = [
        "slight",                     // EN
        "mírně", "mierne",            // CZ / SK
        "leicht",                     // DE
        "lekko",                      // PL
        "ligera",                     // ES
        "légère", "légèrement",       // FR
        "leggera",                    // IT
        "ligeira",                    // PT
        "licht", "flauw",             // NL
        "svak", "svag",               // NO / SV
    ]

    // MARK: - Family predicates

    static func isRoundabout(_ s: String) -> Bool { containsAny(s, roundabout) }
    static func isUTurn(_ s: String)      -> Bool { containsAny(s, uTurn) }
    static func isMerge(_ s: String)      -> Bool { containsAny(s, merge) }
    static func isExitRamp(_ s: String)   -> Bool { containsAny(s, exitRamp) }
    static func isFerry(_ s: String)      -> Bool { containsAny(s, ferry) }
    static func isRailroad(_ s: String)   -> Bool { containsAny(s, railroad) }
    static func isArrive(_ s: String)     -> Bool { containsAny(s, arrive) }

    static func hasLeftToken(_ s: String)  -> Bool { firstIndex(s, leftTokens) != nil }
    static func hasRightToken(_ s: String) -> Bool { firstIndex(s, rightTokens) != nil }

    // MARK: - Textual turn fallback (geometry unavailable)

    /// Direction from text alone, used only when geometry can't supply an
    /// angle (first step / degenerate polyline). Two fixes vs the legacy
    /// code: (1) word-boundary matching so road names don't trip it,
    /// (2) the EARLIEST direction token in the clause wins (the turn verb
    /// comes before "onto <Road>"), not a hardcoded left-before-right.
    static func textualTurn(_ s: String) -> ManeuverKind {
        let li = firstIndex(s, leftTokens)
        let ri = firstIndex(s, rightTokens)

        let side: Side?
        switch (li, ri) {
        case let (l?, r?): side = l <= r ? .left : .right
        case (_?, nil):    side = .left
        case (nil, _?):    side = .right
        case (nil, nil):   side = nil
        }

        guard let side else { return .straight }

        let sharp = containsAny(s, sharpTokens)
        let slight = containsAny(s, slightTokens)
        switch (side, sharp, slight) {
        case (.left,  true,  _):    return .sharpLeft
        case (.left,  false, true): return .slightLeft
        case (.left,  false, false): return .left
        case (.right, true,  _):    return .sharpRight
        case (.right, false, true): return .slightRight
        case (.right, false, false): return .right
        }
    }

    private enum Side { case left, right }

    // MARK: - Matching primitives

    private static func containsAny(_ s: String, _ needles: [String]) -> Bool {
        needles.contains { s.contains($0) }
    }

    /// Index (UTF-16 offset) of the earliest WORD-BOUNDARY match of any
    /// token in `tokens`, or `nil`. Word boundary avoids matching "left"
    /// inside "Leftbank" / "cleft" or "right" inside "Wrightson".
    static func firstIndex(_ s: String, _ tokens: [String]) -> Int? {
        var best: Int?
        let ns = s as NSString
        for tok in tokens {
            let pattern = "\\b" + NSRegularExpression.escapedPattern(for: tok) + "\\b"
            guard let re = try? NSRegularExpression(pattern: pattern,
                                                    options: [.caseInsensitive]) else { continue }
            let m = re.firstMatch(in: s, options: [],
                                  range: NSRange(location: 0, length: ns.length))
            if let m, m.range.location != NSNotFound {
                if best == nil || m.range.location < best! {
                    best = m.range.location
                }
            }
        }
        return best
    }
}
