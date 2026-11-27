import Foundation

/// What the New Project flow collects before the project exists: the style, then the song's
/// settings (length, feel, key, tempo, background sound and seed). `apply(to:)` writes them
/// into a new project; nothing is generated until the user asks.
struct ProjectDraft: Equatable {
    var name = ""
    var style: MusicStyle = .lofi
    var length: Double = 90
    var busyness = Project.defaultBusyness
    var noteLength = Project.defaultNoteLength
    var key: String? = nil              // nil = Auto
    var strictKey = false
    var tempo: Double? = nil            // nil = Auto
    var groove = Project.defaultGroove
    var dynamics = Project.defaultDynamics
    var background = BackgroundSound()
    var seed: UInt32? = nil             // nil = a new one on every Generate

    static let lengthRange: ClosedRange<Double> = 15...180

    /// Every setting from the preset (its effects' background included).
    mutating func apply(_ preset: ScenePreset) {
        style = preset.style
        tempo = preset.tempo
        key = preset.key
        busyness = preset.busyness
        noteLength = preset.noteLength
        groove = preset.groove
        dynamics = preset.dynamics
        background = preset.effects.background
    }

    func apply(to project: inout Project) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { project.name = trimmed }
        project.style = style
        project.lengthSeconds = min(max(length, Self.lengthRange.lowerBound), Self.lengthRange.upperBound)
        project.busyness = busyness
        project.noteLength = noteLength
        project.key = key
        project.strictKey = key == nil ? nil : strictKey
        project.tempo = tempo.map { min(max($0, Project.tempoRange.lowerBound), Project.tempoRange.upperBound) }
        project.groove = groove
        project.dynamics = dynamics
        project.startingBackground = background.ambience == .none ? nil : background
        project.pinnedSeed = seed
    }
}

extension ProjectStore {
    /// A new project with the draft's settings, saved and first in the library.
    @discardableResult
    func create(from draft: ProjectDraft) -> Project {
        var project = create(style: draft.style)
        draft.apply(to: &project)
        update(project)
        return project
    }
}
