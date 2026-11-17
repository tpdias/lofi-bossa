import SwiftUI

// MARK: - Fixed vocabulary

enum TrackID: String, CaseIterable, Codable, Identifiable, Hashable {
    case piano, guitar, bass, drums
    var id: String { rawValue }

    var title: String { rawValue.capitalized }

    /// Fill color for notes, tiles, sliders.
    var color: Color {
        switch self {
        case .piano: .lfbPiano
        case .guitar: .lfbGuitar
        case .bass: .lfbBass
        case .drums: .lfbDrums
        }
    }
    /// Use for text and icons so contrast stays above 4.5:1.
    var ink: Color {
        switch self {
        case .piano: .lfbPianoInk
        case .guitar: .lfbGuitarInk
        case .bass: .lfbBassInk
        case .drums: .lfbDrumsInk
        }
    }
    /// SF Symbol. Drums has no good system symbol, so it draws a small custom glyph instead
    /// (see `TrackGlyph` in TrackRowView.swift) rather than shipping a custom SF Symbol.
    var symbol: String {
        switch self {
        case .piano: "pianokeys"
        case .guitar: "guitars"
        case .bass: "waveform.path"
        case .drums: "circle.grid.2x2.fill"
        }
    }

    /// Sampled instruments the player can swap in, each mapped to a General MIDI program
    /// in the sound bank that ships with macOS (see AudioEngine.swift).
    var instruments: [InstrumentOption] {
        switch self {
        case .piano:
            [.init("Grand Piano", 0), .init("Electric Piano", 4), .init("Soft Electric Piano", 5),
             .init("Vibraphone", 11)]
        case .guitar:
            [.init("Nylon Guitar", 24), .init("Steel Guitar", 25), .init("Jazz Guitar", 26),
             .init("Clean Electric", 27)]
        case .bass:
            [.init("Acoustic Bass", 32), .init("Fingered Bass", 33), .init("Fretless Bass", 35)]
        case .drums:
            [.init("Standard Kit", 0), .init("Room Kit", 8), .init("Jazz Kit", 32), .init("Brush Kit", 40)]
        }
    }

    var defaultInstrument: String { instruments[0].name }

    func program(for instrumentName: String) -> UInt8 {
        instruments.first { $0.name == instrumentName }?.program ?? instruments[0].program
    }
}

struct InstrumentOption: Hashable {
    let name: String
    let program: UInt8
    init(_ name: String, _ program: UInt8) {
        self.name = name
        self.program = program
    }
}

enum MusicStyle: String, CaseIterable, Codable, Identifiable {
    case lofi, bossa
    var id: String { rawValue }
    var title: String { self == .lofi ? "Lo-Fi" : "Bossa Nova" }

    /// Sound design that goes with the style: instrument per track and effect amounts,
    /// applied when a song is generated and offered back via "Reset" in the inspector.
    var defaultInstruments: [TrackID: String] {
        switch self {
        case .lofi:
            [.piano: "Electric Piano", .guitar: "Jazz Guitar", .bass: "Fingered Bass", .drums: "Room Kit"]
        case .bossa:
            [.piano: "Grand Piano", .guitar: "Nylon Guitar", .bass: "Acoustic Bass", .drums: "Brush Kit"]
        }
    }

    var defaultEffects: MixEffects {
        switch self {
        case .lofi: MixEffects(warmth: 0.7, reverb: 0.3, vinyl: 0.4)
        case .bossa: MixEffects(warmth: 0.15, reverb: 0.2, vinyl: 0)
        }
    }
}

enum NoteModel: String, CaseIterable, Codable, Identifiable {
    case pretrained, fineTuned

    var id: String { rawValue }
    var title: String { self == .pretrained ? "Pretrained" : "Fine-tuned" }

    /// Raw value the local generator's `model` query parameter expects.
    var apiValue: String { self == .pretrained ? "pretrained" : "finetuned" }
}

// MARK: - Music data (seconds, not bars; a grid can be layered on later)

struct Note: Identifiable, Codable, Hashable {
    var id = UUID()
    var pitch: Int          // MIDI note number
    var start: Double       // seconds
    var duration: Double    // seconds
    var velocity: Int       // 1...127, shown to the user as "Loudness"

    enum CodingKeys: String, CodingKey { case pitch, start, duration, velocity }
}

struct Track: Identifiable, Codable, Hashable {
    var id: TrackID
    var instrument: String
    var notes: [Note] = []
    var volume: Double = 0.7        // 0...1
    var isMuted = false
    var isSoloed = false
}

struct MixEffects: Codable, Hashable {
    var warmth: Double = 0.6        // low-pass amount
    var reverb: Double = 0.3
    var vinyl: Double = 0.4         // hiss and crackle
}

// MARK: - Versions

enum VersionKind: Codable, Hashable {
    case newTake(seed: UInt32)
    case rewrite(TrackID)
    case noteEdit(TrackID)
    case restore(fromVersion: Int)

    var title: String {
        switch self {
        case .newTake(let seed): "New take · seed \(seed)"
        case .rewrite(let track): "Rewrote \(track.rawValue)"
        case .noteEdit(let track): "Edited \(track.rawValue) notes"
        case .restore(let n): "Restored version \(n)"
        }
    }
}

/// Everything needed to play and edit one state of the song.
struct SongSnapshot: Codable, Hashable {
    var tracks: [Track]
    var effects: MixEffects
    var style: MusicStyle
    var lengthSeconds: Double
    var seed: UInt32

    func track(_ id: TrackID) -> Track {
        tracks.first { $0.id == id } ?? Track(id: id, instrument: id.defaultInstrument)
    }

    static func empty(style: MusicStyle, length: Double) -> SongSnapshot {
        SongSnapshot(
            tracks: TrackID.allCases.map { Track(id: $0, instrument: style.defaultInstruments[$0] ?? $0.defaultInstrument) },
            effects: style.defaultEffects, style: style, lengthSeconds: length, seed: 0)
    }
}

struct Version: Identifiable, Codable, Hashable {
    var id = UUID()
    var number: Int
    var createdAt: Date
    var kind: VersionKind
    var changedTracks: Set<TrackID>   // drives the four small bars in the history list
    var isKept = false                // star: protected from pruning
    var snapshot: SongSnapshot
}

// MARK: - Project

struct Project: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var createdAt = Date()
    var modifiedAt = Date()
    var style: MusicStyle = .lofi
    var model: NoteModel = .fineTuned
    var lengthSeconds: Double = 90          // 15...180
    var pinnedSeed: UInt32? = nil           // nil = random on every Generate
    var versions: [Version] = []
    var currentVersionID: Version.ID? = nil
    var deletedAt: Date? = nil              // in Recently Deleted until purged

    var current: Version? { versions.first { $0.id == currentVersionID } }
    var currentSnapshot: SongSnapshot? { current?.snapshot }
    var hasGenerated: Bool { !versions.isEmpty }

    /// "Style · length · last edited", shown on the library card.
    var subtitle: String {
        "\(style.title) · \(formatTimecode(lengthSeconds)) · \(Self.relativeFormatter.localizedString(for: modifiedAt, relativeTo: .now))"
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()
}

func formatTimecode(_ seconds: Double) -> String {
    let total = max(Int(seconds.rounded()), 0)
    return String(format: "%d:%02d", total / 60, total % 60)
}
