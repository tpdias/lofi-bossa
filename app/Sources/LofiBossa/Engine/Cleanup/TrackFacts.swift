import Foundation

// Per-track facts the clean-up needs (training/tracks.py: KEYS, detect_key, VELOCITY,
// DRUM_CATEGORY / drum_category, DRUM_MIN_GAP).

extension TrackID {
    /// The velocity the model's notes get before dynamics (tracks.py `VELOCITY`).
    var baseVelocity: Int {
        switch self {
        case .piano: 72
        case .guitar: 70
        case .bass: 84
        case .drums: 88
        case .keys: 64
        case .lead: 76
        case .vibes: 70
        }
    }
}

/// Which "job" a General MIDI percussion pitch plays (tracks.py `drum_category`).
enum DrumCategory: String, CaseIterable {
    case kick, snare, hihat, cymbal, tom, perc

    init(pitch: Int) {
        switch pitch {
        case 35, 36: self = .kick
        case 37, 38, 40: self = .snare
        case 42, 44, 46: self = .hihat
        case 49, 51, 52, 55, 57, 59: self = .cymbal
        case 41, 43, 45, 47, 48, 50: self = .tom
        default: self = .perc     // shaker, cowbell, claps...
        }
    }

    /// Default minimum seconds between two hits of this category (tracks.py `DRUM_MIN_GAP`).
    var minGap: Double {
        switch self {
        case .kick, .snare: 0.2
        case .hihat: 0.08
        case .cymbal: 0.5
        case .tom: 0.15
        case .perc: 0.1
        }
    }
}

extension MusicKey {
    private static let noteNames = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
    private static let majorSteps = [0, 2, 4, 5, 7, 9, 11]
    private static let minorSteps = [0, 2, 3, 5, 7, 8, 10]   // natural minor

    /// Name ("C major", "A minor", ...) -> the pitch classes (0 = C) in that key (tracks.py `KEYS`).
    static let pitchClasses: [String: Set<Int>] = {
        var out: [String: Set<Int>] = [:]
        for (root, name) in noteNames.enumerated() {
            out["\(name) major"] = Set(majorSteps.map { (root + $0) % 12 })
            out["\(name) minor"] = Set(minorSteps.map { (root + $0) % 12 })
        }
        return out
    }()

    // Krumhansl-Schmuckler key profiles, indexed by pitch class relative to the tonic.
    private static let profileMajor = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
    private static let profileMinor = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]

    /// Best-fit key name for `notes`, weighting each pitch class by how long it sounds
    /// (Krumhansl-Schmuckler). "C major" when there are no notes (tracks.py `detect_key`).
    static func detect(in notes: [Note]) -> String {
        var weight = [Double](repeating: 0, count: 12)
        for n in notes {
            weight[PythonMath.mod(n.pitch, 12)] += max(n.duration, 0.01)
        }
        guard weight.contains(where: { $0 != 0 }) else { return "C major" }
        var best = "C major", bestScore = -Double.infinity
        for (root, name) in noteNames.enumerated() {
            for (mode, profile) in [("major", profileMajor), ("minor", profileMinor)] {
                var score = 0.0
                for pc in 0..<12 { score += weight[pc] * profile[PythonMath.mod(pc - root, 12)] }
                if score > bestScore {
                    bestScore = score
                    best = "\(name) \(mode)"
                }
            }
        }
        return best
    }
}
