import SwiftUI

// MARK: - Fixed vocabulary

enum TrackID: String, CaseIterable, Codable, Identifiable, Hashable {
    case piano, guitar, bass, drums
    var id: String { rawValue }

    var title: String { rawValue.capitalized }

    /// Fill color for notes, tiles, sliders.
    var color: Color {
        switch self {
        case .piano: Color("Piano")
        case .guitar: Color("Guitar")
        case .bass: Color("Bass")
        case .drums: Color("Drums")
        }
    }
    /// Use for text and icons so contrast stays above 4.5:1.
    var ink: Color {
        switch self {
        case .piano: Color("PianoInk")
        case .guitar: Color("GuitarInk")
        case .bass: Color("BassInk")
        case .drums: Color("DrumsInk")
        }
    }
    /// SF Symbol. Drums has no good system symbol: ship a custom symbol named "drum".
    var symbol: String {
        switch self {
        case .piano: "pianokeys"
        case .guitar: "guitars"
        case .bass: "waveform.path"
        case .drums: "drum"
        }
    }
    /// Sampled instruments the player can swap in. Replace with the real sampler bank list.
    var instruments: [String] {
        switch self {
        case .piano: ["Grand Piano", "Electric Piano", "Vibraphone"]
        case .guitar: ["Nylon Guitar", "Soft Electric Guitar"]
        case .bass: ["Round Bass", "Upright Bass"]
        case .drums: ["Dusty Kit", "Brush Kit"]
        }
    }
}

enum MusicStyle: String, CaseIterable, Codable, Identifiable {
    case lofi, bossa
    var id: String { rawValue }
    var title: String { self == .lofi ? "Lo-Fi" : "Bossa Nova" }
}

enum NoteModel: String, CaseIterable, Codable, Identifiable {
    case pretrained, fineTuned
    var id: String { rawValue }
    var title: String { self == .pretrained ? "Pretrained" : "Fine-tuned" }
}

// MARK: - Music data (seconds, not bars; a grid can be layered on later)

struct Note: Identifiable, Codable, Hashable {
    var id = UUID()
    var pitch: Int          // MIDI note number
    var start: Double       // seconds
    var duration: Double    // seconds
    var velocity: Int       // 1...127, shown to the user as "Loudness"
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
}

/// Everything needed to play and edit one state of the song.
struct SongSnapshot: Codable, Hashable {
    var tracks: [Track]
    var effects: MixEffects
    var style: MusicStyle
    var lengthSeconds: Double
    var seed: UInt32
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
    var model: NoteModel = .pretrained
    var lengthSeconds: Double = 90          // 15...180
    var pinnedSeed: UInt32? = nil           // nil = random on every Generate
    var versions: [Version] = []
    var currentVersionID: Version.ID? = nil

    var current: SongSnapshot? { versions.first { $0.id == currentVersionID }?.snapshot }
}
