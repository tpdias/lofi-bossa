import Foundation

/// Note names the way each language's musicians say them: solfège (Do Re Mi) in Italian, French,
/// Spanish and Portuguese; H for B (and B for B♭) in German; letter names elsewhere, including
/// Chinese. Pitches are MIDI note numbers; sharps are written "#" in every language.
enum NoteName {
    enum Family { case letters, german, solfege }

    static let letters = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
    private static let solfege = ["Do", "Do#", "Re", "Re#", "Mi", "Fa", "Fa#", "Sol", "Sol#", "La", "La#", "Si"]
    private static let italian = ["Do", "Do#", "Re", "Re#", "Mi", "Fa", "Fa#", "Sol", "Sol#", "La", "La#", "Si"]
    private static let german = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "B", "H"]

    static func family(for locale: Locale) -> Family {
        switch locale.language.languageCode?.identifier {
        case "it", "fr", "es", "pt": .solfege
        case "de": .german
        default: .letters
        }
    }

    /// "C", "Do", "H" for a pitch class 0...11 (0 = C).
    static func localized(pitchClass: Int, locale: Locale = .current) -> String {
        let i = ((pitchClass % 12) + 12) % 12
        switch family(for: locale) {
        case .letters: return letters[i]
        case .german: return german[i]
        case .solfege: return locale.language.languageCode?.identifier == "it" ? italian[i] : solfege[i]
        }
    }

    /// "E4", "Mi4", "H3" for a MIDI note number (60 = C4).
    static func localized(pitch: Int, locale: Locale = .current) -> String {
        "\(localized(pitchClass: pitch, locale: locale))\(pitch / 12 - 1)"
    }
}
