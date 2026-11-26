import XCTest
@testable import LofiBossa

/// Key detection, tempo estimation and drum categories (Engine/Cleanup), mirroring
/// training/tests/test_tracks.py.
final class TrackFactsTests: XCTestCase {
    private func notes(_ pitches: [Int]) -> [Note] {
        pitches.enumerated().map { Note(pitch: $1, start: Double($0) * 0.5, duration: 0.5, velocity: 80) }
    }

    func testCMajorScaleIsDetectedAsCMajor() {
        XCTAssertEqual(MusicKey.detect(in: notes([60, 62, 64, 65, 67, 69, 71, 72])), "C major")
    }

    func testAMinorScaleIsDetectedAsAMinor() {
        XCTAssertEqual(MusicKey.detect(in: notes([57, 59, 60, 62, 64, 65, 67, 69])), "A minor")
    }

    func testNoNotesDefaultsToCMajor() {
        XCTAssertEqual(MusicKey.detect(in: []), "C major")
    }

    func testEveryKeyHasSevenPitchClasses() {
        XCTAssertEqual(MusicKey.pitchClasses.count, 24)
        XCTAssertTrue(MusicKey.pitchClasses.values.allSatisfy { $0.count == 7 })
        XCTAssertEqual(Set(MusicKey.pitchClasses.keys), Set(MusicKey.names))
    }

    func testRelativeMajorAndMinorShareThePitchClasses() {
        XCTAssertEqual(MusicKey.pitchClasses["C major"], MusicKey.pitchClasses["A minor"])
    }

    /// Eighth-note clicks with a little jitter and ~15% dropped.
    private func clicks(_ bpm: Double, _ offset: Double, n: Int = 64, jitter: Double = 0.008, seed: UInt64 = 0) -> [Double] {
        var r = Tidy.SeededRandom(seed: seed)
        let beat = 60 / bpm
        return (0..<n).compactMap { i in
            let t = offset + Double(i) * beat / 2 + (r.unit() * 2 - 1) * jitter
            return r.unit() > 0.15 ? t : nil
        }
    }

    func testEstimatesTheTempoOfEighthNoteClicks() {
        for bpm in [72.0, 90, 110, 130] {
            let got = BeatGrid.estimate(onsets: clicks(bpm, 0.2, seed: UInt64(bpm)))
            XCTAssertNotNil(got)
            XCTAssertEqual(got?.bpm ?? 0, bpm, accuracy: 1.5, "\(bpm) BPM")
        }
    }

    func testPhaseLinesUpWithTheClicks() {
        let bpm = 96.0, offset = 0.3
        let got = BeatGrid.estimate(onsets: clicks(bpm, offset, jitter: 0.002))!
        let halfBeat = 60 / bpm / 2
        let miss = PythonMath.mod((got.offset - offset) / halfBeat, 1)
        XCTAssertLessThan(min(miss, 1 - miss), 0.1)
    }

    func testTooFewNotesGivesNil() {
        XCTAssertNil(BeatGrid.estimate(onsets: [0, 1]))
    }

    func testBeatPhaseAtAGivenTempo() {
        let onsets = (0..<16).map { 0.25 + Double($0) * 0.5 }     // 120 BPM, on 0.25
        XCTAssertEqual(BeatGrid.phase(onsets: onsets, bpm: 120), 0.25, accuracy: 0.02)
    }

    func testKnownGMPitchesMapToTheirCategory() {
        XCTAssertEqual(DrumCategory(pitch: 36), .kick)
        XCTAssertEqual(DrumCategory(pitch: 38), .snare)
        XCTAssertEqual(DrumCategory(pitch: 42), .hihat)
    }

    func testUnknownPitchFallsBackToPerc() {
        XCTAssertEqual(DrumCategory(pitch: 70), .perc)
    }

    func testPythonRoundingMatches() {
        XCTAssertEqual(PythonMath.round(2.5), 2)          // ties to even
        XCTAssertEqual(PythonMath.round(0.125, 2), 0.12)
        XCTAssertEqual(PythonMath.round(2.675, 2), 2.67)  // the binary value is just below .675
        XCTAssertEqual(PythonMath.mod(-1.0, 12), 11)
        XCTAssertEqual(PythonMath.mod(-13, 12), 11)
        XCTAssertEqual(PythonMath.arange(41, 43.01, 0.1).count, 21)
    }
}
