import XCTest
@testable import LofiBossa

/// The Swift clean-up (Engine/Cleanup) against golden output of training/tidy.py and
/// training/tracks.py, written by training/export_fixtures.py. Only the deterministic parts are
/// here; the random ones (chord share, dynamics jitter) are property-tested in TidyTests.
final class CleanupGoldenTests: XCTestCase {
    private static let fixture: [String: Any] = {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/cleanup_golden.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            fatalError("Missing \(url.path); run training/export_fixtures.py")
        }
        return json
    }()

    private func cases(_ name: String) -> [[String: Any]] {
        Self.fixture[name] as? [[String: Any]] ?? []
    }

    private func notes(_ value: Any?) -> [Note] {
        (value as? [[Double]] ?? []).map {
            Note(pitch: Int($0[2]), start: $0[0], duration: $0[1], velocity: Int($0[3]))
        }
    }

    private func track(_ value: Any?) -> TrackID { TrackID(rawValue: value as! String)! }

    private func assertNotes(_ got: [Note], _ expected: Any?, _ label: String,
                             file: StaticString = #filePath, line: UInt = #line) {
        let want = notes(expected)
        XCTAssertEqual(got.count, want.count, "\(label): note count", file: file, line: line)
        for (i, (g, w)) in zip(got, want).enumerated() {
            let same = g.pitch == w.pitch && g.velocity == w.velocity
                && abs(g.start - w.start) < 1e-9 && abs(g.duration - w.duration) < 1e-9
            if !same {
                XCTFail("\(label): note \(i) is \(g.start) \(g.duration) \(g.pitch) \(g.velocity), "
                        + "expected \(w.start) \(w.duration) \(w.pitch) \(w.velocity)", file: file, line: line)
                return
            }
        }
    }

    func testKnob() {
        for row in Self.fixture["knob"] as! [[Double]] {
            XCTAssertEqual(Tidy.knob(row[0], sparse: row[1], normal: row[2], busy: row[3]), row[4], accuracy: 1e-12)
        }
    }

    func testSettings() {
        for c in cases("settings") {
            let s = Tidy.settings(track(c["track"]), busyness: c["busyness"] as! Double)
            let label = "\(c["track"]!) at \(c["busyness"]!)"
            XCTAssertEqual(s.voices, c["voices"] as! Int, label)
            XCTAssertEqual(s.chordShare, c["chord_share"] as! Double, accuracy: 1e-9, label)
            XCTAssertEqual(s.minGap, c["min_gap"] as! Double, accuracy: 1e-9, label)
            XCTAssertEqual(s.perSec, c["per_sec"] as! Double, accuracy: 1e-9, label)
            XCTAssertEqual(s.repeats, c["repeats"] as! Double, accuracy: 1e-9, label)
            XCTAssertEqual(s.rest, c["rest"] as! Double, accuracy: 1e-9, label)
            if let phrase = c["phrase"] as? Double {
                XCTAssertEqual(s.phrase ?? -1, phrase, accuracy: 1e-6, label)
            } else {
                XCTAssertNil(s.phrase, label)
            }
        }
    }

    func testMinDuration() {
        for row in Self.fixture["min_duration"] as! [[Any]] {
            XCTAssertEqual(Tidy.minDuration(track(row[0]), noteLength: row[1] as! Double), row[2] as! Double,
                           accuracy: 1e-12, "\(row[0])")
        }
    }

    func testLegato() {
        for (i, c) in cases("legato").enumerated() {
            assertNotes(Tidy.legato(notes(c["notes"]), minLength: c["min_length"] as! Double), c["out"], "legato \(i)")
        }
    }

    func testClampDrums() {
        let c = Self.fixture["clamp_drums"] as! [String: Any]
        assertNotes(Tidy.clampDrums(notes(c["notes"])), c["out"], "clamp")
    }

    func testPitchCooldown() {
        for (i, c) in cases("pitch_cooldown").enumerated() {
            assertNotes(Tidy.pitchCooldown(track(c["track"]), notes(c["notes"])), c["out"], "cooldown \(i)")
        }
    }

    func testKeys() {
        let keys = Self.fixture["keys"] as! [String: [Int]]
        XCTAssertEqual(Set(keys.keys), Set(MusicKey.names))
        for (name, pcs) in keys { XCTAssertEqual(MusicKey.pitchClasses[name], Set(pcs), name) }
    }

    func testSnapToKey() {
        let everyPitch = (0..<128).map { Note(pitch: $0, start: Double($0) * 0.1, duration: 0.1, velocity: 80) }
        for c in cases("snap_to_key") {
            let name = c["key"] as! String
            let got = Tidy.snapToKey(everyPitch, key: MusicKey.pitchClasses[name]!).map(\.pitch)
            XCTAssertEqual(got, c["out"] as! [Int], name)
        }
    }

    func testQuantize() {
        for (i, c) in cases("quantize").enumerated() {
            let tempo = BeatGrid(bpm: c["bpm"] as! Double, offset: c["offset"] as! Double)
            assertNotes(Tidy.quantize(notes(c["notes"]), tempo: tempo, strength: c["strength"] as! Double),
                        c["out"], "quantize \(i)")
        }
    }

    func testDetectKey() {
        for (i, c) in cases("detect_key").enumerated() {
            XCTAssertEqual(MusicKey.detect(in: notes(c["notes"])), c["key"] as! String, "case \(i)")
        }
    }

    func testEstimateTempo() {
        for (i, c) in cases("estimate_tempo").enumerated() {
            let got = BeatGrid.estimate(onsets: c["onsets"] as! [Double])
            if let want = c["tempo"] as? [Double] {
                XCTAssertEqual(got?.bpm, want[0], "case \(i) bpm")
                XCTAssertEqual(got?.offset, want[1], "case \(i) offset")
            } else {
                XCTAssertNil(got, "case \(i)")
            }
        }
    }

    func testBeatPhase() {
        for (i, c) in cases("beat_phase").enumerated() {
            XCTAssertEqual(BeatGrid.phase(onsets: c["onsets"] as! [Double], bpm: c["bpm"] as! Double),
                           c["offset"] as! Double, "case \(i)")
        }
    }

    func testDrumCategory() {
        let want = Self.fixture["drum_category"] as! [String]
        XCTAssertEqual((0..<128).map { DrumCategory(pitch: $0).rawValue }, want)
    }

    func testFlatDynamics() {
        for c in cases("flat_dynamics") {
            var rng = Tidy.SeededRandom(seed: 0)
            let got = Tidy.applyDynamics(track(c["track"]), notes(c["notes"]), dynamics: 0, rng: &rng,
                                         tempo: BeatGrid(bpm: 100, offset: 0))
            assertNotes(got, c["out"], "flat \(c["track"]!)")
        }
    }

    func testTidyTrack() {
        for (i, c) in cases("tidy_track").enumerated() {
            var rng = Tidy.SeededRandom(seed: 0)
            let tempo = (c["tempo"] as? [Double]).map { BeatGrid(bpm: $0[0], offset: $0[1]) }
            let got = Tidy.tidyTrack(
                track(c["track"]), notes(c["notes"]), busyness: c["busyness"] as! Double, rng: &rng,
                noteLength: c["note_length"] as? Double,
                key: (c["key"] as? String).flatMap { MusicKey.pitchClasses[$0] },
                keyStrict: c["key_strict"] as! Bool, tempo: tempo, groove: c["groove"] as! Double)
            assertNotes(got, c["out"], "tidy_track \(i) (\(c["track"]!), busyness \(c["busyness"]!))")
        }
    }
}
