import Foundation

/// Client for the local Python inference server (training/server.py).
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
    func health() async -> Set<Style>? {
        var request = URLRequest(url: base.appending(path: "health"))
        request.timeoutInterval = 2
        guard let (data, response) = try? await Self.session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        let names = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["finetuned"] as? [String]
        return Set((names ?? []).compactMap(Style.init(rawValue:)))
    }

    func generate(style: Style, model: ModelChoice, seconds: Double) async throws -> Song {
        var request = URLRequest(url: base.appending(path: "generate"))
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "style": style.rawValue, "model": model.rawValue, "seconds": seconds, "format": "json",
        ])
        return try await send(request)
    }

    func regenerate(_ track: TrackKind, in song: Song, style: Style, model: ModelChoice) async throws -> Song {
        let url = base.appending(path: "regenerate_track").appending(queryItems: [
            URLQueryItem(name: "track", value: track.rawValue),
            URLQueryItem(name: "style", value: style.rawValue),
            URLQueryItem(name: "model", value: model.rawValue),
        ])
        var request = URLRequest(url: url)
        request.httpBody = try JSONEncoder().encode(song)
        return try await send(request)
    }

    private func send(_ request: URLRequest) async throws -> Song {
        var request = request
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let data: Data, response: URLResponse
        do {
            (data, response) = try await Self.session.data(for: request)
        } catch let error as URLError where error.code == .cannotConnectToHost {
            throw ServerError(message: "The generator isn't running. Start it with: .venv/bin/python training/server.py")
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["detail"]
            throw ServerError(message: "Generator error: \(detail ?? "unknown")")
        }
        return try JSONDecoder().decode(Song.self, from: data)
    }
}
