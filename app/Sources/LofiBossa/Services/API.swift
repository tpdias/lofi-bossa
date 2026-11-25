import Foundation

/// Wire format for the local Python inference server (training/server.py): the JSON body of
/// /generate's response and of /regenerate_track's request and response.
struct WireSong: Codable {
    var seed: Int
    var seconds: Double
    var tracks: [String: [Note]]
    /// The key the server used for this take, e.g. "A minor"; nil when none was asked for, or
    /// (for /regenerate_track) the song had no key constraint to report.
    var key: String? = nil
    var tempo: Double? = nil
    var beatOffset: Double? = nil

    enum CodingKeys: String, CodingKey {
        case seed, seconds, tracks, key, tempo
        case beatOffset = "beat_offset"
    }

    func notes(_ id: TrackID) -> [Note] { tracks[id.rawValue] ?? [] }

    /// Combine with a snapshot's non-musical state (instruments, volumes, effects) to get a
    /// full SongSnapshot after a whole-song generation.
    func snapshot(style: MusicStyle, instruments: [TrackID: String], tracks ids: [TrackID] = TrackID.core) -> SongSnapshot {
        SongSnapshot(
            tracks: ids.map {
                Track(id: $0, instrument: instruments[$0] ?? $0.defaultInstrument, notes: notes($0),
                      effects: style.defaultTrackEffects[$0] ?? TrackEffects())
            },
            effects: style.defaultEffects, style: style, lengthSeconds: seconds, seed: UInt32(truncatingIfNeeded: seed),
            detectedKey: key, tempo: tempo, beatOffset: beatOffset)
    }

    /// `song` with this answer's notes, length, seed and key; everything else (instruments,
    /// volumes, effects) as it was. For /extend.
    func extending(_ song: SongSnapshot) -> SongSnapshot {
        var result = song
        for i in result.tracks.indices { result.tracks[i].notes = notes(result.tracks[i].id) }
        result.lengthSeconds = seconds
        result.seed = UInt32(truncatingIfNeeded: seed)
        result.detectedKey = key
        result.tempo = tempo
        result.beatOffset = beatOffset
        return result
    }

    init(seed: Int, seconds: Double, tracks: [String: [Note]], key: String? = nil) {
        self.seed = seed; self.seconds = seconds; self.tracks = tracks; self.key = key
    }

    /// Everything the server needs to rewrite one track: the full current song, so the model
    /// can fit the new part to what is already there.
    init(from snapshot: SongSnapshot) {
        seed = Int(snapshot.seed)
        seconds = snapshot.lengthSeconds
        // Every track, present or not, so the server never sees a missing key; absent ones are empty.
        tracks = Dictionary(uniqueKeysWithValues: TrackID.allCases.map { ($0.rawValue, snapshot.track($0).notes) })
    }
}

/// Client for the local Python inference server. Talks over plain HTTP to 127.0.0.1:8765.
struct API {
    var base = URL(string: "http://127.0.0.1:8765")!

    struct ServerError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 600   // generation can take as long as the clip
        config.timeoutIntervalForResource = 600
        return URLSession(configuration: config)
    }()

    /// Styles that have a fine-tuned checkpoint, or nil when the generator can't be reached.
    func health() async -> Set<MusicStyle>? {
        var request = URLRequest(url: base.appending(path: "health"))
        request.timeoutInterval = 2
        guard let (data, response) = try? await Self.session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        let names = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["finetuned"] as? [String]
        return Set((names ?? []).compactMap(MusicStyle.init(rawValue:)))
    }

    func generate(style: MusicStyle, model: NoteModel, seconds: Double, seed: UInt32?,
                  tracks: [TrackID] = TrackID.core, busyness: [TrackID: Double] = [:],
                  noteLength: [TrackID: Double] = [:], music: MusicSettings = MusicSettings(),
                  keeping song: WireSong? = nil, locked: [TrackID] = []) async throws -> WireSong {
        var request = URLRequest(url: base.appending(path: "generate"))
        var body: [String: Any] = [
            "style": style.rawValue, "model": model.apiValue, "seconds": seconds, "format": "json",
            "tracks": tracks.map(\.rawValue),
            "busyness": Dictionary(uniqueKeysWithValues: busyness.map { ($0.key.rawValue, $0.value) }),
            "note_length": Dictionary(uniqueKeysWithValues: noteLength.map { ($0.key.rawValue, $0.value) }),
        ].merging(music.body) { $1 }
        if let seed { body["seed"] = Int(seed) }
        if let song, !locked.isEmpty {
            body["song"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(song))
            body["locked"] = locked.map(\.rawValue)
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await send(request)
    }

    /// Continues `song` for `seconds` more; the song's own notes come back exactly as sent.
    func extend(_ song: WireSong, by seconds: Double, style: MusicStyle, model: NoteModel, seed: UInt32?,
                tracks: [TrackID], busyness: [TrackID: Double] = [:], noteLength: [TrackID: Double] = [:],
                music: MusicSettings = MusicSettings()) async throws -> WireSong {
        var request = URLRequest(url: base.appending(path: "extend"))
        var body: [String: Any] = [
            "song": try JSONSerialization.jsonObject(with: JSONEncoder().encode(song)),
            "seconds": seconds, "style": style.rawValue, "model": model.apiValue,
            "tracks": tracks.map(\.rawValue),
            "busyness": Dictionary(uniqueKeysWithValues: busyness.map { ($0.key.rawValue, $0.value) }),
            "note_length": Dictionary(uniqueKeysWithValues: noteLength.map { ($0.key.rawValue, $0.value) }),
        ].merging(music.body) { $1 }
        if let seed { body["seed"] = Int(seed) }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await send(request)
    }

    func regenerate(_ track: TrackID, in song: WireSong, style: MusicStyle, model: NoteModel, seed: UInt32,
                    range: ClosedRange<Double>? = nil, busyness: Double = Project.defaultBusyness,
                    noteLength: Double = Project.defaultNoteLength,
                    music: MusicSettings = MusicSettings()) async throws -> WireSong {
        var items = [
            URLQueryItem(name: "track", value: track.rawValue),
            URLQueryItem(name: "style", value: style.rawValue),
            URLQueryItem(name: "model", value: model.apiValue),
            URLQueryItem(name: "seed", value: String(seed)),
            URLQueryItem(name: "busyness", value: String(min(max(busyness, 0), 1))),
            URLQueryItem(name: "note_length", value: String(min(max(noteLength, 0), 1))),
        ] + music.body.map { URLQueryItem(name: $0.key, value: "\($0.value)") }
        if let range {   // rewrite only this stretch; the server keeps everything outside it
            items.append(URLQueryItem(name: "start", value: String(range.lowerBound)))
            items.append(URLQueryItem(name: "end", value: String(range.upperBound)))
        }
        var request = URLRequest(url: base.appending(path: "regenerate_track").appending(queryItems: items))
        request.httpBody = try JSONEncoder().encode(song)
        return try await send(request)
    }

    private func send(_ request: URLRequest) async throws -> WireSong {
        var request = request
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let data: Data, response: URLResponse
        do {
            (data, response) = try await Self.session.data(for: request)
        } catch let error as URLError where error.code == .cannotConnectToHost || error.code == .networkConnectionLost {
            throw ServerError(message: L("The generator isn't running."))
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["detail"]
            throw ServerError(message: (detail as? String) ?? L("The generator returned an error."))
        }
        return try JSONDecoder().decode(WireSong.self, from: data)
    }
}

/// Derives a track's rewrite seed from the song seed, so repeated rewrites of the same track
/// on the same song are at least distinct from each other while staying deterministic-ish.
/// (The design note: "A rewrite seed is derived from the song seed plus the track.")
func rewriteSeed(songSeed: UInt32, track: TrackID, attempt: Int) -> UInt32 {
    var hasher = Hasher()
    hasher.combine(songSeed)
    hasher.combine(track)
    hasher.combine(attempt)
    return UInt32(truncatingIfNeeded: hasher.finalize())
}

extension MusicSettings {
    /// The server's names for these settings (training/server.py), for a JSON body or a query.
    var body: [String: Any] {
        [
            "key": key ?? "auto", "strict_key": strictKey,
            "tempo": tempo.map { String(Int($0.rounded())) } ?? "auto",
            "groove": min(max(groove, 0), 1), "dynamics": min(max(dynamics, 0), 1),
        ]
    }
}
