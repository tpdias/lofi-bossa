import Foundation
import Observation

/// The generator on iPhone and iPad (docs/design/HANDOFF.md §7). iOS cannot run the Mac's
/// Python server, so the model has to run inside the app. That engine (Core AI) is a later
/// change; until then this client reports the designed "not ready" state, so the UI shows the
/// offline banner while play, mix, edit and export keep working.
///
/// The on-device engine should replace the body of this class, not the protocol: `.starting`
/// while the model loads into memory, `.offline(reason:)` when it failed to load, is short of
/// memory or is not downloaded yet, and `restart()` reloads it.
@MainActor @Observable
final class OnDeviceGeneratorClient: GeneratorClient {
    nonisolated static let notReadyReason = "The on-device music model isn't on this device yet."

    private(set) var currentStatus: GeneratorStatus = .offline(reason: OnDeviceGeneratorClient.notReadyReason)
    let finetunedStyles: Set<MusicStyle> = []
    var lastLogLine: String? { Self.notReadyReason }
    var fullLog: String {
        "On-device generation is not available in this build. The model will run inside the app "
            + "(Core AI) in a later version. Playing, mixing, editing and exporting still work."
    }

    struct NotReady: LocalizedError {
        var errorDescription: String? { OnDeviceGeneratorClient.notReadyReason }
    }

    func restart() async throws {
        currentStatus = .starting
        try? await Task.sleep(for: .milliseconds(600))
        currentStatus = .offline(reason: Self.notReadyReason)
    }

    func generate(style: MusicStyle, model: NoteModel, length: Double, seed: UInt32?,
                  tracks: [TrackID], busyness: [TrackID: Double], noteLength: [TrackID: Double],
                  key: String?, strictKey: Bool, keeping song: SongSnapshot?,
                  locked: Set<TrackID>) -> AsyncThrowingStream<GenerationEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: NotReady()) }
    }

    func extend(_ song: SongSnapshot, by seconds: Double, model: NoteModel, seed: UInt32?,
                busyness: [TrackID: Double], noteLength: [TrackID: Double], key: String?,
                strictKey: Bool) async throws -> SongSnapshot {
        throw NotReady()
    }

    func rewrite(track: TrackID, model: NoteModel, in song: SongSnapshot, seed: UInt32,
                 range: ClosedRange<Double>?, busyness: Double, noteLength: Double, key: String?,
                 strictKey: Bool) async throws -> (notes: [Note], detectedKey: String?) {
        throw NotReady()
    }
}
