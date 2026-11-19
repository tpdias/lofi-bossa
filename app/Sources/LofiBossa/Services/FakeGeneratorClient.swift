import Foundation

/// A stand-in for the model server, for tests and for `--fake-generator` UI runs: it answers
/// instantly with a deterministic song (the same seed always gives the same notes), so nothing
/// needs the Python process, a GPU or a few minutes of waiting.
@MainActor @Observable
final class FakeGeneratorClient: GeneratorClient {
    var currentStatus: GeneratorStatus = .ready
    var finetunedStyles: Set<MusicStyle> = [.lofi, .bossa]
    var lastLogLine: String? { nil }
    var fullLog: String { "" }

    /// Set to make the next generate/rewrite fail, or to take time (so a test can look at the
    /// "busy" state in between).
    var failure: Error?
    var delay: Duration = .zero
    private(set) var generateCalls = 0
    private(set) var rewriteCalls: [(track: TrackID, range: ClosedRange<Double>?)] = []

    struct Failure: LocalizedError { var errorDescription: String? { "The fake generator was told to fail." } }

    func restart() async throws {}

    func generate(style: MusicStyle, model: NoteModel, length: Double, seed: UInt32?,
                  tracks: [TrackID]) -> AsyncThrowingStream<GenerationEvent, Error> {
        generateCalls += 1
        let seed = seed ?? UInt32.random(in: 0...UInt32.max)
        let failure = failure, delay = delay
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if delay > .zero { try await Task.sleep(for: delay) }
                    if let failure { throw failure }
                    continuation.yield(.finished(Self.song(style: style, length: length, seed: seed, tracks: tracks)))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func rewrite(track: TrackID, model: NoteModel, in song: SongSnapshot, seed: UInt32,
                 range: ClosedRange<Double>?) async throws -> [Note] {
        rewriteCalls.append((track, range))
        if delay > .zero { try await Task.sleep(for: delay) }
        if let failure { throw failure }
        let fresh = Self.notes(for: track, length: song.lengthSeconds, seed: seed ^ 0x9E37)
        guard let range else { return fresh }
        // Like the real server: only the range is new, everything outside it is untouched.
        let outside = song.track(track).notes.filter { $0.start < range.lowerBound || $0.start >= range.upperBound }
        let inside = fresh.filter { $0.start >= range.lowerBound && $0.start < range.upperBound }
        return NoteEditing.sorted(outside + inside)
    }

    /// Eight notes per two seconds per track, pitched by track and seed, so different seeds
    /// give different (and checkably different) songs.
    static func song(style: MusicStyle, length: Double, seed: UInt32, tracks: [TrackID] = TrackID.core) -> SongSnapshot {
        var song = SongSnapshot.empty(style: style, length: length, tracks: tracks)
        song.seed = seed
        for i in song.tracks.indices {
            song.tracks[i].notes = notes(for: song.tracks[i].id, length: length, seed: seed)
        }
        return song
    }

    static func notes(for track: TrackID, length: Double, seed: UInt32) -> [Note] {
        let base: Int
        switch track {
        case .piano: base = 60
        case .guitar: base = 52
        case .bass: base = 36
        case .drums: base = 36
        case .keys: base = 55
        case .lead: base = 72
        case .vibes: base = 67
        }
        let step = 0.25
        return (0..<Int(length / step)).compactMap { i in
            guard i % 2 == 0 else { return nil }
            let pitch = track == .drums ? (i % 4 == 0 ? 36 : 38) : base + Int((seed &+ UInt32(i)) % 12)
            return Note(pitch: pitch, start: Double(i) * step, duration: step * 0.9, velocity: 80)
        }
    }
}
