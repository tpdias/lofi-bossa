import Foundation

// Tempo: the model writes none, so it is estimated from its onsets (tracks.py `estimate_tempo`,
// `beat_phase`). Times are in the model's 10 ms ticks internally, as in Python.

extension BeatGrid {
    /// The tempo range the app offers and the estimate searches (tracks.py `TEMPO_RANGE`).
    static let estimateRange: ClosedRange<Double> = 60...140

    /// The tempo (bpm, beat offset) that best explains the notes' onsets, or nil with fewer
    /// than 8 distinct onsets.
    static func estimate(from notes: [Note], lo: Double = estimateRange.lowerBound,
                         hi: Double = estimateRange.upperBound) -> BeatGrid? {
        estimate(onsets: notes.map(\.start), lo: lo, hi: hi)
    }

    /// Onset autocorrelation on the 10 ms grid picks the beat period: a beat should repeat at
    /// one and two beats and also split cleanly in half, leaning toward the faster of a tempo
    /// and its half. The period is then refined to a tenth of a tick, and the offset is the
    /// phase whose beats meet the most onsets.
    static func estimate(onsets: [Double], lo: Double = estimateRange.lowerBound,
                         hi: Double = estimateRange.upperBound) -> BeatGrid? {
        let starts = Set(onsets.map { Int(PythonMath.round($0 * 100)) }).filter { $0 >= 0 }.sorted()
        guard starts.count >= 8, let last = starts.last else { return nil }
        var raw = [Double](repeating: 0, count: last + 1)
        for s in starts { raw[s] = 1 }
        // forgive a tick either way: convolve with [0.5, 1, 0.5]
        let env: [Double] = raw.indices.map { i in
            (i > 0 ? 0.5 * raw[i - 1] : 0) + raw[i] + (i + 1 < raw.count ? 0.5 * raw[i + 1] : 0)
        }

        func ac(_ lagValue: Double) -> Double {
            let lag = Int(PythonMath.round(lagValue))
            guard lag > 0, lag < env.count else { return 0 }
            var dot = 0.0
            for i in 0..<(env.count - lag) { dot += env[i] * env[i + lag] }
            return dot / Double(env.count - lag)
        }

        var bestLag: Int?
        var bestScore = -1.0
        for lag in Int(6000 / hi)...max(Int(6000 / hi), Int(6000 / lo)) {
            if lag * 2 >= env.count { break }
            // Between a tempo and its half, prefer the faster one: its sixteenth grid is finer.
            let z = (6000 / Double(lag) - 110) / 50
            let prior = exp(-0.5 * z * z)
            let l = Double(lag)
            let score = (ac(l) + 0.5 * ac(2 * l) + 0.5 * ac(l / 2)) * (0.7 + 0.3 * prior)
            if score > bestScore {
                bestLag = lag
                bestScore = score
            }
        }
        guard let bestLag else { return nil }

        let ticks = starts.map(Double.init)
        var period = 0.0, periodHits = Int.min
        for p in PythonMath.arange(Double(bestLag - 1), Double(bestLag) + 1.01, 0.1) {
            let hits = bestPhase(ticks, period: p).hits
            if hits > periodHits {
                period = p
                periodHits = hits
            }
        }
        let offset = bestPhase(ticks, period: period).offset
        return BeatGrid(bpm: PythonMath.round(6000 / period, 1), offset: PythonMath.round(offset / 100, 3))
    }

    /// Seconds: the beat offset at `bpm` whose beats meet the most onsets (0 with no notes).
    static func phase(of notes: [Note], bpm: Double) -> Double {
        phase(onsets: notes.map(\.start), bpm: bpm)
    }

    static func phase(onsets: [Double], bpm: Double) -> Double {
        guard !onsets.isEmpty else { return 0 }
        let best = bestPhase(onsets.map { $0 * 100 }, period: 6000 / bpm)
        return PythonMath.round(best.offset / 100, 3)
    }

    /// (onsets within 2 ticks of a beat, the first phase in half-tick steps with the most).
    private static func bestPhase(_ ticks: [Double], period: Double) -> (hits: Int, offset: Double) {
        var best = (hits: -1, offset: 0.0)
        for o in PythonMath.arange(0, period, 0.5) {
            var hits = 0
            for t in ticks {
                let d = PythonMath.mod(t - o, period)
                if min(d, period - d) <= 2 { hits += 1 }
            }
            if hits > best.hits { best = (hits, o) }
        }
        return best
    }
}
