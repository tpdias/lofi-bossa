import SwiftUI

/// The four tracks, in display order. Raw values match the server's track names.
enum TrackKind: String, CaseIterable, Identifiable, Codable {
    case piano, guitar, bass, drums

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    var color: Color {
        switch self {
        case .piano: Color(red: 0.42, green: 0.62, blue: 0.95)
        case .guitar: Color(red: 0.93, green: 0.66, blue: 0.30)
        case .bass: Color(red: 0.62, green: 0.48, blue: 0.90)
        case .drums: Color(red: 0.36, green: 0.76, blue: 0.62)
        }
    }

    /// Sounds from the General MIDI bank that ships with macOS.
    var presets: [InstrumentPreset] {
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
}

struct InstrumentPreset: Hashable {
    let name: String
    let program: UInt8
    init(_ name: String, _ program: UInt8) {
        self.name = name
        self.program = program
    }
}

struct Note: Codable, Hashable {
    var start: Double       // seconds
    var duration: Double    // seconds
    var pitch: Int
    var velocity: Int
}

/// A generated song, exactly as the server sends and receives it.
struct Song: Codable, Equatable {
    var seed: Int
    var seconds: Double
    var tracks: [String: [Note]]

    func notes(_ kind: TrackKind) -> [Note] { tracks[kind.rawValue] ?? [] }
}

enum Style: String, CaseIterable, Identifiable {
    case lofi, bossa

    var id: String { rawValue }
    var title: String { self == .lofi ? "Lo-Fi" : "Bossa Nova" }

    /// Sound design that goes with the style: instrument per track and effect amounts.
    var presetNames: [TrackKind: String] {
        switch self {
        case .lofi:
            [.piano: "Electric Piano", .guitar: "Jazz Guitar", .bass: "Fingered Bass", .drums: "Room Kit"]
        case .bossa:
            [.piano: "Grand Piano", .guitar: "Nylon Guitar", .bass: "Acoustic Bass", .drums: "Brush Kit"]
        }
    }

    var effects: Effects {
        switch self {
        case .lofi: Effects(warmth: 0.7, reverb: 0.3, vinyl: 0.4)
        case .bossa: Effects(warmth: 0.15, reverb: 0.2, vinyl: 0)
        }
    }
}

/// Master effect amounts, each 0...1.
struct Effects: Equatable {
    var warmth: Double   // low-pass: 0 = open, 1 = very muffled
    var reverb: Double
    var vinyl: Double    // hiss and crackle level
}

struct TrackMix: Equatable {
    var volume: Double = 0.8
    var muted = false
    var soloed = false
    var preset: InstrumentPreset
}
