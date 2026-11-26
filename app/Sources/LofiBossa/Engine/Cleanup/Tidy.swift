import Foundation

/// Clean-up of the model's notes before they reach the song: a Swift port of training/tidy.py.
///
/// The model tends to write long unbroken strings of short repeated notes and to stack four or
/// more notes on almost every onset; this thins that out per track, for model output only (notes
/// the user draws or pastes never come through here). `busyness` goes from 0 (sparse) through
/// 0.5 (default) to 1 (the model's notes, untouched). Independent knobs, applied whenever given:
/// `noteLength` (0 short .. 1 long) stretches staccato notes and clamps drum hits, `key` +
/// `keyStrict` snaps stray notes into the key, a tempo with `groove` > 0 quantizes onsets, and
/// `dynamics` (0 flat .. 1 expressive) writes velocities. Deterministic for a given seed.
enum Tidy {
    static let group = 0.03          // notes starting this close together are one onset (a chord)
    static let phraseGap = 0.25      // a silence at least this long ends a phrase
    static let repeatGap = 0.35      // repeats closer than this count as one run
    static let minLength = 0.05      // shortest a note may be cut to

    static let drumMaxDuration = 0.12   // seconds; a drum hit, not a held chord
    static let pitchCooldown = 1.5
    static let stepsPerBeat = 4         // the grid is sixteenth notes

    // MARK: - Busyness settings

    /// Most notes in one onset, default min time between onsets, default most onsets per
    /// second, default longest phrase (nil: drums play on without breathing).
    struct Rule: Equatable {
        var voices: Int
        var gap: Double
        var perSec: Double
        var phrase: Double?
    }

    static func rule(_ track: TrackID) -> Rule {
        switch track {
        case .piano: Rule(voices: 4, gap: 0.10, perSec: 8, phrase: 6.0)
        case .keys: Rule(voices: 4, gap: 0.25, perSec: 4, phrase: 8.0)
        case .guitar: Rule(voices: 4, gap: 0.10, perSec: 8, phrase: 6.0)
        case .bass: Rule(voices: 1, gap: 0.15, perSec: 5, phrase: 10.0)
        case .lead: Rule(voices: 1, gap: 0.12, perSec: 6, phrase: 5.0)
        case .vibes: Rule(voices: 3, gap: 0.12, perSec: 6, phrase: 5.0)
        case .drums: Rule(voices: 3, gap: 0.05, perSec: 12, phrase: nil)
        }
    }

    /// The thresholds for one track at a busyness.
    struct Settings: Equatable {
        var voices: Int
        var chordShare: Double
        var minGap: Double
        var perSec: Double
        var repeats: Double
        var phrase: Double?
        var rest: Double
    }

    /// Piecewise-linear: busyness 0 -> sparse, 0.5 -> default, 1 -> busy.
    static func knob(_ busyness: Double, sparse: Double, normal: Double, busy: Double) -> Double {
        let b = min(max(busyness, 0), 1)
        if b <= 0.5 { return sparse + (normal - sparse) * b / 0.5 }
        return normal + (busy - normal) * (b - 0.5) / 0.5
    }

    static func settings(_ track: TrackID, busyness: Double) -> Settings {
        let r = rule(track)
        return Settings(
            voices: r.voices,
            chordShare: knob(busyness, sparse: 0.3, normal: 0.6, busy: 1.0),
            minGap: knob(busyness, sparse: r.gap * 2, normal: r.gap, busy: 0.0),
            perSec: knob(busyness, sparse: r.perSec * 0.6, normal: r.perSec, busy: 1000.0),
            repeats: knob(busyness, sparse: 2, normal: 4, busy: 1000),
            phrase: r.phrase.map { knob(busyness, sparse: $0 / 2, normal: $0, busy: 1e9) },
            rest: knob(busyness, sparse: 1.0, normal: 0.5, busy: 0.0))
    }

    // MARK: - Note length

    /// Seconds: the "normal" (note length 0.5) minimum new note length, per melodic track.
    static func baseNoteLength(_ track: TrackID) -> Double {
        switch track {
        case .keys: 0.35
        case .guitar: 0.18
        case .bass, .lead: 0.30
        case .vibes: 0.18
        case .piano, .drums: 0.20     // drums: Python falls back to piano's
        }
    }

    /// Within `pitchCooldown` seconds the same pitch may restart at most this many times.
    static func pitchCooldownMax(_ track: TrackID) -> Int? {
        switch track {
        case .keys, .lead, .vibes, .bass: 2
        case .piano, .guitar: 3
        case .drums: nil
        }
    }

    /// Seconds: the shortest a new note on this (non-drum) track should be.
    static func minDuration(_ track: TrackID, noteLength: Double) -> Double {
        let base = baseNoteLength(track)
        return knob(noteLength, sparse: base * 0.3, normal: base, busy: base * 3)
    }

    /// Notes shorter than `minLength` are stretched up to the next onset of this track (any
    /// pitch), capped at `minLength`, instead of ending early and leaving a silent gap. A note
    /// past every other one is simply given the full length. Returns the notes sorted by onset.
    static func legato(_ notes: [Note], minLength target: Double) -> [Note] {
        guard !notes.isEmpty else { return notes }
        var ns = PythonMath.sorted(notes, by: byOnset)
        for i in ns.indices where ns[i].duration < target {
            let start = ns[i].start
            var j = i + 1
            while j < ns.count, ns[j].start <= start { j += 1 }
            let ceiling = j < ns.count ? ns[j].start : start + target
            ns[i].duration = max(ns[i].duration, min(target, max(ceiling - start, minLength)))
        }
        return ns
    }

    /// A drum "note" is a hit, not a held chord; anything longer than `drumMaxDuration` is cut.
    static func clampDrums(_ notes: [Note]) -> [Note] {
        notes.map { var n = $0; n.duration = min(n.duration, drumMaxDuration); return n }
    }

    /// Drop the extra onsets once the same pitch has restarted `pitchCooldownMax(track)` times
    /// within any `pitchCooldown`-second span (the earliest onsets win). Keeps the input order.
    static func pitchCooldown(_ track: TrackID, _ notes: [Note]) -> [Note] {
        guard let limit = pitchCooldownMax(track), limit > 0, !notes.isEmpty else { return notes }
        let order = PythonMath.sorted(Array(notes.indices)) { notes[$0].start < notes[$1].start }
        var byPitch: [Int: [Int]] = [:]
        var pitches: [Int] = []
        for i in order {
            if byPitch[notes[i].pitch] == nil { pitches.append(notes[i].pitch) }
            byPitch[notes[i].pitch, default: []].append(i)
        }
        var drop = Set<Int>()
        for pitch in pitches {
            var window: [Double] = []
            for i in byPitch[pitch]! {
                let t = notes[i].start
                window = window.filter { t - $0 < pitchCooldown }
                if window.count >= limit {
                    drop.insert(i)
                } else {
                    window.append(t)
                }
            }
        }
        return notes.indices.filter { !drop.contains($0) }.map { notes[$0] }
    }

    /// Move any note outside `key` (pitch classes, e.g. `MusicKey.pitchClasses["A minor"]`) to
    /// the nearest in-key pitch, trying a step down before a step up.
    static func snapToKey(_ notes: [Note], key: Set<Int>) -> [Note] {
        notes.map { note in
            var n = note
            let pc = PythonMath.mod(n.pitch, 12)
            guard !key.contains(pc) else { return n }
            for d in 1..<7 {
                if key.contains(PythonMath.mod(pc - d, 12)) { n.pitch -= d; break }
                if key.contains(PythonMath.mod(pc + d, 12)) { n.pitch += d; break }
            }
            return n
        }
    }

    // MARK: - Tempo and dynamics

    /// Seconds between sixteenth notes.
    static func gridStep(_ tempo: BeatGrid) -> Double { 60.0 / tempo.bpm / Double(stepsPerBeat) }

    /// Pull every onset toward the nearest sixteenth of `tempo` by `strength` (0 untouched,
    /// 1 exactly on the grid); each note keeps its length.
    static func quantize(_ notes: [Note], tempo: BeatGrid, strength: Double) -> [Note] {
        guard !notes.isEmpty, strength > 0 else { return notes }
        let step = gridStep(tempo), offset = tempo.offset
        return notes.map { note in
            var n = note
            let target = offset + PythonMath.round((n.start - offset) / step) * step
            n.start = max(PythonMath.round(n.start + (target - n.start) * min(strength, 1), 4), 0)
            return n
        }
    }

    /// Loudness range around each track's base velocity at dynamics 1.
    static func dynamicRange(_ track: TrackID) -> Double {
        switch track {
        case .piano: 26
        case .guitar: 24
        case .bass: 14
        case .drums: 30
        case .keys: 14
        case .lead: 24
        case .vibes: 22
        }
    }

    /// Write velocities instead of the model's flat default. `dynamics` 0 keeps every note at
    /// the track's base; up to 1 adds beat accents (with a tempo: downbeats and, for drums,
    /// backbeats louder, off-beat sixteenths softer), a rise and fall over each phrase, the top
    /// note of a chord a little louder, drum roles (kick and snare up, hi-hats down), and a
    /// little jitter. Returns the notes sorted by onset.
    static func applyDynamics(_ track: TrackID, _ notes: [Note], dynamics: Double,
                              rng: inout SeededRandom, tempo: BeatGrid? = nil, base: Int? = nil) -> [Note] {
        guard !notes.isEmpty else { return notes }
        let base = base ?? track.baseVelocity
        let spread = dynamicRange(track) * min(max(dynamics, 0), 1)
        var ns = PythonMath.sorted(notes, by: byOnset)
        if spread <= 0 {
            for i in ns.indices { ns[i].velocity = base }
            return ns
        }

        // phrases: split where the track goes quiet for phraseGap
        var phrases: [[Int]] = [[]]
        var lastEnd: Double?
        for i in ns.indices {
            if let lastEnd, ns[i].start - lastEnd >= phraseGap { phrases.append([]) }
            phrases[phrases.count - 1].append(i)
            lastEnd = max(lastEnd ?? 0, end(ns[i]))
        }
        var position = [Double](repeating: 0, count: ns.count)
        for ph in phrases {
            let a = ns[ph.first!].start, b = ns[ph.last!].start
            for i in ph { position[i] = b > a ? (ns[i].start - a) / (b - a) : 0.5 }
        }
        // the last note of each multi-note onset (sorted, so the highest of a true chord)
        var tops = Set<Int>()
        var groupStart = 0
        for i in ns.indices.dropFirst() where !(ns[i].start - ns[groupStart].start < group) {
            if i - groupStart > 1 { tops.insert(i - 1) }
            groupStart = i
        }
        if ns.count - groupStart > 1 { tops.insert(ns.count - 1) }

        for i in ns.indices {
            let n = ns[i]
            var v = 0.35 * spread * sin(.pi * position[i]) - 0.1 * spread    // phrase arc
            if let tempo {
                let beats = (n.start - tempo.offset) * tempo.bpm / 60.0
                let sixteenth = PythonMath.mod(Int(PythonMath.round(beats * Double(stepsPerBeat))),
                                               4 * stepsPerBeat)            // position in a 4/4 bar
                if sixteenth == 0 {
                    v += 0.45 * spread                       // downbeat
                } else if sixteenth % stepsPerBeat == 0 {
                    v += 0.2 * spread                        // other beats
                    if track == .drums, sixteenth == 4 || sixteenth == 12 {
                        v += 0.2 * spread                    // backbeat
                    }
                } else if sixteenth % 2 == 1 {
                    v -= 0.3 * spread                        // off-beat sixteenths
                }
            }
            if track == .drums {
                let role: Double = switch DrumCategory(pitch: n.pitch) {
                case .kick: 0.3
                case .snare: 0.25
                case .hihat: -0.3
                case .cymbal: 0.1
                case .tom: 0.0
                case .perc: -0.2
                }
                v += role * spread
            } else if tops.contains(i) {
                v += 0.2 * spread                            // melody on top of a chord
            }
            v += rng.gauss(0, 0.12 * spread)
            ns[i].velocity = Int(min(max(PythonMath.round(Double(base) + v), 20), 120))
        }
        return ns
    }

    // MARK: - Groups

    /// Notes sorted and grouped by onset.
    static func groupsOf(_ notes: [Note]) -> [[Note]] {
        var out: [[Note]] = []
        for n in PythonMath.sorted(notes, by: byOnset) {
            if let first = out.last?.first, n.start - first.start < group {
                out[out.count - 1].append(n)
            } else {
                out.append([n])
            }
        }
        return out
    }

    static func byOnset(_ a: Note, _ b: Note) -> Bool {
        a.start < b.start || (a.start == b.start && a.pitch < b.pitch)
    }

    static func end(_ n: Note) -> Double { n.start + n.duration }

    static func cut(_ n: inout Note, at t: Double) { n.duration = max(t - n.start, minLength) }

    // MARK: - Whole track / whole song

    /// Cleaned copy of one track's notes, sorted by onset.
    ///
    /// busyness >= 1 skips the busyness-driven thinning (the model's raw notes). `noteLength`
    /// (nil = off) runs legato + pitch cooldown, or clamps drums; `key` (nil = off) snaps notes
    /// into it when `keyStrict`; `tempo` with `groove` > 0 pulls onsets toward its sixteenths;
    /// `dynamics` (nil = off) writes the velocities, last.
    static func tidyTrack(_ track: TrackID, _ notes: [Note], busyness: Double, rng: inout SeededRandom,
                          noteLength: Double? = nil, key: Set<Int>? = nil, keyStrict: Bool = false,
                          tempo: BeatGrid? = nil, groove: Double = 0, dynamics: Double? = nil) -> [Note] {
        var ns = notes
        guard !ns.isEmpty else { return ns }
        if busyness < 1 { ns = thin(track, ns, busyness: busyness, rng: &rng) }
        if let noteLength {
            if track == .drums {
                ns = clampDrums(ns)
            } else {
                ns = pitchCooldown(track, legato(ns, minLength: minDuration(track, noteLength: noteLength)))
            }
        }
        if let key, keyStrict, track != .drums { ns = snapToKey(ns, key: key) }
        if let tempo, groove > 0 { ns = quantize(ns, tempo: tempo, strength: groove) }
        if let dynamics { ns = applyDynamics(track, ns, dynamics: dynamics, rng: &rng, tempo: tempo) }
        return PythonMath.sorted(ns, by: byOnset)
    }

    /// One value for every track, or a value per track.
    enum PerTrack: Equatable, ExpressibleByFloatLiteral, ExpressibleByIntegerLiteral, ExpressibleByDictionaryLiteral {
        case all(Double)
        case each([TrackID: Double])

        init(floatLiteral value: Double) { self = .all(value) }
        init(integerLiteral value: Int) { self = .all(Double(value)) }
        init(dictionaryLiteral elements: (TrackID, Double)...) {
            self = .each(Dictionary(elements, uniquingKeysWith: { $1 }))
        }

        func value(for track: TrackID) -> Double? {
            switch self {
            case .all(let v): v
            case .each(let map): map[track]
            }
        }
    }

    /// Cleaned copy of {track: notes}. `busyness` and `noteLength` are each one value or per
    /// track (a track missing from the map uses 0.5 for busyness and skips note length). `key`
    /// is one set of pitch classes for the whole song, or nil. `only` limits the clean-up to
    /// those tracks; the rest are copied as-is. Each track draws from its own generator seeded
    /// with "\(seed)-\(track)", so adding a track doesn't change the others.
    static func tidySong(_ tracks: [TrackID: [Note]], busyness: PerTrack, seed: Int = 0,
                         only: Set<TrackID>? = nil, noteLength: PerTrack? = nil, key: Set<Int>? = nil,
                         keyStrict: Bool = false, tempo: BeatGrid? = nil, groove: Double = 0,
                         dynamics: Double? = nil) -> [TrackID: [Note]] {
        var out: [TrackID: [Note]] = [:]
        for (track, notes) in tracks {
            if let only, !only.contains(track) {
                out[track] = notes
                continue
            }
            var rng = SeededRandom("\(seed)-\(track.rawValue)")
            out[track] = tidyTrack(track, notes, busyness: busyness.value(for: track) ?? 0.5, rng: &rng,
                                   noteLength: noteLength?.value(for: track), key: key, keyStrict: keyStrict,
                                   tempo: tempo, groove: groove, dynamics: dynamics)
        }
        return out
    }

    // MARK: - Report

    struct Stats: Equatable {
        var notes: Int
        var perSec: Double
        var chordShare: Double
        var longestPhrase: Double
        var maxSounding: Int
    }

    /// Notes per second, share of full chords, longest phrase, most notes sounding at once.
    static func stats(_ notes: [Note], seconds: Double) -> Stats {
        let groups = groupsOf(notes)
        guard let firstGroup = groups.first else {
            return Stats(notes: 0, perSec: 0, chordShare: 0, longestPhrase: 0, maxSounding: 0)
        }
        var longest = 0.0, phraseStart = firstGroup[0].start
        var lastEnd: Double?
        for g in groups {
            let t = g[0].start
            let groupEnd = g.map(end).max()!
            if let lastEnd, t - lastEnd >= phraseGap { phraseStart = t }
            longest = max(longest, groupEnd - phraseStart)
            lastEnd = max(lastEnd ?? 0, groupEnd)
        }
        let onsets: [(time: Double, delta: Int)] = notes.map { ($0.start, 1) }
        let ends: [(time: Double, delta: Int)] = notes.map { (end($0), -1) }
        let edges = PythonMath.sorted(onsets + ends) { a, b in
            a.time < b.time || (a.time == b.time && a.delta < b.delta)
        }
        var sounding = 0, peak = 0
        for (_, d) in edges {
            sounding += d
            peak = max(peak, sounding)
        }
        return Stats(
            notes: notes.count,
            perSec: PythonMath.round(Double(notes.count) / max(seconds, 1e-6), 2),
            chordShare: PythonMath.round(Double(groups.filter { $0.count >= 3 }.count) / Double(groups.count), 2),
            longestPhrase: PythonMath.round(longest, 1),
            maxSounding: peak)
    }
}
