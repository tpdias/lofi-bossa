import Foundation
import Observation
#if canImport(CoreAI)
import CoreAI
#endif

/// Where the on-device models are: `<style>.aimodel` (a style's own, fine-tuned) or
/// `base.aimodel` (the pretrained model, for any style), in the app bundle, or in the folder
/// given with `--model-dir PATH` (development: `exports/` from training/export_coreai.py).
enum ModelFiles {
    static var directory: URL? {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--model-dir"), args.count > i + 1 {
            return URL(fileURLWithPath: args[i + 1], isDirectory: true)
        }
        return Bundle.main.resourceURL
    }

    private static func existing(_ name: String) -> URL? {
        guard let dir = directory else { return nil }
        let url = dir.appendingPathComponent("\(name).aimodel")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// The style's own model, else the base one.
    static func url(for style: MusicStyle) -> URL? {
        existing(style.rawValue) ?? existing("base") ?? existing("base-int8")
    }

    static func hasOwnModel(_ style: MusicStyle) -> Bool { existing(style.rawValue) != nil }

    static var isAvailable: Bool { MusicStyle.allCases.contains { url(for: $0) != nil } }
}

/// The generator inside the app: the music model on Core AI (macOS / iOS 27), the Swift sampler
/// and clean-up (`Engine/`), doing what `training/server.py` does, with no Python and no network.
///
/// Models load in the background at launch (status `.starting`; the first load of a model takes
/// ~20 s while the system specializes it for this device, later loads a second or two). Each
/// job runs off the main thread, one at a time.
@MainActor @Observable
final class OnDeviceGeneratorClient: GeneratorClient {
    nonisolated static let notReadyReason = "The on-device music model isn't in this build."
    /// `--engine-log` also prints the engine's log (loading, each stage with its time) to stdout.
    private static let printsLog = CommandLine.arguments.contains("--engine-log")

    private(set) var currentStatus: GeneratorStatus = .starting
    private(set) var finetunedStyles: Set<MusicStyle> = []
    private(set) var lastLogLine: String?
    private var log: [String] = []
    var fullLog: String { log.joined(separator: "\n") }

    /// Loaded models by file, so styles sharing the base model load it once.
    private var loaded: [URL: AnyObject] = [:]
    private var loading: Task<Void, Never>?

    struct NotReady: LocalizedError {
        var errorDescription: String? { OnDeviceGeneratorClient.notReadyReason }
    }

    init() {
        loading = Task { await loadModels() }
    }

    private func note(_ line: String) {
        if Self.printsLog { print("engine: \(line)"); fflush(stdout) }
        lastLogLine = line
        log.append(line)
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }

    private func loadModels() async {
        currentStatus = .starting
        guard ModelFiles.isAvailable else {
            note(Self.notReadyReason)
            currentStatus = .offline(reason: Self.notReadyReason)
            return
        }
        #if canImport(CoreAI)
        guard #available(macOS 27.0, iOS 27.0, *) else {
            currentStatus = .offline(reason: "On-device generation needs macOS or iOS 27.")
            return
        }
        finetunedStyles = Set(MusicStyle.allCases.filter(ModelFiles.hasOwnModel))
        for style in MusicStyle.allCases {
            guard let url = ModelFiles.url(for: style), loaded[url] == nil else { continue }
            let start = Date()
            do {
                loaded[url] = try await MusicModel(contentsOf: url)
                note(String(format: "Loaded %@ in %.1f s", url.lastPathComponent, Date().timeIntervalSince(start)))
            } catch {
                note("Couldn't load \(url.lastPathComponent): \(error.localizedDescription)")
                currentStatus = .offline(reason: "The music model couldn't be loaded.")
                return
            }
        }
        currentStatus = .ready
        #else
        currentStatus = .offline(reason: Self.notReadyReason)
        #endif
    }

    func restart() async throws {
        loading?.cancel()
        loaded = [:]
        loading = Task { await loadModels() }
        await loading?.value
    }

    #if canImport(CoreAI)
    @available(macOS 27.0, iOS 27.0, *)
    private func model(for style: MusicStyle) async throws -> MusicModel {
        await loading?.value
        guard let url = ModelFiles.url(for: style), let model = loaded[url] as? MusicModel else { throw NotReady() }
        return model
    }
    #endif

    /// The model's notes as a snapshot (same shape a server answer becomes).
    private static func snapshot(_ result: MusicEngine.Result, style: MusicStyle, tracks: [TrackID], seed: UInt32) -> SongSnapshot {
        var wire = WireSong(seed: Int(seed), seconds: result.seconds,
                            tracks: Dictionary(uniqueKeysWithValues: tracks.map { ($0.rawValue, result.tracks[$0] ?? []) }),
                            key: result.key)
        wire.tempo = result.tempo?.bpm
        wire.beatOffset = result.tempo?.offset
        return wire.snapshot(style: style, instruments: style.defaultInstruments, tracks: tracks)
    }

    func generate(style: MusicStyle, model: NoteModel, length: Double, seed: UInt32?,
                  tracks: [TrackID], busyness: [TrackID: Double], noteLength: [TrackID: Double],
                  music: MusicSettings, keeping song: SongSnapshot?,
                  locked: Set<TrackID>) -> AsyncThrowingStream<GenerationEvent, Error> {
        let seed = seed ?? UInt32.random(in: 0...UInt32.max)
        let kept = song.map { s in Dictionary(uniqueKeysWithValues: s.tracks.map { ($0.id, $0.notes) }) }
        return AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                do {
                    #if canImport(CoreAI)
                    guard #available(macOS 27.0, iOS 27.0, *) else { throw NotReady() }
                    let engineModel = try await self.model(for: style)
                    let log: @Sendable (String) -> Void = { line in Task { @MainActor in self.note(line) } }
                    let result = try await Task.detached(priority: .userInitiated) {
                        try await MusicEngine.generate(model: engineModel, seconds: length, seed: UInt64(seed), tracks: tracks,
                                                       busyness: busyness, noteLength: noteLength, music: music,
                                                       keeping: kept, locked: locked, log: log)
                    }.value
                    continuation.yield(.finished(Self.snapshot(result, style: style, tracks: tracks, seed: seed)))
                    continuation.finish()
                    #else
                    throw NotReady()
                    #endif
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
        #if canImport(CoreAI)
        guard #available(macOS 27.0, iOS 27.0, *) else { throw NotReady() }
        let engineModel = try await self.model(for: song.style)
        let seed = seed ?? UInt32.random(in: 0...UInt32.max)
        let notes = Dictionary(uniqueKeysWithValues: song.tracks.map { ($0.id, $0.notes) })
        let ids = song.trackIDs, length = song.lengthSeconds
        let result = try await Task.detached(priority: .userInitiated) {
            try await MusicEngine.extend(model: engineModel, song: notes, seconds: length, by: seconds, seed: UInt64(seed),
                                         tracks: ids, busyness: busyness, noteLength: noteLength, music: music)
        }.value
        var longer = song
        for i in longer.tracks.indices { longer.tracks[i].notes = result.tracks[longer.tracks[i].id] ?? [] }
        longer.lengthSeconds = result.seconds
        longer.seed = seed
        longer.detectedKey = result.key
        longer.tempo = result.tempo?.bpm
        longer.beatOffset = result.tempo?.offset
        return longer
        #else
        throw NotReady()
        #endif
    }

    func rewrite(track: TrackID, model: NoteModel, in song: SongSnapshot, seed: UInt32,
                 range: ClosedRange<Double>?, busyness: Double, noteLength: Double,
                 music: MusicSettings) async throws -> (notes: [Note], detectedKey: String?) {
        #if canImport(CoreAI)
        guard #available(macOS 27.0, iOS 27.0, *) else { throw NotReady() }
        let engineModel = try await self.model(for: song.style)
        let notes = Dictionary(uniqueKeysWithValues: song.tracks.map { ($0.id, $0.notes) })
        let length = song.lengthSeconds
        let result = try await Task.detached(priority: .userInitiated) {
            try await MusicEngine.rewrite(model: engineModel, track: track, song: notes, seconds: length, seed: UInt64(seed),
                                          range: range, busyness: busyness, noteLength: noteLength, music: music)
        }.value
        return (result.notes, result.key)
        #else
        throw NotReady()
        #endif
    }
}

#if canImport(CoreAI)
/// The client runs one job at a time (the view model won't start another while busy), so the
/// model is never used from two places at once.
@available(macOS 27.0, iOS 27.0, *)
extension MusicModel: @unchecked Sendable {}
#endif
