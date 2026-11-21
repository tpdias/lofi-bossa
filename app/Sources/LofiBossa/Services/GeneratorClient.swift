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
    case generating(startedAt: Date, seed: UInt32)    // whole song, roughly 15–60 s
    case rewriting(TrackID, startedAt: Date)          // one track, roughly 3–5 s
    case failed(message: String, detail: String?, trackScope: TrackID?)
}

enum GenerationEvent {
    /// Not used today: the local server returns a finished song, not a stream. Kept so a
    /// future streaming server can light up the write-head animation without a protocol change.
    case partial(track: TrackID, notes: [Note], writtenUpTo: Double)
    case finished(SongSnapshot)
}

/// All calls are cancellable: Cancel in the banner cancels the Task, which cancels the
/// underlying URLSession task through Swift concurrency's cooperative cancellation.
///
/// There is exactly one GeneratorClient instance, shared by every open project (it owns the
/// one generator process), so `currentStatus` is a plain observable property rather than a
/// stream: an `AsyncStream` only delivers each value to one consumer, which would starve all
/// but the first project to subscribe.
protocol GeneratorClient: AnyObject, Observable {
    var currentStatus: GeneratorStatus { get }
    /// Styles that have a fine-tuned checkpoint right now (from the server's /health). A
    /// style not in this set has no fine-tuned model to ask for — see
    /// `ProjectViewModel.activeModel`, which falls back to pretrained rather than letting a
    /// request for a nonexistent checkpoint reach the server as an error.
    var finetunedStyles: Set<MusicStyle> { get }

    /// `busyness` per track: how much of the model's output the server keeps (see Project.busyness).
    /// `noteLength` per track (see Project.noteLength). `key` nil = Auto (detect it); strictKey
    /// forbids out-of-key notes instead of discouraging them.
    /// With `song` and some `locked` tracks, those come back exactly as they are in `song` and
    /// the other tracks are written around them.
    func generate(style: MusicStyle, model: NoteModel, length: Double, seed: UInt32?,
                  tracks: [TrackID], busyness: [TrackID: Double], noteLength: [TrackID: Double],
                  key: String?, strictKey: Bool, keeping song: SongSnapshot?,
                  locked: Set<TrackID>) -> AsyncThrowingStream<GenerationEvent, Error>

    /// Continues the song for `seconds` more on every track it has; returns the whole song (its
    /// own notes unchanged, instruments and mix kept) at its new length.
    func extend(_ song: SongSnapshot, by seconds: Double, model: NoteModel, seed: UInt32?,
                busyness: [TrackID: Double], noteLength: [TrackID: Double], key: String?,
                strictKey: Bool) async throws -> SongSnapshot

    /// Rewrites one track so it fits the others. Seed is derived from the song seed plus
    /// the track by the caller. With a `range` only that stretch (seconds) is rewritten; the
    /// track's notes outside it come back unchanged.
    func rewrite(track: TrackID, model: NoteModel, in song: SongSnapshot, seed: UInt32,
                 range: ClosedRange<Double>?, busyness: Double, noteLength: Double, key: String?,
                 strictKey: Bool) async throws -> (notes: [Note], detectedKey: String?)

    /// Wired to "Restart generator" in the offline banner.
    func restart() async throws

    var lastLogLine: String? { get }
    var fullLog: String { get }
}

/// Talks to `training/server.py` over HTTP, and launches it itself via GeneratorProcess so the
/// user never has to start it from a terminal.
///
/// `@Observable`, so every ProjectViewModel reading `generator.currentStatus` (through the
/// `GeneratorClient` existential) re-renders on a change, with no subscription bookkeeping.
@MainActor @Observable
final class LocalGeneratorClient: GeneratorClient {
    private let api = API()
    private let process = GeneratorProcess()
    private var watchTask: Task<Void, Never>?

    private(set) var currentStatus: GeneratorStatus = .starting
    private(set) var finetunedStyles: Set<MusicStyle> = []

    var lastLogLine: String? { process.lastLogLine }
    var fullLog: String { process.fullLog }

    init() {
        watchTask = Task { [weak self] in await self?.watch() }
    }

    // No deinit: this client is created once and held for the app's whole lifetime (by
    // RootView's @State), so there is no real teardown path to clean up after.

    private func emit(_ status: GeneratorStatus) {
        currentStatus = status
    }

    private func watch() async {
        // Try to launch our own copy first; if something is already listening (started by
        // hand, or left over from a previous run) health will succeed regardless.
        process.start()
        var emittedStarting = false
        while !Task.isCancelled {
            if let styles = await api.health() {
                finetunedStyles = styles
                emit(.ready)
                emittedStarting = false
            } else if process.isRunning && !emittedStarting {
                emit(.starting)
                emittedStarting = true
            } else if !process.isRunning {
                let reason = process.hasFailedRepeatedly ? process.lastLogLine : nil
                emit(.offline(reason: reason))
                emittedStarting = false
            }
            try? await Task.sleep(for: .seconds(process.isRunning ? 2 : 1))
        }
    }

    func restart() async throws {
        emit(.starting)
        process.restart()
    }

    func generate(style: MusicStyle, model: NoteModel, length: Double, seed: UInt32?,
                  tracks: [TrackID], busyness: [TrackID: Double], noteLength: [TrackID: Double],
                  key: String?, strictKey: Bool, keeping song: SongSnapshot?,
                  locked: Set<TrackID>) -> AsyncThrowingStream<GenerationEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let wire = try await api.generate(style: style, model: model, seconds: length, seed: seed, tracks: tracks,
                                                     busyness: busyness, noteLength: noteLength, key: key, strictKey: strictKey,
                                                     keeping: song.map(WireSong.init(from:)),
                                                     locked: tracks.filter(locked.contains))
                    let instruments = Dictionary(uniqueKeysWithValues: style.defaultInstruments.map { ($0.key, $0.value) })
                    continuation.yield(.finished(wire.snapshot(style: style, instruments: instruments, tracks: tracks)))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func extend(_ song: SongSnapshot, by seconds: Double, model: NoteModel, seed: UInt32?,
                busyness: [TrackID: Double], noteLength: [TrackID: Double], key: String?,
                strictKey: Bool) async throws -> SongSnapshot {
        let wire = try await api.extend(WireSong(from: song), by: seconds, style: song.style, model: model, seed: seed,
                                        tracks: song.trackIDs, busyness: busyness, noteLength: noteLength,
                                        key: key, strictKey: strictKey)
        return wire.extending(song)
    }

    func rewrite(track: TrackID, model: NoteModel, in song: SongSnapshot, seed: UInt32,
                 range: ClosedRange<Double>?, busyness: Double, noteLength: Double, key: String?,
                 strictKey: Bool) async throws -> (notes: [Note], detectedKey: String?) {
        let wire = try await api.regenerate(track, in: WireSong(from: song), style: song.style, model: model,
                                            seed: seed, range: range, busyness: busyness, noteLength: noteLength,
                                            key: key, strictKey: strictKey)
        return (wire.notes(track), wire.key)
    }
}
