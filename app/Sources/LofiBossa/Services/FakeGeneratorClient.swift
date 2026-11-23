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
    private(set) var rewriteCalls: [(track: TrackID, range: ClosedRange<Double>?, busyness: Double, noteLength: Double, key: String?)] = []
    private(set) var lastGenerateBusyness: [TrackID: Double] = [:]
    private(set) var lastGenerateNoteLength: [TrackID: Double] = [:]
    private(set) var lastGenerateKey: String? = nil
    private(set) var lastGenerateStrictKey = false
    private(set) var lastGenerateMusic = MusicSettings()
    /// The tempo a generate/extend reports when the request left it on Auto.
    var detectedTempo: Double? = 90
    private(set) var lastGenerateLocked: Set<TrackID> = []
    private(set) var extendCalls: [Double] = []
    /// What `rewrite`/`generate` hand back as the key actually used; "auto" (default) echoes
    /// back whatever key was asked for, same as a real song with nothing yet to detect.
    var detectedKey: String? = "auto"

    struct Failure: LocalizedError { var errorDescription: String? { "The fake generator was told to fail." } }

    func restart() async throws {}

    func generate(style: MusicStyle, model: NoteModel, length: Double, seed: UInt32?,
                  tracks: [TrackID], busyness: [TrackID: Double], noteLength: [TrackID: Double],
                  music: MusicSettings, keeping song: SongSnapshot?,
                  locked: Set<TrackID>) -> AsyncThrowingStream<GenerationEvent, Error> {
        generateCalls += 1
        lastGenerateLocked = locked
        lastGenerateBusyness = busyness
        lastGenerateNoteLength = noteLength
        lastGenerateKey = music.key
        lastGenerateStrictKey = music.strictKey
        lastGenerateMusic = music
        let seed = seed ?? UInt32.random(in: 0...UInt32.max)
        let failure = failure, delay = delay
        let detectedKey = detectedKey
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if delay > .zero { try await Task.sleep(for: delay) }
                    if let failure { throw failure }
                    var result = Self.song(style: style, length: length, seed: seed, tracks: tracks, busyness: busyness)
                    result.detectedKey = music.key ?? detectedKey
                    result.tempo = music.tempo ?? detectedTempo
                    result.beatOffset = result.tempo == nil ? nil : 0
                    if let song {   // like the server: locked tracks come back exactly as sent
                        for i in result.tracks.indices where locked.contains(result.tracks[i].id) {
                            result.tracks[i].notes = song.track(result.tracks[i].id).notes
                        }
                    }
                    continuation.yield(.finished(result))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func extend(_ song: SongSnapshot, by seconds: Double, model: NoteModel, seed: UInt32?,
                busyness: [TrackID: Double], noteLength: [TrackID: Double],
                music: MusicSettings) async throws -> SongSnapshot {
        extendCalls.append(seconds)
        if delay > .zero { try await Task.sleep(for: delay) }
        if let failure { throw failure }
        var result = song
        let start = song.lengthSeconds, end = min(start + seconds, 180)
        for i in result.tracks.indices {
            let id = result.tracks[i].id
            let more = Self.notes(for: id, length: end - start, seed: seed ?? song.seed)
                .map { Note(pitch: $0.pitch, start: $0.start + start, duration: $0.duration, velocity: $0.velocity) }
            result.tracks[i].notes += more
        }
        result.lengthSeconds = end
        result.detectedKey = music.key ?? detectedKey
        result.tempo = music.tempo ?? song.tempo ?? detectedTempo
        return result
    }

    func rewrite(track: TrackID, model: NoteModel, in song: SongSnapshot, seed: UInt32,
                 range: ClosedRange<Double>?, busyness: Double, noteLength: Double,
                 music: MusicSettings) async throws -> (notes: [Note], detectedKey: String?) {
        rewriteCalls.append((track, range, busyness, noteLength, music.key))
        if delay > .zero { try await Task.sleep(for: delay) }
        if let failure { throw failure }
        // A rewrite never gives back the very same notes (a real one almost never does): the
        // seed-derived pitches can collide with the current ones about 1 time in 12.
        let current = Set(song.track(track).notes.map { "\($0.start)-\($0.pitch)" })
        let fresh = Self.thinned(Self.notes(for: track, length: song.lengthSeconds, seed: seed ^ 0x9E37), busyness)
            .map { n in current.contains("\(n.start)-\(n.pitch)")
                ? Note(pitch: n.pitch + 1, start: n.start, duration: n.duration, velocity: n.velocity) : n }
        let usedKey = music.key ?? detectedKey
        guard let range else { return (fresh, usedKey) }
        // Like the real server: only the range is new, everything outside it is untouched.
        let outside = song.track(track).notes.filter { $0.start < range.lowerBound || $0.start >= range.upperBound }
        let inside = fresh.filter { $0.start >= range.lowerBound && $0.start < range.upperBound }
        return (NoteEditing.sorted(outside + inside), usedKey)
    }

    /// Eight notes per two seconds per track, pitched by track and seed, so different seeds
    /// give different (and checkably different) songs.
    /// Like the server's clean-up, roughly: busyness 1 keeps every note, 0 keeps half.
    static func thinned(_ notes: [Note], _ busyness: Double) -> [Note] {
        let keep = 0.5 + min(max(busyness, 0), 1) / 2
        return notes.enumerated().filter { Double($0.offset % 10) < keep * 10 }.map(\.element)
    }

    static func song(style: MusicStyle, length: Double, seed: UInt32, tracks: [TrackID] = TrackID.core,
                     busyness: [TrackID: Double] = [:]) -> SongSnapshot {
        var song = SongSnapshot.empty(style: style, length: length, tracks: tracks)
        song.seed = seed
        for i in song.tracks.indices {
            let id = song.tracks[i].id
            song.tracks[i].notes = thinned(notes(for: id, length: length, seed: seed), busyness[id] ?? 1)
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
