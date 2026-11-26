import Foundation
#if canImport(CoreAI)
import CoreAI

/// The music transformer running in the app through Core AI (macOS / iOS 27).
///
/// The asset comes from `training/export_coreai.py` and has two entrypoints that share a KV cache
/// held as model state: `prefill` writes exactly `prefillLength` tokens at once, `decode` writes
/// one. Both take the absolute positions of their tokens and attend only to cache positions at or
/// before each query (the mask is position based), so a prompt longer than `prefillLength` is
/// fed in chunks at increasing positions, and a shorter one is padded: the padding lands at later
/// positions that no real query sees, and decode overwrites them as it goes.
@available(macOS 27.0, iOS 27.0, *)
final class MusicModel: LogitsModel {
    static let prefillLength = 512
    static let maxLength = 1024
    static let vocabulary = 55028
    private static let layers = 12, heads = 12, headDim = 64

    private let prefillFunction: InferenceFunction
    private let decodeFunction: InferenceFunction
    private var keys: NDArray
    private var values: NDArray
    /// The token last written at each cache position, so a prefill that has to start earlier
    /// (near the end of the window) can rewrite those positions with exactly what's there.
    private var written = [Int32](repeating: 0, count: MusicModel.maxLength)

    struct LoadError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// `computeUnit` nil lets Core AI choose; otherwise it's the preferred unit.
    init(contentsOf url: URL, computeUnit: ComputeUnitKind? = nil) async throws {
        let options = computeUnit.map { SpecializationOptions(preferredComputeUnitKind: $0) } ?? .default
        let model = try await AIModel(contentsOf: url, options: options)
        guard let prefill = try model.loadFunction(named: "prefill"),
              let decode = try model.loadFunction(named: "decode") else {
            throw LoadError(message: "\(url.lastPathComponent) has no prefill/decode entrypoints")
        }
        prefillFunction = prefill
        decodeFunction = decode
        let shape = [Self.layers, 1, Self.heads, Self.maxLength, Self.headDim]
        keys = NDArray(shape: shape, scalarType: .float32)
        values = NDArray(shape: shape, scalarType: .float32)
    }

    /// Feeds `tokens` at positions `start...` and returns the logits after the last one.
    func feed(_ tokens: [Int32], at start: Int) async throws -> [Float] {
        precondition(!tokens.isEmpty && start + tokens.count <= Self.maxLength)
        // A few tokens (one event) are cheaper one by one through decode than as a padded
        // 512-token prefill.
        for (i, token) in tokens.enumerated() { written[start + i] = token }
        if tokens.count <= 4 {
            var logits: [Float] = []
            for (i, token) in tokens.enumerated() {
                logits = try await run(decodeFunction, tokens: [token], start: start + i, readRow: 0)
            }
            return logits
        }
        var logits: [Float] = []
        var offset = 0
        while offset < tokens.count {
            let chunk = Array(tokens[offset..<min(offset + Self.prefillLength, tokens.count)])
            let begin = start + offset
            // A prefill writes exactly `prefillLength` positions, and they must stay inside the
            // cache. Near the end of the window it starts earlier instead, rewriting the positions
            // before `begin` with the tokens already there (same tokens, same cache entries).
            if begin + Self.prefillLength > Self.maxLength {
                let first = Self.maxLength - Self.prefillLength
                let refill = Array(written[first..<begin]) + chunk
                let padded = refill + Array(repeating: Int32(0), count: Self.prefillLength - refill.count)
                logits = try await run(prefillFunction, tokens: padded, start: first, readRow: refill.count - 1)
            } else {
                let padded = chunk + Array(repeating: Int32(0), count: Self.prefillLength - chunk.count)
                logits = try await run(prefillFunction, tokens: padded, start: begin, readRow: chunk.count - 1)
            }
            offset += chunk.count
        }
        return logits
    }

    private func run(_ function: InferenceFunction, tokens: [Int32], start: Int, readRow: Int) async throws -> [Float] {
        let ids = NDArray(scalars: tokens, shape: [1, tokens.count])
        let positions = NDArray(scalars: (0..<tokens.count).map { Int32(start + $0) }, shape: [1, tokens.count])
        // The state views borrow the caches for the call, which a class property can't lend for
        // that long, so they move into locals and back. NDArray is copy-on-write, so the move is
        // free and the model writes into the same storage.
        var keys = self.keys, values = self.values
        defer { self.keys = keys; self.values = values }
        var states = InferenceFunction.MutableViews()
        states.insert(&keys, for: "k_cache")
        states.insert(&values, for: "v_cache")
        var outputs = try await function.run(inputs: ["input_ids": ids, "position_ids": positions], states: states)
        guard let logits = outputs.remove("logits")?.ndArray else {
            throw LoadError(message: "the model returned no logits")
        }
        let vocabulary = Self.vocabulary
        return logits.view(as: Float.self).withUnsafePointer { pointer, _, strides in
            let rowStride = strides.count >= 2 ? strides[strides.count - 2] : vocabulary
            let columnStride = strides.count >= 1 ? strides[strides.count - 1] : 1
            let base = pointer + readRow * rowStride
            return (0..<vocabulary).map { base[$0 * columnStride] }
        }
    }
}

/// `LofiBossa --engine-bench model.aimodel [fixture.json]`: loads the asset, checks its logits
/// against PyTorch's (from `training/engine_fixture.py`), and times prefill and decode on this
/// device's real Core AI runtime. Prints a report and exits.
@available(macOS 27.0, iOS 27.0, *)
enum EngineBench {
    struct Fixture: Decodable {
        struct Top: Decodable { let indices: [Int]; let values: [Float] }
        let prompt: [Int32]
        let next_token: Int32
        let after_prompt: Top
        let after_next: Top
    }

    static func run(model url: URL, fixture: URL?, computeUnit: ComputeUnitKind? = nil) async -> Int32 {
        do {
            let loadStart = Date()
            let model = try await MusicModel(contentsOf: url, computeUnit: computeUnit)
            print("compute unit: \(computeUnit.map { "\($0)" } ?? "default"), available: \(ComputeUnitKind.availableKinds)")
            print(String(format: "loaded %@ in %.1f s", url.lastPathComponent, Date().timeIntervalSince(loadStart)))

            if let fixture {
                let f = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: fixture))
                let afterPrompt = try await model.feed(f.prompt, at: 0)
                let afterNext = try await model.feed([f.next_token], at: f.prompt.count)
                for (name, got, want) in [("prefill", afterPrompt, f.after_prompt), ("decode", afterNext, f.after_next)] {
                    let argmax = got.indices.max { got[$0] < got[$1] } ?? -1
                    let top5 = Set(got.indices.sorted { got[$0] > got[$1] }.prefix(5))
                    let overlap = top5.intersection(want.indices.prefix(5)).count
                    let diff = zip(want.indices, want.values).map { abs(got[$0.0] - $0.1) }.max() ?? .nan
                    print("\(name): argmax \(argmax) (PyTorch \(want.indices[0])), top-5 overlap \(overlap)/5, "
                          + String(format: "max |Δlogit| over PyTorch's top %d: %.3f", want.indices.count, diff))
                }
            }

            // Near the end of the window a prefill starts earlier and rewrites positions already
            // written; the logits must equal feeding the same tokens the plain way.
            let sequence = (0..<610).map { _ in Int32.random(in: 0..<55000) }
            _ = try await model.feed(Array(sequence[0..<600]), at: 0)
            let shifted = try await model.feed(Array(sequence[600..<610]), at: 600)   // 600 + 512 > 1024
            let plain = try await model.feed(sequence, at: 0)                         // 512 + 98, no shift
            let nearEndDiff = zip(shifted, plain).map { abs($0 - $1) }.max() ?? .nan
            print(String(format: "near-end prefill: max |Δlogit| vs the plain path %.5f", nearEndDiff))

            // Timing on fresh positions: one full prefill, then decode token by token.
            let prefillTokens = (0..<MusicModel.prefillLength).map { _ in Int32.random(in: 0..<55000) }
            var prefillTimes: [Double] = []
            for _ in 0..<3 {
                let t = Date()
                _ = try await model.feed(prefillTokens, at: 0)
                prefillTimes.append(Date().timeIntervalSince(t))
            }
            var decodeTimes: [Double] = []
            for step in 0..<128 {
                let t = Date()
                _ = try await model.feed([Int32.random(in: 0..<55000)], at: MusicModel.prefillLength + step)
                decodeTimes.append(Date().timeIntervalSince(t))
            }
            let prefill = prefillTimes.dropFirst().reduce(0, +) / Double(max(prefillTimes.count - 1, 1))
            let warm = Array(decodeTimes.dropFirst(8))
            let decode = warm.reduce(0, +) / Double(warm.count)
            let p95 = warm.sorted()[Int(Double(warm.count) * 0.95)]
            print(String(format: "prefill %d tokens: %.1f ms (%.0f tok/s); first call %.1f ms",
                         MusicModel.prefillLength, prefill * 1000, Double(MusicModel.prefillLength) / prefill, prefillTimes[0] * 1000))
            print(String(format: "decode: %.2f ms/token mean, %.2f ms p95 (%.0f tok/s); first call %.1f ms",
                         decode * 1000, p95 * 1000, 1 / decode, decodeTimes[0] * 1000))
            print(String(format: "a 1,500-token song: about %.0f s", 1500 * decode))
            return 0
        } catch {
            print("engine bench failed: \(error)")
            return 1
        }
    }
}

/// `LofiBossa --engine-generate model.aimodel seconds out.json [seed]`: writes a four-track song
/// with the Swift sampler on Core AI (no clean-up yet) and saves it in the server's wire format,
/// so `--render out.json lofi out.wav` can play it. Prints timing and note counts.
@available(macOS 27.0, iOS 27.0, *)
enum EngineGenerate {
    static func run(model url: URL, seconds: Double, output: URL, seed: UInt64) async -> Int32 {
        do {
            let model = try await MusicModel(contentsOf: url)
            let tracks = TrackID.core
            let result = try await MusicEngine.generate(
                model: model, seconds: seconds, seed: seed, tracks: tracks, busyness: [:], noteLength: [:],
                music: MusicSettings(), log: { print($0) })
            let notes = result.tracks
            let wire = WireSong(seed: Int(seed), seconds: seconds,
                                tracks: Dictionary(uniqueKeysWithValues: tracks.map { ($0.rawValue, notes[$0] ?? []) }))
            try JSONEncoder().encode(wire).write(to: output)
            return 0
        } catch {
            print("engine generate failed: \(error)")
            return 1
        }
    }
}
#endif
