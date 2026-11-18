import Foundation

/// Wire format for the local Python inference server (training/server.py): the JSON body of
/// /generate's response and of /regenerate_track's request and response.
struct WireSong: Codable {
    var seed: Int
    var seconds: Double
    var tracks: [String: [Note]]

    func notes(_ id: TrackID) -> [Note] { tracks[id.rawValue] ?? [] }

    /// Combine with a snapshot's non-musical state (instruments, volumes, effects) to get a
    /// full SongSnapshot after a whole-song generation.
    func snapshot(style: MusicStyle, instruments: [TrackID: String]) -> SongSnapshot {
        SongSnapshot(
            tracks: TrackID.allCases.map {
                Track(id: $0, instrument: instruments[$0] ?? $0.defaultInstrument, notes: notes($0),
                      effects: style.defaultTrackEffects[$0] ?? TrackEffects())
            },
            effects: style.defaultEffects, style: style, lengthSeconds: seconds, seed: UInt32(truncatingIfNeeded: seed))
    }

    init(seed: Int, seconds: Double, tracks: [String: [Note]]) {
        self.seed = seed; self.seconds = seconds; self.tracks = tracks
    }

    /// Everything the server needs to rewrite one track: the full current song, so the model
    /// can fit the new part to what is already there.
    init(from snapshot: SongSnapshot) {
        seed = Int(snapshot.seed)
        seconds = snapshot.lengthSeconds
        tracks = Dictionary(uniqueKeysWithValues: snapshot.tracks.map { ($0.id.rawValue, $0.notes) })
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

    func generate(style: MusicStyle, model: NoteModel, seconds: Double, seed: UInt32?) async throws -> WireSong {
        var request = URLRequest(url: base.appending(path: "generate"))
        var body: [String: Any] = [
            "style": style.rawValue, "model": model.apiValue, "seconds": seconds, "format": "json",
        ]
        if let seed { body["seed"] = Int(seed) }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await send(request)
    }

    func regenerate(_ track: TrackID, in song: WireSong, style: MusicStyle, model: NoteModel, seed: UInt32) async throws -> WireSong {
        let url = base.appending(path: "regenerate_track").appending(queryItems: [
            URLQueryItem(name: "track", value: track.rawValue),
            URLQueryItem(name: "style", value: style.rawValue),
            URLQueryItem(name: "model", value: model.apiValue),
            URLQueryItem(name: "seed", value: String(seed)),
        ])
        var request = URLRequest(url: url)
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
