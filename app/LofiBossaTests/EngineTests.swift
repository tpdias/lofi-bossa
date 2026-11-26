import XCTest
@testable import LofiBossa

/// The engine's event helpers against the `anticipation` library itself (golden fixtures from
/// training/export_engine_fixtures.py), and the sampler's constraints against a fake model.
final class EngineEventsTests: XCTestCase {
    private struct Fixture: Decodable {
        let events: [Int], controls: [Int], pad: [Int], pad_to_2000: [Int]
        let clip_0_400: [Int], clip_0_400_keep: [Int], anticipate: [Int], anticipate_pending: [Int]
        let min_time: Int, max_time: Int, unpad: [Int]
        let out_program: [String: Int], family: [String: [Int]], velocity: [String: Int]
    }

    private lazy var fixture: Fixture = {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/engine_ops.json")
        return try! JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }()

    private func events(_ tokens: [Int]) -> [Event] {
        stride(from: 0, to: tokens.count, by: 3).map { Event(time: tokens[$0], dur: tokens[$0 + 1], note: tokens[$0 + 2]) }
    }

    func testOpsMatchTheLibrary() {
        let e = events(fixture.events), c = events(fixture.controls)
        XCTAssertEqual(EventOps.flatten(EventOps.pad(e)), fixture.pad)
        XCTAssertEqual(EventOps.flatten(EventOps.pad(e, endTime: 2000)), fixture.pad_to_2000)
        XCTAssertEqual(EventOps.flatten(EventOps.clip(e, start: 0, end: 400)), fixture.clip_0_400)
        XCTAssertEqual(EventOps.flatten(EventOps.clip(e, start: 0, end: 400, clipDuration: false)), fixture.clip_0_400_keep)
        XCTAssertEqual(EventOps.flatten(EventOps.anticipate(EventOps.pad(e, endTime: 2000), controls: c).tokens), fixture.anticipate)
        XCTAssertEqual(EventOps.flatten(EventOps.anticipate(EventOps.pad(e), controls: c).pending), fixture.anticipate_pending)
        XCTAssertEqual(EventOps.minTime(e + c), fixture.min_time)
        XCTAssertEqual(EventOps.maxTime(e + c), fixture.max_time)
        XCTAssertEqual(EventOps.flatten(EventOps.unpad(EventOps.pad(e, endTime: 2000))), fixture.unpad)
    }

    func testTrackTablesMatchTracksPy() {
        for id in TrackID.allCases {
            XCTAssertEqual(id.outProgram, fixture.out_program[id.rawValue], id.rawValue)
            XCTAssertEqual(id.modelInstruments, fixture.family[id.rawValue], id.rawValue)
            XCTAssertEqual(id.defaultVelocity, fixture.velocity[id.rawValue], id.rawValue)
        }
    }

    func testNotesRoundTripThroughEvents() {
        let notes: [TrackID: [Note]] = [
            .piano: [Note(pitch: 60, start: 0.5, duration: 0.25, velocity: 90)],
            .drums: [Note(pitch: 36, start: 1.0, duration: 0.1, velocity: 100)],
            .keys: [Note(pitch: 55, start: 2.25, duration: 1.5, velocity: 80)],
        ]
        let back = NoteEvents.notes(from: NoteEvents.events(for: notes))
        for (id, list) in notes {
            XCTAssertEqual(back[id]?.map(\.pitch), list.map(\.pitch), id.rawValue)
            XCTAssertEqual(back[id]?.first?.start ?? -1, list[0].start, accuracy: 0.005)
            XCTAssertEqual(back[id]?.first?.duration ?? -1, list[0].duration, accuracy: 0.005)
        }
    }
}

/// A stand-in for the model: deterministic pseudo-random logits per position and token, so the
/// sampler runs its real loop without Core AI.
private final class FakeModel: LogitsModel {
    private(set) var fed = 0
    func feed(_ tokens: [Int32], at start: Int) async throws -> [Float] {
        fed += tokens.count
        var rng = SeededGenerator(seed: UInt64(start + tokens.count) &* 31 &+ UInt64(tokens.last.map { Int($0) } ?? 0))
        return (0..<55028).map { _ in Float.random(in: -2...2, using: &rng) }
    }
}

final class SamplerTests: XCTestCase {
    private let piano = TrackID.piano.modelInstruments

    private func run(_ options: SamplerOptions = SamplerOptions(), instruments: [Int]? = nil, seconds: Double = 6, seed: UInt64 = 1) async throws -> [Event] {
        try await Sampler.generate(model: FakeModel(), start: 0, end: seconds, instruments: instruments ?? piano, options: options, seed: seed)
    }

    func testNotesStayInsideTheRangeAndTheWhitelist() async throws {
        let events = try await run()
        XCTAssertFalse(events.isEmpty)
        XCTAssertTrue(events.allSatisfy { $0.tick >= 0 && $0.tick < 600 })
        XCTAssertTrue(events.allSatisfy { piano.contains($0.instrument) }, "only piano instruments")
        XCTAssertFalse(events.contains(where: \.isRest), "rests are removed from the result")
    }

    func testASeedReproduces() async throws {
        let a = try await run(seed: 7), b = try await run(seed: 7), c = try await run(seed: 8)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    func testStrictKeyKeepsEveryNoteInKey() async throws {
        var o = SamplerOptions()
        o.key = [0, 2, 4, 5, 7, 9, 11]
        o.keyStrict = true
        let events = try await run(o)
        XCTAssertTrue(events.allSatisfy { o.key!.contains($0.pitch % 12) })
    }

    func testMinimumDuration() async throws {
        var o = SamplerOptions()
        o.minDurationTicks = 40
        o.restPenalty = .infinity
        let events = try await run(o)
        XCTAssertTrue(events.allSatisfy { $0.durationTicks >= 40 })
    }

    func testDrumGapsAreKept() async throws {
        var o = SamplerOptions()
        o.drumMinGapTicks = Dictionary(uniqueKeysWithValues: (27...87).map { ($0, 25) })
        let hits = try await run(o, instruments: [Vocab.drums], seconds: 8)
        var last: [Int: Int] = [:]
        for e in hits {
            if let t = last[e.pitch] { XCTAssertGreaterThanOrEqual(e.tick - t, 25, "pitch \(e.pitch)") }
            last[e.pitch] = e.tick
        }
    }

    func testNotesPerSecondCap() async throws {
        var o = SamplerOptions()
        o.maxNotesPerSecond = 4
        let events = try await run(o, seconds: 8)
        for e in events {
            XCTAssertLessThanOrEqual(events.filter { $0.tick >= e.tick && $0.tick < e.tick + 100 }.count, 4)
        }
    }

    func testControlsAreNotReturnedAndInputsAreKept() async throws {
        let fixed = [Event.note(tick: 100, durationTicks: 50, instrument: 32, pitch: 40)]
        let out = try await Sampler.generate(model: FakeModel(), start: 0, end: 5, controls: fixed.map(\.asControl),
                                             instruments: piano, seed: 3)
        XCTAssertFalse(out.contains { $0.instrument == 32 }, "fixed notes are context, not output")
        let inputs = [Event.note(tick: 450, durationTicks: 30, instrument: 32, pitch: 43)]
        let merged = try await Sampler.generate(model: FakeModel(), start: 0, end: 4, inputs: inputs, instruments: piano, seed: 3)
        XCTAssertTrue(merged.contains(inputs[0]), "inputs after the range come back unchanged")
    }

    func testRewriteRangeOnlyWritesInsideTheRange() async throws {
        let song = (0..<20).map { Event.note(tick: $0 * 50, durationTicks: 40, instrument: 0, pitch: 60 + $0 % 5) }
        let new = try await Sampler.rewriteRange(model: FakeModel(), events: song, instruments: piano, start: 3, end: 6, seed: 2)
        XCTAssertTrue(new.allSatisfy { $0.tick >= 300 && $0.tick < 600 && $0.tick + $0.durationTicks <= 600 })
    }

    func testTopPKeepsTheMostLikely() {
        var rng = SeededGenerator(seed: 1)
        let logits: [Float] = [10, 0, 0, -.infinity]
        for _ in 0..<50 { XCTAssertEqual(Sampler.sample(logits, topP: 0.5, using: &rng), 0) }
        for _ in 0..<50 { XCTAssertNotEqual(Sampler.sample(logits, topP: 1, using: &rng), 3) }
    }
}
