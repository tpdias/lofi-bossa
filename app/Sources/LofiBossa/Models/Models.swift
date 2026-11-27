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
        case .piano: String(localized: "Piano")
        case .guitar: String(localized: "Guitar")
        case .bass: String(localized: "Bass")
        case .drums: String(localized: "Drums")
        case .keys: String(localized: "Keys & Pads")
        case .lead: String(localized: "Lead")
        case .vibes: String(localized: "Vibes")
        }
    }

    /// The name inside a sentence ("Rewrote guitar"): lowercase, except in German where nouns keep
    /// their capital.
    var inlineTitle: String {
        Locale.current.language.languageCode?.identifier == "de" ? title : title.lowercased(with: .current)
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
    /// (drum kits: GS kit numbers in the percussion bank). macOS plays them from its system GS
    /// bank, iOS from the bundled GeneralUser GS (see AudioEngine.swift).
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
    // Style names are proper names and stay as they are in every language.
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
    var title: String { self == .pretrained ? String(localized: "Pretrained") : String(localized: "Fine-tuned") }

    /// Raw value the local generator's `model` query parameter expects.
    var apiValue: String { self == .pretrained ? "pretrained" : "finetuned" }
}

/// The song's beat, from the tempo the server used or detected (`SongSnapshot.beatGrid`): drives
/// the bar and beat lines on the timeline and beat snapping in the piano roll. 4/4 throughout.
struct BeatGrid: Equatable {
    var bpm: Double
    var offset: Double = 0          // seconds to the first beat
    var beatsPerBar = 4

    var beat: Double { 60 / bpm }
    var bar: Double { beat * Double(beatsPerBar) }

    /// `t` moved to the nearest multiple of `step` seconds, counted from the first beat.
    func snap(_ t: Double, step: Double) -> Double {
        guard step > 0 else { return t }
        return offset + ((t - offset) / step).rounded() * step
    }

    /// Beat times from `from` to `to`, each with whether it starts a bar.
    func beats(from: Double, to: Double) -> [(time: Double, isBar: Bool)] {
        guard beat > 0, to > from else { return [] }
        var i = Int(((from - offset) / beat).rounded(.down))
        var out: [(Double, Bool)] = []
        while true {
            let t = offset + Double(i) * beat
            if t > to { break }
            if t >= from { out.append((t, ((i % beatsPerBar) + beatsPerBar) % beatsPerBar == 0)) }
            i += 1
        }
        return out
    }
}

/// Song-wide generation settings (`Project.music`): key, tempo, groove and dynamics. Per-track
/// ones (busyness, note length) travel separately.
struct MusicSettings: Equatable {
    var key: String? = nil          // nil = Auto
    var strictKey = false
    var tempo: Double? = nil        // nil = Auto
    var groove = Project.defaultGroove
    var dynamics = Project.defaultDynamics
}

/// The 24 major/minor keys the server can keep new notes in (training/tracks.py `KEYS`, same
/// names and order); `Project.key == nil` means "Auto" (detect it instead of naming one).
enum MusicKey {
    /// Stable English identifiers: stored in projects and sent to the server. Show a key to
    /// people with `display(_:)`.
    static let names: [String] = {
        let notes = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        return notes.flatMap { ["\($0) major", "\($0) minor"] }
    }()

    /// "A minor" in the reader's language and note naming: "La menor", "A-Moll", "A小调".
    static func display(_ name: String, locale: Locale = .current) -> String {
        let parts = name.split(separator: " ")
        guard parts.count == 2, let pc = NoteName.letters.firstIndex(of: String(parts[0])) else { return name }
        let tonic = NoteName.localized(pitchClass: pc, locale: locale)
        switch (parts[1], NoteName.family(for: locale)) {
        case ("major", .german): return "\(tonic)-Dur"
        case ("minor", .german): return "\(tonic)-Moll"
        case ("major", .solfege) where locale.language.languageCode?.identifier == "fr": return "\(tonic) majeur"
        case ("minor", .solfege) where locale.language.languageCode?.identifier == "fr": return "\(tonic) mineur"
        case ("major", .solfege) where locale.language.languageCode?.identifier == "it": return "\(tonic) maggiore"
        case ("minor", .solfege) where locale.language.languageCode?.identifier == "it": return "\(tonic) minore"
        case ("major", .solfege) where locale.language.languageCode?.identifier == "pt": return "\(tonic) maior"
        case ("minor", .solfege) where locale.language.languageCode?.identifier == "pt": return "\(tonic) menor"
        case ("major", .solfege): return "\(tonic) mayor"
        case ("minor", .solfege): return "\(tonic) menor"
        case ("major", .letters) where locale.language.languageCode?.identifier == "zh": return "\(tonic)大调"
        case ("minor", .letters) where locale.language.languageCode?.identifier == "zh": return "\(tonic)小调"
        case ("major", .letters): return "\(tonic) major"
        default: return "\(tonic) minor"
        }
    }
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
    /// How long this track's new notes should be (see `Project.noteLength`); nil follows the
    /// song's setting.
    var noteLength: Double? = nil
    /// Kept as it is by the next Generate: the model writes the other tracks around it.
    var isLocked = false
}

// Decoding is written out by hand (in an extension, so the memberwise init survives) because
// synthesized Decodable fails on a missing key: a project saved before `effects` existed would
// otherwise fail to load and silently disappear from the library. Anything added to Track
// later needs a decodeIfPresent line here too.
extension Track {
    private enum CodingKeys: String, CodingKey {
        case id, instrument, notes, volume, isMuted, isSoloed, effects, busyness, noteLength, isLocked
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
        noteLength = try c.decodeIfPresent(Double.self, forKey: .noteLength)
        isLocked = try c.decodeIfPresent(Bool.self, forKey: .isLocked) ?? false
    }
}

struct MixEffects: Codable, Hashable {
    var warmth: Double = 0.6        // low-pass amount
    var reverb: Double = 0.3
    var vinyl: Double = 0.4         // hiss and crackle
    /// A bed of rain, forest, wind, waves or noise under the song (none by default).
    var background = BackgroundSound()
}

// Written out so projects saved before `background` existed still decode (see Track).
extension MixEffects {
    private enum CodingKeys: String, CodingKey { case warmth, reverb, vinyl, background }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        warmth = try c.decodeIfPresent(Double.self, forKey: .warmth) ?? 0.6
        reverb = try c.decodeIfPresent(Double.self, forKey: .reverb) ?? 0.3
        vinyl = try c.decodeIfPresent(Double.self, forKey: .vinyl) ?? 0.4
        background = try c.decodeIfPresent(BackgroundSound.self, forKey: .background) ?? BackgroundSound()
    }
}

/// The sounds that can play under a song. All are synthesized while playing (Audio/
/// BackgroundNoise.swift), so the app ships no recordings and none need a license.
enum Ambience: String, CaseIterable, Codable, Identifiable {
    case none, rain, forest, wind, ocean, white, grey, brown
    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: String(localized: "None")
        case .rain: String(localized: "Rain")
        case .forest: String(localized: "Forest")
        case .wind: String(localized: "Wind")
        case .ocean: String(localized: "Ocean")
        case .white: String(localized: "White noise")
        case .grey: String(localized: "Grey noise")
        case .brown: String(localized: "Brown noise")
        }
    }

    /// One line on what it sounds like.
    var caption: String {
        switch self {
        case .none: String(localized: "Just the music")
        case .rain: String(localized: "Steady rain with drops on the window")
        case .forest: String(localized: "Rustling leaves and distant birds")
        case .wind: String(localized: "Slow gusts rising and falling")
        case .ocean: String(localized: "Waves rolling in and out")
        case .white: String(localized: "Bright, even hiss")
        case .grey: String(localized: "Balanced to sound even to the ear")
        case .brown: String(localized: "Deep, soft rumble")
        }
    }

    var symbol: String {
        switch self {
        case .none: "speaker.slash"
        case .rain: "cloud.rain"
        case .forest: "tree"
        case .wind: "wind"
        case .ocean: "water.waves"
        case .white: "aqi.low"
        case .grey: "aqi.medium"
        case .brown: "circle.hexagongrid.fill"
        }
    }

    /// Nature sounds first, then the plain noise colors.
    static let nature: [Ambience] = [.rain, .forest, .wind, .ocean]
    static let noises: [Ambience] = [.white, .grey, .brown]
}

struct BackgroundSound: Codable, Hashable {
    var ambience: Ambience = .none
    var level: Double = 0.5         // 0...1

    var isOn: Bool { ambience != .none && level > 0 }
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
    /// A new take that kept some tracks as they were and wrote the rest around them.
    case takeAroundLocked(seed: UInt32, kept: [TrackID])
    /// The model continued the song; `to` is its new length in seconds.
    case extend(to: Double)

    var title: String {
        switch self {
        case .newTake(let seed): String(localized: "New take · seed \(seed)")
        case .rewrite(let track): String(localized: "Rewrote \(track.inlineTitle)")
        case .noteEdit(let track): String(localized: "Edited \(track.inlineTitle) notes")
        case .restore(let n): String(localized: "Restored version \(n)")
        case .sectionEdit(_, let title): title
        case .rewriteSection(let track, let start, let end):
            String(localized: "Rewrote \(track.inlineTitle) \(formatTimecode(start))–\(formatTimecode(end))")
        case .addTrack(let track): String(localized: "Added \(track.title)")
        case .removeTrack(let track): String(localized: "Removed \(track.title)")
        case .takeAroundLocked(let seed, let kept):
            String(localized: "New take around \(kept.map(\.inlineTitle).joined(separator: ", ")) · seed \(seed)")
        case .extend(let to): String(localized: "Extended to \(formatTimecode(to))")
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
    /// The key the server actually used when writing this song's new notes (from /generate's
    /// or /regenerate_track's "key"), e.g. "A minor"; nil if it was never asked to keep one.
    /// Shown next to the Key menu when the project's own `key` is Auto.
    var detectedKey: String? = nil
    /// The tempo (BPM) and beat offset (seconds) the server used or detected for this song;
    /// nil when it had none. Drives the bar grid.
    var tempo: Double? = nil
    var beatOffset: Double? = nil

    /// The tracks this song has, in display order (core ones first, then added ones).
    var trackIDs: [TrackID] { tracks.map(\.id) }
    /// The beat to draw and snap to, when the song has a tempo.
    var beatGrid: BeatGrid? { tempo.map { BeatGrid(bpm: $0, offset: beatOffset ?? 0) } }
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
    /// How long new notes should be: 0 short, 0.5 default, 1 long. Same shape as busyness,
    /// applied by the server with legato (stretches staccato notes) and a shorter cap on drum
    /// hits; the user's own edits are never touched. Optional for the same decoding reason.
    var noteLength: Double? = nil
    var songNoteLength: Double { noteLength ?? Self.defaultNoteLength }
    static let defaultNoteLength = 0.5
    /// The key to keep new notes in; nil = detect it automatically (from the song once there
    /// is one, otherwise no constraint). One of `MusicKey.all`.
    var key: String? = nil
    /// Forbid out-of-key notes outright instead of just discouraging them.
    var strictKey: Bool? = nil
    var isStrictKey: Bool { strictKey ?? false }
    /// Beats per minute to keep new notes on (a sixteenth-note grid); nil = Auto (the server
    /// detects it from the song). The model itself has no tempo; see training/tidy.py.
    var tempo: Double? = nil
    /// How tightly new notes are pulled onto the tempo's grid: 0 loose, 1 exactly on it.
    var groove: Double? = nil
    var songGroove: Double { groove ?? Self.defaultGroove }
    static let defaultGroove = 0.5
    /// How much new notes' loudness varies (accents, phrase arcs): 0 flat, 1 expressive.
    var dynamics: Double? = nil
    var songDynamics: Double { dynamics ?? Self.defaultDynamics }
    static let defaultDynamics = 0.5
    static let tempoRange: ClosedRange<Double> = 60...140
    /// The background sound chosen when the project was made, for its first take (a take's
    /// mix lives in its snapshot; there is none before the first Generate).
    var startingBackground: BackgroundSound? = nil

    /// The song-wide settings sent with every generate, rewrite and extend.
    var music: MusicSettings {
        MusicSettings(key: key, strictKey: isStrictKey, tempo: tempo, groove: songGroove, dynamics: songDynamics)
    }

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
    // Clock digits read the same in every language (0:00); the arithmetic stays locale-free.
    let total = max(Int(seconds.rounded()), 0)
    return String(format: "%d:%02d", total / 60, total % 60)
}
