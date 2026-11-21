import SwiftUI
import Observation

/// The one panel model, shown three ways:
///   Mac and iPad    inspector tabs (Sound, Versions); Notes is the bottom split pane
///   iPhone          sheets from the transport (Sound, Versions) and a pushed editor (Notes)
///   iPhone Duo open the right-hand page, with a segmented control (Sound, Versions, Notes)
enum Panel: String, CaseIterable, Identifiable {
    case sound, versions, notes
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

/// Sheets used on compact width (iPhone, iPhone Duo closed).
enum CompactSheet: Identifiable, Hashable {
    case sound, versions, export, track(TrackID)
    var id: String { "\(self)" }
}

/// Everything about one open project. It lives ABOVE the layout switch,
/// so folding or unfolding an iPhone Duo, rotating, or resizing a window never loses
/// the playhead, the selection or a generation in progress. Apple treats Duo fold changes as
/// size-class and trait changes, not a new scene, so this object simply survives.
@MainActor @Observable
final class ProjectSession {
    var project: Project
    var song: SongSnapshot

    var phase: GenerationPhase = .idle
    var generator: GeneratorStatus = .starting

    var isPlaying = false
    var playhead: Double = 0                     // seconds
    var loop: ClosedRange<Double>? = nil         // also the export range
    var isLooping = false

    var selectedTrack: TrackID? = nil            // track open in the piano roll
    var selectedNotes: Set<Note.ID> = []
    var listeningVersion: Version.ID? = nil      // comparing by ear

    var panel: Panel = .sound                    // inspector tab / Duo right page
    var sheet: CompactSheet? = nil               // iPhone only
    var isEditingNotes = false                   // iPhone: pushed editor

    init(project: Project, song: SongSnapshot) {
        self.project = project
        self.song = song
    }

    var duration: Double { song.lengthSeconds }

    func rewritingTrack() -> TrackID? {
        if case .rewriting(let id) = phase { return id }
        return nil
    }

    /// Single entry point for "open the notes of this track", whatever the device.
    func openNotes(_ track: TrackID) {
        selectedTrack = track
        panel = .notes
        isEditingNotes = true
    }
}
