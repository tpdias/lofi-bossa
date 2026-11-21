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
            detectedKey: key)
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
                  noteLength: [TrackID: Double] = [:], key: String? = nil, strictKey: Bool = false) async throws -> WireSong {
        var request = URLRequest(url: base.appending(path: "generate"))
        var body: [String: Any] = [
            "style": style.rawValue, "model": model.apiValue, "seconds": seconds, "format": "json",
            "tracks": tracks.map(\.rawValue),
            "busyness": Dictionary(uniqueKeysWithValues: busyness.map { ($0.key.rawValue, $0.value) }),
            "note_length": Dictionary(uniqueKeysWithValues: noteLength.map { ($0.key.rawValue, $0.value) }),
            "key": key ?? "auto", "strict_key": strictKey,
        ]
        if let seed { body["seed"] = Int(seed) }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await send(request)
    }

    func regenerate(_ track: TrackID, in song: WireSong, style: MusicStyle, model: NoteModel, seed: UInt32,
                    range: ClosedRange<Double>? = nil, busyness: Double = Project.defaultBusyness,
                    noteLength: Double = Project.defaultNoteLength, key: String? = nil,
                    strictKey: Bool = false) async throws -> WireSong {
        var items = [
            URLQueryItem(name: "track", value: track.rawValue),
            URLQueryItem(name: "style", value: style.rawValue),
            URLQueryItem(name: "model", value: model.apiValue),
            URLQueryItem(name: "seed", value: String(seed)),
            URLQueryItem(name: "busyness", value: String(min(max(busyness, 0), 1))),
            URLQueryItem(name: "note_length", value: String(min(max(noteLength, 0), 1))),
            URLQueryItem(name: "key", value: key ?? "auto"),
            URLQueryItem(name: "strict_key", value: String(strictKey)),
        ]
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
            throw ServerError(message: "The generator isn't running.")
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["detail"]
            throw ServerError(message: "\(detail ?? "The generator returned an error.")")
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
