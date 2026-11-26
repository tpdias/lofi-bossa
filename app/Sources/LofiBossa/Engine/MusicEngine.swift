import Foundation

/// What `training/server.py` does around the sampler, in Swift: whole-song generation (with
/// locked tracks), rewriting one track or a stretch of it, and extending the song. Pure and
/// model-agnostic, so tests drive it with a fake `LogitsModel`.
enum MusicEngine {
    static let maxSeconds = 180.0

    struct Result {
        var tracks: [TrackID: [Note]]
        var seconds: Double
        var key: String?
        var tempo: BeatGrid?
    }

    // MARK: Settings shared by every request (server.py resolve_key / resolve_tempo / grid_args)

    /// (pitch classes, name) for a chosen key, or one detected from `notes` on Auto (none yet: nil).
    static func resolveKey(_ chosen: String?, notes: [Note]) -> (pitchClasses: Set<Int>, name: String)? {
        let name = chosen ?? (notes.isEmpty ? nil : MusicKey.detect(in: notes))
        guard let name, let pcs = MusicKey.pitchClasses[name] else { return nil }
        return (pcs, name)
    }

    /// A chosen tempo phased to `notes`, or one estimated from them on Auto (too few notes: nil).
    static func resolveTempo(_ chosen: Double?, notes: [Note]) -> BeatGrid? {
        if let bpm = chosen { return BeatGrid(bpm: bpm, offset: notes.isEmpty ? 0 : BeatGrid.phase(of: notes, bpm: bpm)) }
        return notes.isEmpty ? nil : BeatGrid.estimate(from: notes)
    }

    static func samplerOptions(music: MusicSettings, key: Set<Int>?, tempo: BeatGrid?, drums: Bool,
                               minDurationTicks: Int = 0) -> SamplerOptions {
        var o = SamplerOptions()
        o.key = key
        o.keyStrict = music.strictKey
        o.minDurationTicks = minDurationTicks
        if drums {
            o.drumMinGapTicks = Dictionary(uniqueKeysWithValues: (27...87).map {
                ($0, Int(PythonMath.round(DrumCategory(pitch: $0).minGap * Double(Vocab.timeResolution))))
            })
        }
        if let tempo, music.groove > 0 {
            o.grid = (Double(Vocab.timeResolution) * Tidy.gridStep(tempo), tempo.offset * Double(Vocab.timeResolution))
            o.gridBonus = Float(Tidy.knob(music.groove, sparse: 0, normal: 1.5, busy: 3))
        }
        return o
    }

    private static func allNotes(_ tracks: [TrackID: [Note]]) -> [Note] { tracks.values.flatMap { $0 } }
    private static func end(_ notes: [Note]) -> Double { notes.map { $0.start + $0.duration }.max() ?? 0 }

    // MARK: Generate (server.py /generate)

    static func generate(model: LogitsModel, seconds: Double, seed: UInt64, tracks wanted: [TrackID],
                         busyness: [TrackID: Double], noteLength: [TrackID: Double], music: MusicSettings,
                         keeping song: [TrackID: [Note]]? = nil, locked: Set<TrackID> = [],
                         progress: ((Double) -> Void)? = nil, log: ((String) -> Void)? = nil) async throws -> Result {
        let began = Date()
        func stage(_ text: String) { log?(String(format: "%5.1f s  ", Date().timeIntervalSince(began)) + text) }
        let lockedTracks = song == nil ? [] : wanted.filter(locked.contains)
        let free = wanted.filter { !lockedTracks.contains($0) }
        guard !free.isEmpty else { throw EngineError("every track is locked: unlock one to write something new") }
        let lockedNotes = lockedTracks.flatMap { song?[$0] ?? [] }
        let fixed = NoteEvents.events(for: Dictionary(uniqueKeysWithValues: lockedTracks.map { ($0, song?[$0] ?? []) }))
        var key = resolveKey(music.key, notes: lockedNotes)
        var tempo = resolveTempo(music.tempo, notes: lockedNotes)
        let options = samplerOptions(music: music, key: key?.pitchClasses, tempo: tempo, drums: free.contains(.drums))

        stage("writing \(free.map(\.rawValue).joined(separator: ", ")) for \(Int(seconds)) s")
        var events = try await Sampler.generate(
            model: model, start: 0, end: seconds, controls: fixed.map(\.asControl),
            instruments: free.flatMap(\.modelInstruments), options: options, seed: seed, progress: progress)
        stage("main pass: \(events.count) notes")
        // The model often leaves an instrument out: write a part for any silent track.
        var byTrack = NoteEvents.notes(from: events)
        for t in free where Double(byTrack[t]?.count ?? 0) < 0.25 * seconds {
            stage("\(t.rawValue) is nearly silent (\(byTrack[t]?.count ?? 0) notes): writing a part for it")
            let others = fixed + events.filter { e in free.contains { $0 != t && $0.modelInstruments.contains(e.instrument) } }
            // It already came back silent once: start with rests discouraged instead of repeating
            // that attempt (each full pass on the device costs tens of seconds).
            let part = try await Sampler.accompany(model: model, fixed: EventOps.sort(others), seconds: seconds,
                                                   instruments: t.modelInstruments, options: options, seed: seed,
                                                   restPenalties: [4, .infinity])
            events = events.filter { !t.modelInstruments.contains($0.instrument) } + part
            byTrack[t] = NoteEvents.notes(from: part)[t] ?? []
            stage("\(t.rawValue): \(byTrack[t]?.count ?? 0) notes")
        }

        let written = free.flatMap { byTrack[$0] ?? [] }
        key = resolveKey(music.key, notes: lockedNotes + written)
        tempo = tempo ?? resolveTempo(music.tempo, notes: lockedNotes + written)
        var out = Tidy.tidySong(Dictionary(uniqueKeysWithValues: free.map { ($0, byTrack[$0] ?? []) }),
                                busyness: .each(busyness), seed: Int(seed), noteLength: .each(noteLength),
                                key: key?.pitchClasses, keyStrict: music.strictKey, tempo: tempo,
                                groove: music.groove, dynamics: music.dynamics)
        for t in lockedTracks { out[t] = song?[t] ?? [] }
        stage("cleaned up: " + out.map { "\($0.key.rawValue) \($0.value.count)" }.sorted().joined(separator: ", "))
        let length = max(seconds, end(allNotes(out)))
        return Result(tracks: out, seconds: length, key: key?.name, tempo: tempo)
    }

    // MARK: Rewrite one track (server.py /regenerate_track)

    static func rewrite(model: LogitsModel, track: TrackID, song: [TrackID: [Note]], seconds songSeconds: Double,
                        seed: UInt64, range: ClosedRange<Double>?, busyness: Double, noteLength: Double,
                        music: MusicSettings, progress: ((Double) -> Void)? = nil) async throws -> (notes: [Note], key: String?) {
        let existing = allNotes(song)
        guard !existing.isEmpty || range == nil else { throw EngineError("the song is empty") }
        let key = resolveKey(music.key, notes: existing)
        let tempo = resolveTempo(music.tempo, notes: existing)
        let minDur = track == .drums ? 0 : Int(PythonMath.round(Tidy.minDuration(track, noteLength: noteLength) * Double(Vocab.timeResolution)))
        let options = samplerOptions(music: music, key: key?.pitchClasses, tempo: tempo, drums: track == .drums, minDurationTicks: minDur)
        let events = NoteEvents.events(for: song)
        let seconds = min(max(ceil(end(existing)), ceil(songSeconds), 1), maxSeconds)

        let fresh: [Event]
        if let range {
            let upper = min(range.upperBound, seconds)
            guard upper - range.lowerBound >= 0.5 else { throw EngineError("the range to rewrite must be at least half a second") }
            fresh = try await Sampler.rewriteRange(model: model, events: events, instruments: track.modelInstruments,
                                                   start: range.lowerBound, end: upper, options: options, seed: seed, progress: progress)
        } else {
            let others = events.filter { !track.modelInstruments.contains($0.instrument) }
            fresh = try await Sampler.accompany(model: model, fixed: others, seconds: seconds, instruments: track.modelInstruments,
                                                options: options, seed: seed, progress: progress)
        }
        var rng = Tidy.SeededRandom("\(seed)-\(track.rawValue)")
        let cleaned = Tidy.tidyTrack(track, NoteEvents.notes(from: fresh)[track] ?? [], busyness: busyness, rng: &rng,
                                     noteLength: noteLength, key: key?.pitchClasses, keyStrict: music.strictKey,
                                     tempo: tempo, groove: music.groove, dynamics: music.dynamics)
        guard let range else { return (cleaned, key?.name) }
        // Keep this track's notes outside the range (one ringing into it stops where it starts).
        let kept: [Note] = (song[track] ?? []).compactMap { n in
            if range.lowerBound <= n.start && n.start < range.upperBound { return nil }
            var n = n
            if n.start < range.lowerBound && range.lowerBound < n.start + n.duration { n.duration = range.lowerBound - n.start }
            return n
        }
        return ((kept + cleaned).sorted { ($0.start, $0.pitch) < ($1.start, $1.pitch) }, key?.name)
    }

    // MARK: Extend (server.py /extend)

    static func extend(model: LogitsModel, song: [TrackID: [Note]], seconds songSeconds: Double, by more: Double,
                       seed: UInt64, tracks wanted: [TrackID], busyness: [TrackID: Double], noteLength: [TrackID: Double],
                       music: MusicSettings, progress: ((Double) -> Void)? = nil) async throws -> Result {
        let old = allNotes(song)
        guard !old.isEmpty else { throw EngineError("the song is empty: generate it first") }
        let start = max(songSeconds, end(old))
        let stop = min(start + more, maxSeconds)
        guard stop - start >= 1 else { throw EngineError("the song is already at the \(Int(maxSeconds))-second maximum") }
        let key = resolveKey(music.key, notes: old)
        let tempo = resolveTempo(music.tempo, notes: old)
        let options = samplerOptions(music: music, key: key?.pitchClasses, tempo: tempo, drums: wanted.contains(.drums))
        let merged = try await Sampler.generate(model: model, start: start, end: stop, inputs: NoteEvents.events(for: song),
                                                instruments: wanted.flatMap(\.modelInstruments), options: options,
                                                seed: seed, progress: progress)
        let startTick = Int(PythonMath.round(start * Double(Vocab.timeResolution)))
        let added = NoteEvents.notes(from: merged.filter { $0.tick >= startTick })
        let cleaned = Tidy.tidySong(Dictionary(uniqueKeysWithValues: wanted.map { ($0, added[$0] ?? []) }),
                                    busyness: .each(busyness), seed: Int(seed), noteLength: .each(noteLength),
                                    key: key?.pitchClasses, keyStrict: music.strictKey, tempo: tempo,
                                    groove: music.groove, dynamics: music.dynamics)
        var out = song
        for t in wanted {
            out[t] = ((song[t] ?? []) + (cleaned[t] ?? []).filter { $0.start < stop })
                .sorted { ($0.start, $0.pitch) < ($1.start, $1.pitch) }
        }
        return Result(tracks: out, seconds: stop, key: key?.name, tempo: tempo)
    }
}

struct EngineError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
