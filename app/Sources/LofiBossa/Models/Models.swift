import SwiftUI

// MARK: - Fixed vocabulary

enum TrackID: String, CaseIterable, Codable, Identifiable, Hashable {
    case piano, guitar, bass, drums, keys, lead, vibes
    var id: String { rawValue }

    /// Every project starts with these four; the rest are added from the Track menu.
    static let core: [TrackID] = [.piano, .guitar, .bass, .drums]
    static let optional: [TrackID] = [.keys, .lead, .vibes]
    var isCore: Bool { Self.core.contains(self) }

    var title: String {
        switch self {
        case .keys: "Keys & Pads"
        default: rawValue.capitalized
        }
    }

    /// Fill color for notes, tiles, sliders.
    var color: Color {
        switch self {
        case .piano: .lfbPiano
        case .guitar: .lfbGuitar
        case .bass: .lfbBass
        case .drums: .lfbDrums
        case .keys: .lfbKeys
        case .lead: .lfbLead
        case .vibes: .lfbVibes
        }
    }
    /// Use for text and icons so contrast stays above 4.5:1.
    var ink: Color {
        switch self {
        case .piano: .lfbPianoInk
        case .guitar: .lfbGuitarInk
        case .bass: .lfbBassInk
        case .drums: .lfbDrumsInk
        case .keys: .lfbKeysInk
        case .lead: .lfbLeadInk
        case .vibes: .lfbVibesInk
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
        case .keys: "waveform"
        case .lead: "music.quarternote.3"
        case .vibes: "sparkles"
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
        case .keys:
            [.init("Warm Pad", 89), .init("String Ensemble", 48), .init("Slow Strings", 49),
             .init("Choir Aahs", 52), .init("Church Organ", 19)]
        case .lead:
            [.init("Flute", 73), .init("Soft Sax", 65), .init("Muted Trumpet", 59),
             .init("Clarinet", 71), .init("Oboe", 68)]
        case .vibes:
            [.init("Vibraphone", 11), .init("Marimba", 12), .init("Glockenspiel", 9),
             .init("Music Box", 10)]
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
            [.piano: "Electric Piano", .guitar: "Jazz Guitar", .bass: "Fingered Bass", .drums: "Room Kit",
             .keys: "Warm Pad", .lead: "Soft Sax", .vibes: "Vibraphone"]
        case .bossa:
            [.piano: "Grand Piano", .guitar: "Nylon Guitar", .bass: "Acoustic Bass", .drums: "Brush Kit",
             .keys: "String Ensemble", .lead: "Flute", .vibes: "Vibraphone"]
        }
    }

    var defaultEffects: MixEffects {
        switch self {
        case .lofi: MixEffects(warmth: 0.7, reverb: 0.3, vinyl: 0.4)
        case .bossa: MixEffects(warmth: 0.15, reverb: 0.2, vinyl: 0)
        }
    }

    /// Starting per-track effects, applied on a project's first generate (like instruments).
    /// Lo-Fi gets a little grit and warmth on piano and drums; Bossa Nova a little room on
    /// the guitar. Everything else starts neutral.
    var defaultTrackEffects: [TrackID: TrackEffects] {
        switch self {
        case .lofi:
            [.piano: TrackEffects(warmth: 0.25, grit: 0.15),
             .drums: TrackEffects(warmth: 0.15, grit: 0.25)]
        case .bossa:
            [.guitar: TrackEffects(reverb: 0.2)]
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

/// Per-track effects, applied between the track's sampler and the master chain. All neutral
/// (zero) by default; a track with every effect at zero is audibly unprocessed.
struct TrackEffects: Codable, Hashable {
    var warmth: Double = 0      // low-pass: 0 = open, 1 = very muffled
    var grit: Double = 0        // bit-crush / decimation: the per-track lo-fi texture
    var echo: Double = 0        // short feedback delay, wet amount
    var reverb: Double = 0      // wet amount
    var pan: Double = 0         // -1 (left) ... 1 (right)

    var isNeutral: Bool { self == TrackEffects() }
}

struct Track: Identifiable, Codable, Hashable {
    var id: TrackID
    var instrument: String
    var notes: [Note] = []
    var volume: Double = 0.7        // 0...1
    var isMuted = false
    var isSoloed = false
    var effects = TrackEffects()
    /// How much of the model's output to keep for this track on the next generate or rewrite
    /// (see `Project.busyness`); nil follows the song's setting.
    var busyness: Double? = nil
}

// Decoding is written out by hand (in an extension, so the memberwise init survives) because
// synthesized Decodable fails on a missing key: a project saved before `effects` existed would
// otherwise fail to load and silently disappear from the library. Anything added to Track
// later needs a decodeIfPresent line here too.
extension Track {
    private enum CodingKeys: String, CodingKey {
        case id, instrument, notes, volume, isMuted, isSoloed, effects, busyness
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(TrackID.self, forKey: .id)
        instrument = try c.decode(String.self, forKey: .instrument)
        notes = try c.decodeIfPresent([Note].self, forKey: .notes) ?? []
        volume = try c.decodeIfPresent(Double.self, forKey: .volume) ?? 0.7
        isMuted = try c.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false
        isSoloed = try c.decodeIfPresent(Bool.self, forKey: .isSoloed) ?? false
        effects = try c.decodeIfPresent(TrackEffects.self, forKey: .effects) ?? TrackEffects()
        busyness = try c.decodeIfPresent(Double.self, forKey: .busyness)
    }
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
    /// Cut / paste / delete / duplicate / move of a section; the string is the title,
    /// e.g. "Cut guitar 0:10–0:18".
    case sectionEdit(TrackID, String)
    /// The model rewrote only `start...end` (seconds) of one track.
    case rewriteSection(TrackID, start: Double, end: Double)
    /// An optional track was added to / removed from the song.
    case addTrack(TrackID)
    case removeTrack(TrackID)

    var title: String {
        switch self {
        case .newTake(let seed): "New take · seed \(seed)"
        case .rewrite(let track): "Rewrote \(track.rawValue)"
        case .noteEdit(let track): "Edited \(track.rawValue) notes"
        case .restore(let n): "Restored version \(n)"
        case .sectionEdit(_, let title): title
        case .rewriteSection(let track, let start, let end):
            "Rewrote \(track.rawValue) \(formatTimecode(start))–\(formatTimecode(end))"
        case .addTrack(let track): "Added \(track.title)"
        case .removeTrack(let track): "Removed \(track.title)"
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

    /// The tracks this song has, in display order (core ones first, then added ones).
    var trackIDs: [TrackID] { tracks.map(\.id) }
    func hasTrack(_ id: TrackID) -> Bool { tracks.contains { $0.id == id } }

    func track(_ id: TrackID) -> Track {
        tracks.first { $0.id == id } ?? Track(id: id, instrument: id.defaultInstrument)
    }

    static func empty(style: MusicStyle, length: Double, tracks ids: [TrackID] = TrackID.core) -> SongSnapshot {
        SongSnapshot(
            tracks: TrackID.allCases.filter(ids.contains).map {
                Track(id: $0, instrument: style.defaultInstruments[$0] ?? $0.defaultInstrument,
                      effects: style.defaultTrackEffects[$0] ?? TrackEffects())
            },
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
    /// How busy the model's notes may be: 0 sparse, 0.5 default, 1 untouched. The server thins
    /// the model's output to this (fewer stacked chords, rests in endless runs) on every
    /// generate and rewrite; the user's own edits are never limited. Optional so projects saved
    /// before it existed still decode.
    var busyness: Double? = nil
    var songBusyness: Double { busyness ?? Self.defaultBusyness }
    static let defaultBusyness = 0.5

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
