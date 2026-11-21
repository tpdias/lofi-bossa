import Foundation

/// The local background process the app depends on.
enum GeneratorStatus: Equatable {
    case ready
    case starting
    case offline(reason: String?)

    var label: String {
        switch self {
        case .ready: "Generator ready"
        case .starting: "Generator starting…"
        case .offline: "Generator offline"
        }
    }
}

/// What the stage is doing right now. Drives the banner, the Generate button and the track rows.
enum GenerationPhase: Equatable {
    case idle
    case generating(startedAt: Date)          // whole song, roughly 15–60 s
    case rewriting(TrackID)                   // one track, roughly 3–5 s
    case failed(message: String, detail: String?)
}

enum GenerationEvent {
    /// Optional: if the model can stream notes while it writes, the lanes fill in behind the write head.
    case partial(track: TrackID, notes: [Note], writtenUpTo: Double)
    case finished(SongSnapshot)
}

/// Implement against the local process (XPC, localhost HTTP or stdio).
/// All calls must be cancellable: Cancel in the banner cancels the Task.
protocol GeneratorClient: Sendable {
    var status: AsyncStream<GeneratorStatus> { get }

    func generate(style: MusicStyle, model: NoteModel, length: Double, seed: UInt32) -> AsyncThrowingStream<GenerationEvent, Error>

    /// Rewrites one track so it fits the other three. Seed is derived from the song seed plus the track.
    func rewrite(track: TrackID, in song: SongSnapshot) async throws -> [Note]

    /// Wired to "Restart generator" in the offline banner.
    func restart() async throws
}
