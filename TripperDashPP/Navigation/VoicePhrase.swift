//
//  VoicePhrase.swift
//  TripperDashPP
//
//  feat/voice-nav — pure phrase templates for spoken guidance.
//
//  Turns a `ManeuverKind` + a distance-prompt tier into a natural-language
//  sentence in one of the supported languages. Kept deliberately separate
//  from `VoiceNavigator` (which owns the audio session + synthesizer) so
//  this layer is a PURE function of its inputs — unit-testable on Linux with
//  no AVFoundation, and mirror-able in Python the same way the wire helpers
//  are.
//
//  Design choices:
//   - Phrases derive from `ManeuverKind` (the same enum that drives the
//     dash glyph + the phone HUD arrow), NOT Apple's free-text
//     `instructions`. Apple's strings are verb-heavy, locale-inconsistent,
//     and bake the road name into the verb clause — reusing them would make
//     the spoken cue drift from the glyph the rider sees. One enum → one
//     glyph → one phrase keeps all three channels in lock-step.
//   - Distance is expressed as a spoken tier ("in one kilometre", "in 300
//     metres") rather than a live number, so the phrase is stable and
//     doesn't need re-rounding — the caller (`VoicePromptScheduler`) already
//     decides WHEN to fire each tier.
//   - Per-language strings live in one `Lexicon` struct per language rather
//     than a wall of switch statements, so adding a language is one table.
//

import Foundation

/// Distance tier at which a maneuver prompt is announced. The scheduler
/// fires each tier at most once per maneuver as the rider closes in.
enum VoicePromptTier: Equatable {
    case far        // ~1 km out (highway lead-in) — "in one kilometre, …"
    case near       // ~300 m out — "in 300 metres, …"
    case now        // at the maneuver — just the action, no distance
}

/// Spoken language for guidance. BCP-47 code drives `AVSpeechSynthesisVoice`
/// (all of these ship stock voices on iOS 18). Ordered roughly by expected
/// use for a Central-European rider.
enum VoiceLanguage: String, CaseIterable, Identifiable, Codable {
    case czech      = "cs-CZ"
    case slovak     = "sk-SK"
    case english    = "en-GB"
    case german     = "de-DE"
    case polish     = "pl-PL"
    case french     = "fr-FR"
    case spanish    = "es-ES"
    case italian    = "it-IT"

    var id: String { rawValue }

    /// Native-language name, shown in the picker.
    var label: String {
        switch self {
        case .czech:   return "Čeština"
        case .slovak:  return "Slovenčina"
        case .english: return "English"
        case .german:  return "Deutsch"
        case .polish:  return "Polski"
        case .french:  return "Français"
        case .spanish: return "Español"
        case .italian: return "Italiano"
        }
    }
}

enum VoicePhrase {

    // MARK: - Maneuver prompt

    /// Build the spoken sentence for an upcoming maneuver at a given tier.
    /// Pure — no side effects, no actor state. Returns nil for maneuvers we
    /// deliberately don't voice at a tier (e.g. `.straight` far out is noise).
    static func maneuver(_ kind: ManeuverKind,
                         tier: VoicePromptTier,
                         language: VoiceLanguage) -> String? {
        let lex = language.lexicon
        // "Continue straight" is only worth saying if it's a fork/keep
        // decision, not on every long straight leg. Suppress plain straight.
        if case .straight = kind, tier != .now { return nil }

        let action = lex.action(kind)
        switch tier {
        case .now:
            return action
        case .near, .far:
            guard let dist = lex.distance(tier) else { return action }
            return lex.compose(distance: dist, action: action)
        }
    }

    // MARK: - Non-maneuver prompts

    static func rerouting(_ language: VoiceLanguage) -> String {
        language.lexicon.rerouting
    }

    static func arrived(_ language: VoiceLanguage) -> String {
        language.lexicon.arrived
    }

    static func speedCamera(_ language: VoiceLanguage) -> String {
        language.lexicon.speedCamera
    }
}

// MARK: - Lexicon

/// One language's spoken strings + the two glue rules (how a distance clause
/// joins an action clause, and how roundabout ordinals read). Pure data +
/// tiny formatting; no framework dependency.
struct Lexicon {
    /// distance clause for far / near ("In one kilometre" / "In 300 metres").
    let far: String
    let near: String
    /// "{distance}{join}{action}" — join is ", " for EN/DE/…, " " for CS/SK.
    let join: String
    let rerouting: String
    let arrived: String
    let speedCamera: String
    /// Ordinals 1…9 for roundabout exits (index 0 unused).
    let ordinals: [String]
    /// Build the roundabout action for a given exit; `exit` clamps 1…9.
    let roundabout: (Int, [String]) -> String
    /// The per-maneuver action clause.
    let actionFor: (ManeuverKind) -> String

    func distance(_ tier: VoicePromptTier) -> String? {
        switch tier {
        case .far:  return far
        case .near: return near
        case .now:  return nil
        }
    }

    func compose(distance: String, action: String) -> String {
        "\(distance)\(join)\(action)"
    }

    func action(_ kind: ManeuverKind) -> String {
        if case .roundabout(let exit, _) = kind {
            return roundabout(exit, ordinals)
        }
        return actionFor(kind)
    }
}

extension VoiceLanguage {
    var lexicon: Lexicon {
        switch self {
        case .czech:   return .czech
        case .slovak:  return .slovak
        case .english: return .english
        case .german:  return .german
        case .polish:  return .polish
        case .french:  return .french
        case .spanish: return .spanish
        case .italian: return .italian
        }
    }
}

// MARK: - Language tables

extension Lexicon {

    static let czech = Lexicon(
        far: "Za jeden kilometr", near: "Za tři sta metrů", join: " ",
        rerouting: "Přepočítávám trasu.", arrived: "Dojeli jste do cíle.",
        speedCamera: "Pozor, rychlostní radar.",
        ordinals: ["", "první", "druhý", "třetí", "čtvrtý", "pátý",
                   "šestý", "sedmý", "osmý", "devátý"],
        roundabout: { e, o in
            (e >= 1 && e <= 9) ? "na kruhovém objezdu \(o[e]) výjezd"
                               : "na kruhovém objezdu jeďte podle šipky"
        },
        actionFor: { k in
            switch k {
            case .straight:     return "pokračujte rovně"
            case .slightLeft:   return "držte se vlevo"
            case .left:         return "odbočte vlevo"
            case .sharpLeft:    return "ostře vlevo"
            case .slightRight:  return "držte se vpravo"
            case .right:        return "odbočte vpravo"
            case .sharpRight:   return "ostře vpravo"
            case .uTurnLeft, .uTurnRight: return "otočte se do protisměru"
            case .mergeLeft:    return "připojte se zleva"
            case .mergeRight:   return "připojte se zprava"
            case .forkLeft:     return "na křižovatce se držte vlevo"
            case .forkRight:    return "na křižovatce se držte vpravo"
            case .forkStraight: return "na křižovatce pokračujte rovně"
            case .exitLeft:     return "sjeďte vlevo"
            case .exitRight:    return "sjeďte vpravo"
            case .arrive, .arriveLeft, .arriveRight: return "jste v cíli"
            case .recalculating: return "přepočítávám trasu"
            case .ferry:        return "najeďte na trajekt"
            case .railroad:     return "pozor, železniční přejezd"
            case .roundabout:   return ""   // handled by `roundabout`
            }
        }
    )

    static let slovak = Lexicon(
        far: "O jeden kilometer", near: "O tristo metrov", join: " ",
        rerouting: "Prepočítavam trasu.", arrived: "Dorazili ste do cieľa.",
        speedCamera: "Pozor, rýchlostný radar.",
        ordinals: ["", "prvý", "druhý", "tretí", "štvrtý", "piaty",
                   "šiesty", "siedmy", "ôsmy", "deviaty"],
        roundabout: { e, o in
            (e >= 1 && e <= 9) ? "na kruhovom objazde \(o[e]) výjazd"
                               : "na kruhovom objazde choďte podľa šípky"
        },
        actionFor: { k in
            switch k {
            case .straight:     return "pokračujte rovno"
            case .slightLeft:   return "držte sa vľavo"
            case .left:         return "odbočte vľavo"
            case .sharpLeft:    return "ostro vľavo"
            case .slightRight:  return "držte sa vpravo"
            case .right:        return "odbočte vpravo"
            case .sharpRight:   return "ostro vpravo"
            case .uTurnLeft, .uTurnRight: return "otočte sa do protismeru"
            case .mergeLeft:    return "pripojte sa zľava"
            case .mergeRight:   return "pripojte sa sprava"
            case .forkLeft:     return "na križovatke sa držte vľavo"
            case .forkRight:    return "na križovatke sa držte vpravo"
            case .forkStraight: return "na križovatke pokračujte rovno"
            case .exitLeft:     return "zíďte vľavo"
            case .exitRight:    return "zíďte vpravo"
            case .arrive, .arriveLeft, .arriveRight: return "ste v cieli"
            case .recalculating: return "prepočítavam trasu"
            case .ferry:        return "nastúpte na trajekt"
            case .railroad:     return "pozor, železničné priecestie"
            case .roundabout:   return ""
            }
        }
    )

    static let english = Lexicon(
        far: "In one kilometre", near: "In 300 metres", join: ", ",
        rerouting: "Recalculating route.",
        arrived: "You have arrived at your destination.",
        speedCamera: "Caution, speed camera ahead.",
        ordinals: ["", "first", "second", "third", "fourth", "fifth",
                   "sixth", "seventh", "eighth", "ninth"],
        roundabout: { e, o in
            (e >= 1 && e <= 9) ? "at the roundabout, take the \(o[e]) exit"
                               : "at the roundabout, follow the arrow"
        },
        actionFor: { k in
            switch k {
            case .straight:     return "continue straight"
            case .slightLeft:   return "keep left"
            case .left:         return "turn left"
            case .sharpLeft:    return "make a sharp left"
            case .slightRight:  return "keep right"
            case .right:        return "turn right"
            case .sharpRight:   return "make a sharp right"
            case .uTurnLeft, .uTurnRight: return "make a U-turn"
            case .mergeLeft:    return "merge left"
            case .mergeRight:   return "merge right"
            case .forkLeft:     return "at the fork, keep left"
            case .forkRight:    return "at the fork, keep right"
            case .forkStraight: return "at the fork, continue straight"
            case .exitLeft:     return "take the exit on the left"
            case .exitRight:    return "take the exit on the right"
            case .arrive, .arriveLeft, .arriveRight: return "you have arrived"
            case .recalculating: return "recalculating route"
            case .ferry:        return "board the ferry"
            case .railroad:     return "caution, railway crossing"
            case .roundabout:   return ""
            }
        }
    )

    static let german = Lexicon(
        far: "In einem Kilometer", near: "In 300 Metern", join: ", ",
        rerouting: "Route wird neu berechnet.",
        arrived: "Sie haben Ihr Ziel erreicht.",
        speedCamera: "Achtung, Radarkontrolle.",
        ordinals: ["", "erste", "zweite", "dritte", "vierte", "fünfte",
                   "sechste", "siebte", "achte", "neunte"],
        roundabout: { e, o in
            (e >= 1 && e <= 9) ? "im Kreisverkehr die \(o[e]) Ausfahrt nehmen"
                               : "im Kreisverkehr dem Pfeil folgen"
        },
        actionFor: { k in
            switch k {
            case .straight:     return "geradeaus weiter"
            case .slightLeft:   return "halten Sie sich links"
            case .left:         return "links abbiegen"
            case .sharpLeft:    return "scharf links abbiegen"
            case .slightRight:  return "halten Sie sich rechts"
            case .right:        return "rechts abbiegen"
            case .sharpRight:   return "scharf rechts abbiegen"
            case .uTurnLeft, .uTurnRight: return "wenden Sie"
            case .mergeLeft:    return "links einfädeln"
            case .mergeRight:   return "rechts einfädeln"
            case .forkLeft:     return "an der Gabelung links halten"
            case .forkRight:    return "an der Gabelung rechts halten"
            case .forkStraight: return "an der Gabelung geradeaus"
            case .exitLeft:     return "links abfahren"
            case .exitRight:    return "rechts abfahren"
            case .arrive, .arriveLeft, .arriveRight: return "Sie sind am Ziel"
            case .recalculating: return "Route wird neu berechnet"
            case .ferry:        return "auf die Fähre fahren"
            case .railroad:     return "Achtung, Bahnübergang"
            case .roundabout:   return ""
            }
        }
    )

    static let polish = Lexicon(
        far: "Za jeden kilometr", near: "Za trzysta metrów", join: ", ",
        rerouting: "Przeliczam trasę.", arrived: "Dotarłeś do celu.",
        speedCamera: "Uwaga, fotoradar.",
        ordinals: ["", "pierwszy", "drugi", "trzeci", "czwarty", "piąty",
                   "szósty", "siódmy", "ósmy", "dziewiąty"],
        roundabout: { e, o in
            (e >= 1 && e <= 9) ? "na rondzie \(o[e]) zjazd"
                               : "na rondzie jedź zgodnie ze strzałką"
        },
        actionFor: { k in
            switch k {
            case .straight:     return "jedź prosto"
            case .slightLeft:   return "trzymaj się lewej"
            case .left:         return "skręć w lewo"
            case .sharpLeft:    return "ostro w lewo"
            case .slightRight:  return "trzymaj się prawej"
            case .right:        return "skręć w prawo"
            case .sharpRight:   return "ostro w prawo"
            case .uTurnLeft, .uTurnRight: return "zawróć"
            case .mergeLeft:    return "włącz się z lewej"
            case .mergeRight:   return "włącz się z prawej"
            case .forkLeft:     return "na rozwidleniu trzymaj się lewej"
            case .forkRight:    return "na rozwidleniu trzymaj się prawej"
            case .forkStraight: return "na rozwidleniu jedź prosto"
            case .exitLeft:     return "zjedź w lewo"
            case .exitRight:    return "zjedź w prawo"
            case .arrive, .arriveLeft, .arriveRight: return "jesteś u celu"
            case .recalculating: return "przeliczam trasę"
            case .ferry:        return "wjedź na prom"
            case .railroad:     return "uwaga, przejazd kolejowy"
            case .roundabout:   return ""
            }
        }
    )

    static let french = Lexicon(
        far: "Dans un kilomètre", near: "Dans 300 mètres", join: ", ",
        rerouting: "Recalcul de l'itinéraire.",
        arrived: "Vous êtes arrivé à destination.",
        speedCamera: "Attention, radar.",
        ordinals: ["", "première", "deuxième", "troisième", "quatrième",
                   "cinquième", "sixième", "septième", "huitième", "neuvième"],
        roundabout: { e, o in
            (e >= 1 && e <= 9) ? "au rond-point, prenez la \(o[e]) sortie"
                               : "au rond-point, suivez la flèche"
        },
        actionFor: { k in
            switch k {
            case .straight:     return "continuez tout droit"
            case .slightLeft:   return "serrez à gauche"
            case .left:         return "tournez à gauche"
            case .sharpLeft:    return "tournez franchement à gauche"
            case .slightRight:  return "serrez à droite"
            case .right:        return "tournez à droite"
            case .sharpRight:   return "tournez franchement à droite"
            case .uTurnLeft, .uTurnRight: return "faites demi-tour"
            case .mergeLeft:    return "insérez-vous à gauche"
            case .mergeRight:   return "insérez-vous à droite"
            case .forkLeft:     return "à l'embranchement, serrez à gauche"
            case .forkRight:    return "à l'embranchement, serrez à droite"
            case .forkStraight: return "à l'embranchement, continuez tout droit"
            case .exitLeft:     return "prenez la sortie à gauche"
            case .exitRight:    return "prenez la sortie à droite"
            case .arrive, .arriveLeft, .arriveRight: return "vous êtes arrivé"
            case .recalculating: return "recalcul de l'itinéraire"
            case .ferry:        return "embarquez sur le ferry"
            case .railroad:     return "attention, passage à niveau"
            case .roundabout:   return ""
            }
        }
    )

    static let spanish = Lexicon(
        far: "En un kilómetro", near: "En 300 metros", join: ", ",
        rerouting: "Recalculando la ruta.",
        arrived: "Ha llegado a su destino.",
        speedCamera: "Atención, radar de velocidad.",
        ordinals: ["", "primera", "segunda", "tercera", "cuarta", "quinta",
                   "sexta", "séptima", "octava", "novena"],
        roundabout: { e, o in
            (e >= 1 && e <= 9) ? "en la rotonda, tome la \(o[e]) salida"
                               : "en la rotonda, siga la flecha"
        },
        actionFor: { k in
            switch k {
            case .straight:     return "continúe recto"
            case .slightLeft:   return "manténgase a la izquierda"
            case .left:         return "gire a la izquierda"
            case .sharpLeft:    return "gire bruscamente a la izquierda"
            case .slightRight:  return "manténgase a la derecha"
            case .right:        return "gire a la derecha"
            case .sharpRight:   return "gire bruscamente a la derecha"
            case .uTurnLeft, .uTurnRight: return "haga un cambio de sentido"
            case .mergeLeft:    return "incorpórese por la izquierda"
            case .mergeRight:   return "incorpórese por la derecha"
            case .forkLeft:     return "en la bifurcación, manténgase a la izquierda"
            case .forkRight:    return "en la bifurcación, manténgase a la derecha"
            case .forkStraight: return "en la bifurcación, continúe recto"
            case .exitLeft:     return "tome la salida a la izquierda"
            case .exitRight:    return "tome la salida a la derecha"
            case .arrive, .arriveLeft, .arriveRight: return "ha llegado"
            case .recalculating: return "recalculando la ruta"
            case .ferry:        return "suba al ferry"
            case .railroad:     return "atención, paso a nivel"
            case .roundabout:   return ""
            }
        }
    )

    static let italian = Lexicon(
        far: "Tra un chilometro", near: "Tra 300 metri", join: ", ",
        rerouting: "Ricalcolo del percorso.",
        arrived: "È arrivato a destinazione.",
        speedCamera: "Attenzione, autovelox.",
        ordinals: ["", "prima", "seconda", "terza", "quarta", "quinta",
                   "sesta", "settima", "ottava", "nona"],
        roundabout: { e, o in
            (e >= 1 && e <= 9) ? "alla rotonda, prendi la \(o[e]) uscita"
                               : "alla rotonda, segui la freccia"
        },
        actionFor: { k in
            switch k {
            case .straight:     return "prosegui dritto"
            case .slightLeft:   return "tieni la sinistra"
            case .left:         return "svolta a sinistra"
            case .sharpLeft:    return "svolta bruscamente a sinistra"
            case .slightRight:  return "tieni la destra"
            case .right:        return "svolta a destra"
            case .sharpRight:   return "svolta bruscamente a destra"
            case .uTurnLeft, .uTurnRight: return "fai inversione a U"
            case .mergeLeft:    return "immettiti a sinistra"
            case .mergeRight:   return "immettiti a destra"
            case .forkLeft:     return "al bivio, tieni la sinistra"
            case .forkRight:    return "al bivio, tieni la destra"
            case .forkStraight: return "al bivio, prosegui dritto"
            case .exitLeft:     return "prendi l'uscita a sinistra"
            case .exitRight:    return "prendi l'uscita a destra"
            case .arrive, .arriveLeft, .arriveRight: return "sei arrivato"
            case .recalculating: return "ricalcolo del percorso"
            case .ferry:        return "sali sul traghetto"
            case .railroad:     return "attenzione, passaggio a livello"
            case .roundabout:   return ""
            }
        }
    )
}
