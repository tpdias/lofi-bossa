import XCTest
@testable import LofiBossa

/// The clean-up port (Engine/Cleanup/Tidy.swift): the cases of training/tests/test_tidy.py, plus
/// property tests for the random parts, which use a Swift generator and so can't be golden.
final class TidyTests: XCTestCase {
    private func note(_ start: Double, _ pitch: Int = 60, _ duration: Double = 0.2, _ velocity: Int = 80) -> Note {
        Note(pitch: pitch, start: start, duration: duration, velocity: velocity)
    }

    private func chord(_ start: Double, _ pitches: [Int], duration: Double = 0.4) -> [Note] {
        pitches.map { note(start, $0, duration) }
    }

    private func run(_ track: TrackID, _ notes: [Note], busyness: Double = 0.5, seed: UInt64 = 0) -> [Note] {
        var rng = Tidy.SeededRandom(seed: seed)
        return Tidy.tidyTrack(track, notes, busyness: busyness, rng: &rng)
    }

    private func tidy(_ track: TrackID, _ notes: [Note], busyness: Double = 1, noteLength: Double? = nil,
                      key: Set<Int>? = nil, keyStrict: Bool = false, tempo: BeatGrid? = nil,
                      groove: Double = 0) -> [Note] {
        var rng = Tidy.SeededRandom(seed: 0)
        return Tidy.tidyTrack(track, notes, busyness: busyness, rng: &rng, noteLength: noteLength,
                              key: key, keyStrict: keyStrict, tempo: tempo, groove: groove)
    }

    private func end(_ n: Note) -> Double { n.start + n.duration }

    // MARK: - test_tidy.py

    func testBusynessOneLeavesNotesUntouched() {
        let notes = (0..<40).flatMap { chord(Double($0) * 0.1, [60, 64, 67, 71, 74]) }
        XCTAssertEqual(run(.piano, notes, busyness: 1), notes)
    }

    func testChordsAreCappedPerTrack() {
        let notes = chord(0, [48, 55, 60, 64, 67, 72])
        let out = run(.piano, notes)
        XCTAssertEqual(out.count, 4)
        XCTAssertTrue(Set(out.map(\.pitch)).isSuperset(of: [48, 72]), "keeps lowest and highest")
        XCTAssertEqual(run(.vibes, notes).count, 3)
    }

    func testBassAndLeadPlayOneNoteAtATime() {
        let notes = chord(0, [36, 43], duration: 2) + chord(1, [38], duration: 2)
        let bass = run(.bass, notes)
        XCTAssertEqual(bass.map(\.pitch), [36, 38], "bass keeps the lowest note")
        XCTAssertLessThanOrEqual(end(bass[0]), 1.0 + 1e-9, "no overlap")
        XCTAssertEqual(run(.lead, notes)[0].pitch, 43, "lead keeps the top note")
    }

    func testFullChordsAreAtMostSixtyPercentOfOnsets() {
        let notes = (0..<20).flatMap { chord(Double($0) * 0.5, [60, 64, 67, 70], duration: 0.3) }
        for seed in 0..<20 as Range<UInt64> {
            let groups = Tidy.groupsOf(run(.guitar, notes, seed: seed))
            let share = Double(groups.filter { $0.count >= 3 }.count) / Double(groups.count)
            XCTAssertLessThanOrEqual(share, 0.6, "seed \(seed)")
            XCTAssertGreaterThanOrEqual(share, 0.5, "only the excess is thinned (seed \(seed))")
            XCTAssertTrue(groups.allSatisfy { $0.count == 2 || $0.count == 4 }, "thinned chords keep top and bottom")
        }
    }

    func testFastRepeatsAreThinned() {
        let notes = (0..<30).map { note(Double($0) * 0.15, 60, 0.1) }
        XCTAssertLessThan(run(.guitar, notes).count, 20)
    }

    func testLongUnbrokenPartsGetARest() {
        let notes = (0..<80).map { note(Double($0) * 0.25, 60 + $0 % 7, 0.24) }   // 20 s, never stops
        let stats = Tidy.stats(run(.piano, notes), seconds: 20)
        XCTAssertLessThanOrEqual(stats.longestPhrase, Tidy.settings(.piano, busyness: 0.5).phrase! + 0.5)
    }

    func testDrumsKeepTheirGroove() {
        let hats = (0..<64).map { note(Double($0) * 0.125, 42, 0.05) }   // straight eighths at 240 per minute
        XCTAssertEqual(run(.drums, hats).count, hats.count, "repeats and phrases don't apply to drums")
    }

    func testSparseRemovesMoreThanBusy() {
        let notes = (0..<100).map { note(Double($0) * 0.12, 60 + $0 % 5, 0.1) }
        let sparse = run(.piano, notes, busyness: 0.1).count
        let normal = run(.piano, notes, busyness: 0.5).count
        let busy = run(.piano, notes, busyness: 0.9).count
        XCTAssertLessThan(sparse, normal)
        XCTAssertLessThanOrEqual(normal, busy)
    }

    func testDeterministicForASeed() {
        let notes = (0..<30).flatMap { chord(Double($0) * 0.5, [60, 64, 67]) }
        XCTAssertEqual(run(.piano, notes, seed: 3), run(.piano, notes, seed: 3))
    }

    func testTidySongOnlyTouchesTheGivenTracks() {
        let crowded = (0..<10).flatMap { chord(Double($0) * 0.5, [48, 55, 60, 64, 67, 72]) }
        let out = Tidy.tidySong([.piano: crowded, .guitar: crowded], busyness: 0.5, seed: 1, only: [.guitar])
        XCTAssertEqual(out[.piano], crowded, "the user's own notes are never limited")
        XCTAssertLessThan(out[.guitar]!.count, crowded.count)
    }

    func testPerTrackBusyness() {
        let crowded = (0..<10).flatMap { chord(Double($0) * 0.5, [48, 55, 60, 64, 67, 72]) }
        let out = Tidy.tidySong([.piano: crowded, .guitar: crowded], busyness: [.piano: 1.0, .guitar: 0.5])
        XCTAssertEqual(out[.piano]!.count, crowded.count)
        XCTAssertLessThan(out[.guitar]!.count, crowded.count)
    }

    func testNoteIdentitiesSurvive() {
        // Swift arrays are values, so "input is not modified" holds by construction; what matters
        // here is that kept notes keep their ids (the app tracks notes by id).
        let notes = chord(0, [36, 43], duration: 2) + chord(1, [38], duration: 2)
        let ids = Set(notes.map(\.id))
        XCTAssertTrue(run(.bass, notes).allSatisfy { ids.contains($0.id) })
    }

    // note_length and key: independent of busyness, and of each other

    func testNoteLengthAppliesEvenAtBusynessOne() {
        let notes = [note(0, 60, 0.03), note(0.1, 62, 0.03)]
        XCTAssertGreaterThan(tidy(.piano, notes, noteLength: 0.5)[0].duration, 0.03, "stretched toward the next onset")
        XCTAssertEqual(tidy(.piano, notes), notes, "without note length, busyness 1 is still a no-op")
    }

    func testLegatoStretchesShortNotesToTheNextOnset() {
        let out = Tidy.legato([note(0, 60, 0.02), note(1.0, 62, 0.02)], minLength: 0.5)
        XCTAssertEqual(out[0].duration, 0.5, accuracy: 1e-9, "capped, doesn't reach the next onset")
        XCTAssertEqual(out[1].duration, 0.5, accuracy: 1e-9, "nothing after it: gets the full length")
    }

    func testLegatoNeverOverlapsTheNextOnset() {
        let out = Tidy.legato([note(0, 60, 0.02), note(0.2, 62, 0.02)], minLength: 0.5)
        XCTAssertLessThanOrEqual(end(out[0]), out[1].start)
    }

    func testDrumsAreClampedNotStretched() {
        XCTAssertEqual(tidy(.drums, [note(0, 36, 20.0)], noteLength: 0.5)[0].duration, Tidy.drumMaxDuration)
    }

    func testPitchCooldownDropsDistantRepeatsOfOnePitch() {
        let notes = [0, 0.3, 0.6, 0.9, 1.2].map { note($0, 60, 0.05) }   // same pitch, 5 times
        let out = Tidy.pitchCooldown(.keys, notes)
        XCTAssertLessThanOrEqual(out.count, Tidy.pitchCooldownMax(.keys)!)
        XCTAssertEqual(out[0].start, 0, "the earliest onsets win")
    }

    func testPitchCooldownLeavesOtherPitchesAlone() {
        let notes = [(0.0, 60), (0.1, 62), (0.2, 64)].map { note($0.0, $0.1, 0.05) }
        XCTAssertEqual(Tidy.pitchCooldown(.keys, notes), notes)
    }

    func testStrictKeySnapsOutOfKeyNotes() {
        let key = MusicKey.pitchClasses["C major"]!   // white keys only
        let out = tidy(.piano, [note(0, 61)], key: key, keyStrict: true)   // C#, not in C major
        XCTAssertTrue(key.contains(out[0].pitch % 12))
    }

    func testKeyWithoutStrictLeavesNotesAlone() {
        let out = tidy(.piano, [note(0, 61)], key: MusicKey.pitchClasses["C major"]!, keyStrict: false)
        XCTAssertEqual(out[0].pitch, 61)
    }

    func testTidySongPassesNoteLengthAndKeyPerTrack() {
        let short = [note(0, 60, 0.02), note(0.5, 62, 0.02)]
        let out = Tidy.tidySong([.piano: short, .guitar: short], busyness: 1.0, noteLength: [.piano: 0.5])
        XCTAssertGreaterThan(out[.piano]![0].duration, 0.02)
        XCTAssertEqual(out[.guitar], short, "a track missing from the note length map is untouched")
    }

    // tempo and dynamics

    func testQuantizePullsOnsetsOntoTheSixteenthGrid() {
        let tempo = BeatGrid(bpm: 90, offset: 0.1)              // sixteenth = 1/6 s
        let notes = (0..<8).map { note(0.1 + Double($0) / 6 + 0.04) }
        for n in Tidy.quantize(notes, tempo: tempo, strength: 1) {
            let k = (n.start - 0.1) * 6
            XCTAssertEqual(k, k.rounded(), accuracy: 1e-3)
        }
        XCTAssertEqual(Tidy.quantize(notes, tempo: tempo, strength: 0.5)[0].start - 0.1, 0.02, accuracy: 1e-3)
        XCTAssertEqual(Tidy.quantize(notes, tempo: tempo, strength: 0), notes)
    }

    func testQuantizeKeepsLengths() {
        XCTAssertEqual(Tidy.quantize([note(0.33, 60, 0.7)], tempo: BeatGrid(bpm: 120), strength: 1)[0].duration, 0.7)
    }

    func testDynamicsZeroIsFlatAndOneVaries() {
        let notes = (0..<32).map { note(Double($0) * 0.25, 60 + $0 % 5) }
        var rng = Tidy.SeededRandom(seed: 0)
        let flat = Tidy.applyDynamics(.piano, notes, dynamics: 0, rng: &rng, tempo: BeatGrid(bpm: 120))
        XCTAssertEqual(Set(flat.map(\.velocity)), [TrackID.piano.baseVelocity])
        for seed in 0..<20 as Range<UInt64> {
            var rng = Tidy.SeededRandom(seed: seed)
            let vs = Tidy.applyDynamics(.piano, notes, dynamics: 1, rng: &rng, tempo: BeatGrid(bpm: 120)).map(\.velocity)
            XCTAssertGreaterThan(vs.max()! - vs.min()!, 15, "seed \(seed)")
            XCTAssertTrue(vs.allSatisfy { (20...120).contains($0) })
        }
    }

    func testDownbeatsAreLouderThanOffbeats() {
        let tempo = BeatGrid(bpm: 120)                         // beat 0.5 s, bar 2 s, sixteenth 0.125 s
        let notes = [0.0, 2, 4, 6].map { note($0, 60) } + [0.125, 2.125, 4.125, 6.125].map { note($0, 62) }
        for seed in 0..<20 as Range<UInt64> {
            var rng = Tidy.SeededRandom(seed: seed)
            let out = Tidy.applyDynamics(.piano, notes, dynamics: 1, rng: &rng, tempo: tempo)
            let down = out.filter { $0.pitch == 60 }.map(\.velocity).reduce(0, +)
            let off = out.filter { $0.pitch == 62 }.map(\.velocity).reduce(0, +)
            XCTAssertGreaterThan(down, off, "seed \(seed)")
        }
    }

    func testDrumRoles() {
        let hits = (0..<8).map { note(Double($0) * 0.5, 36) } + (0..<8).map { note(Double($0) * 0.5 + 0.25, 42) }
        for seed in 0..<20 as Range<UInt64> {
            var rng = Tidy.SeededRandom(seed: seed)
            let out = Tidy.applyDynamics(.drums, hits, dynamics: 1, rng: &rng)
            let kick = out.filter { $0.pitch == 36 }.map(\.velocity).reduce(0, +)
            let hat = out.filter { $0.pitch == 42 }.map(\.velocity).reduce(0, +)
            XCTAssertGreaterThan(kick, hat, "seed \(seed)")
        }
    }

    func testTempoAndDynamicsApplyAtBusynessOneAndAreOffByDefault() {
        let notes = [note(0.03, 60), note(0.52, 62)]
        XCTAssertEqual(run(.piano, notes, busyness: 1), notes)
        let out = tidy(.piano, notes, tempo: BeatGrid(bpm: 120), groove: 1)
        XCTAssertEqual(out.map(\.start), [0.0, 0.5])
    }

    // MARK: - Properties of the random parts

    /// Model-like notes: chords, repeats, long and very short notes.
    private func messyNotes(seed: UInt64, count: Int = 200, drums: Bool = false) -> [Note] {
        var r = Tidy.SeededRandom(seed: seed)
        var out: [Note] = [], t = 0.0
        while out.count < count {
            let size = r.unit() < 0.4 ? 2 + r.below(5) : 1
            let root = drums ? [35, 36, 38, 42, 46, 49, 51, 70][r.below(8)] : 40 + r.below(45)
            for k in 0..<size {
                let pitch = drums && k > 0 ? [36, 38, 42, 46][r.below(4)] : root + [0, 4, 7, 10, 14, 17][k]
                out.append(note(t + r.unit() * 0.02, pitch, [0.02, 0.1, 0.3, 0.8, 2.0][r.below(5)], 40 + r.below(70)))
            }
            t += [0.1, 0.125, 0.25, 0.5, 1.0][r.below(5)]
        }
        return out
    }

    func testChordShareStaysUnderTheLimitForEverySeed() {
        let notes = messyNotes(seed: 7)
        for track in [TrackID.piano, .guitar, .keys, .vibes] {
            for busyness in [0.0, 0.25, 0.5, 0.75] {
                for seed in 0..<10 as Range<UInt64> {
                    var rng = Tidy.SeededRandom(seed: seed)
                    let groups = Tidy.groupsOf(Tidy.thin(track, notes, busyness: busyness, rng: &rng))
                    let full = groups.filter { $0.count >= 3 }.count
                    let allowed = max(Int(Tidy.settings(track, busyness: busyness).chordShare * Double(groups.count)), 1)
                    XCTAssertLessThanOrEqual(full, allowed, "\(track) at \(busyness), seed \(seed)")
                    XCTAssertTrue(groups.allSatisfy { $0.count <= Tidy.rule(track).voices })
                }
            }
        }
    }

    func testDifferentSeedsThinDifferentChords() {
        let notes = (0..<20).flatMap { chord(Double($0) * 0.5, [60, 64, 67, 70], duration: 0.3) }
        let outcomes = Set((0..<10 as Range<UInt64>).map { seed in
            Tidy.groupsOf(run(.guitar, notes, seed: seed)).map(\.count)
        })
        XCTAssertGreaterThan(outcomes.count, 1, "the seed picks which chords are thinned")
    }

    func testDynamicsStayInRangeAndNearTheBase() {
        for track in TrackID.allCases {
            let notes = messyNotes(seed: 3, drums: track == .drums)
            for dynamics in [0.0, 0.3, 1.0, 2.0] {
                var rng = Tidy.SeededRandom(seed: 11)
                let vs = Tidy.applyDynamics(track, notes, dynamics: dynamics, rng: &rng,
                                            tempo: BeatGrid(bpm: 96, offset: 0.1)).map(\.velocity)
                XCTAssertTrue(vs.allSatisfy { (20...120).contains($0) }, "\(track) at \(dynamics)")
                let mean = Double(vs.reduce(0, +)) / Double(vs.count)
                XCTAssertEqual(mean, Double(track.baseVelocity), accuracy: Tidy.dynamicRange(track) * 0.5,
                               "\(track) at \(dynamics): loudness centres on the track's base")
            }
        }
    }

    func testMoreDynamicsMeansMoreSpread() {
        let notes = messyNotes(seed: 5)
        func spread(_ d: Double) -> Double {
            var rng = Tidy.SeededRandom(seed: 1)
            let vs = Tidy.applyDynamics(.piano, notes, dynamics: d, rng: &rng, tempo: BeatGrid(bpm: 100)).map { Double($0.velocity) }
            let mean = vs.reduce(0, +) / Double(vs.count)
            return (vs.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(vs.count)).squareRoot()
        }
        XCTAssertEqual(spread(0), 0)
        XCTAssertLessThan(spread(0.3), spread(1))
    }

    func testTidySongIsDeterministicPerSeed() {
        let song: [TrackID: [Note]] = [.piano: messyNotes(seed: 1), .guitar: messyNotes(seed: 2),
                                       .drums: messyNotes(seed: 3, drums: true), .vibes: messyNotes(seed: 4)]
        func go(_ seed: Int) -> [TrackID: [Note]] {
            Tidy.tidySong(song, busyness: 0.4, seed: seed, noteLength: 0.5, key: MusicKey.pitchClasses["D minor"],
                          keyStrict: true, tempo: BeatGrid(bpm: 92, offset: 0.05), groove: 0.6, dynamics: 0.8)
        }
        XCTAssertEqual(go(42), go(42))
        XCTAssertNotEqual(go(42), go(43))
        // each track has its own generator: removing one doesn't change the others
        let fewer = Tidy.tidySong(song.filter { $0.key != .guitar }, busyness: 0.4, seed: 42, noteLength: 0.5,
                                  key: MusicKey.pitchClasses["D minor"], keyStrict: true,
                                  tempo: BeatGrid(bpm: 92, offset: 0.05), groove: 0.6, dynamics: 0.8)
        XCTAssertEqual(fewer[.piano], go(42)[.piano])
    }

    func testSeededRandomIsReproducible() {
        var a = Tidy.SeededRandom("0-piano"), b = Tidy.SeededRandom("0-piano"), c = Tidy.SeededRandom("0-guitar")
        let xs = (0..<5).map { _ in a.next() }
        XCTAssertEqual(xs, (0..<5).map { _ in b.next() })
        XCTAssertNotEqual(xs, (0..<5).map { _ in c.next() })
        var r = Tidy.SeededRandom(seed: 9)
        let picked = r.sample(Array(0..<10), 4)
        XCTAssertEqual(Set(picked).count, 4)
        XCTAssertTrue(picked.allSatisfy { (0..<10).contains($0) })
        let g = (0..<4000).map { _ in r.gauss(0, 1) }
        XCTAssertEqual(g.reduce(0, +) / 4000, 0, accuracy: 0.1)
    }
}
