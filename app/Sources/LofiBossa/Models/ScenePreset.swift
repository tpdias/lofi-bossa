import Foundation

/// A mood in one tap: style, tempo, key, busyness, note length, groove, dynamics and the mix
/// effects (background sound included), all set together. It only changes settings; the next
/// Generate writes the music.
struct ScenePreset: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let symbol: String
    let blurb: String
    let style: MusicStyle
    let tempo: Double
    let key: String
    let busyness: Double
    let noteLength: Double
    let groove: Double
    let dynamics: Double
    let effects: MixEffects

    static let all: [ScenePreset] = [
        ScenePreset(name: "Rainy study", symbol: "cloud.rain", blurb: "Slow, warm and sparse, with plenty of vinyl.",
                    style: .lofi, tempo: 72, key: "A minor", busyness: 0.3, noteLength: 0.7, groove: 0.4, dynamics: 0.35,
                    effects: MixEffects(warmth: 0.8, reverb: 0.45, vinyl: 0.55,
                                       background: BackgroundSound(ambience: .rain, level: 0.45))),
        ScenePreset(name: "Morning coffee", symbol: "cup.and.saucer", blurb: "Light bossa, easy and bright.",
                    style: .bossa, tempo: 96, key: "C major", busyness: 0.45, noteLength: 0.5, groove: 0.6, dynamics: 0.5,
                    effects: MixEffects(warmth: 0.3, reverb: 0.2, vinyl: 0.1)),
        ScenePreset(name: "Beach sunset", symbol: "sun.horizon", blurb: "Unhurried bossa with long, open notes, by the waves.",
                    style: .bossa, tempo: 84, key: "F major", busyness: 0.4, noteLength: 0.7, groove: 0.5, dynamics: 0.55,
                    effects: MixEffects(warmth: 0.2, reverb: 0.4, vinyl: 0,
                                       background: BackgroundSound(ambience: .ocean, level: 0.4))),
        ScenePreset(name: "Late night drive", symbol: "car", blurb: "Moody lo-fi with a steady pulse.",
                    style: .lofi, tempo: 82, key: "D minor", busyness: 0.45, noteLength: 0.55, groove: 0.6, dynamics: 0.45,
                    effects: MixEffects(warmth: 0.65, reverb: 0.35, vinyl: 0.3)),
        ScenePreset(name: "Cozy fireplace", symbol: "flame", blurb: "Very slow and soft, muffled and close.",
                    style: .lofi, tempo: 64, key: "E minor", busyness: 0.2, noteLength: 0.8, groove: 0.3, dynamics: 0.25,
                    effects: MixEffects(warmth: 0.9, reverb: 0.5, vinyl: 0.6,
                                       background: BackgroundSound(ambience: .brown, level: 0.3))),
    ]
}

extension ProjectViewModel {
    /// Applies every setting in the preset. The effects change the current version's mix (if
    /// there is one); the rest shape the next Generate, rewrite or extension.
    func apply(_ preset: ScenePreset) {
        setStyle(preset.style)
        setTempo(preset.tempo)
        setKey(preset.key)
        setBusyness(preset.busyness)
        setNoteLength(preset.noteLength)
        setGroove(preset.groove)
        setDynamics(preset.dynamics)
        setEffects(preset.effects)
        setBackground(preset.effects.background)
    }
}
