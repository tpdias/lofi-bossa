import Foundation

extension Tidy {
    /// The busyness-driven thinning (steps 1-6 of tidy.py `tidy_track`, `_thin`).
    static func thin(_ track: TrackID, _ notes: [Note], busyness: Double, rng: inout SeededRandom) -> [Note] {
        let s = settings(track, busyness: busyness)
        let drums = track == .drums
        var groups = groupsOf(notes)

        // 1. chord size
        groups = groups.map { capGroup($0, voices: s.voices, bassLike: track == .bass) }

        // 2. repeat spam: the same notes again and again in quick succession
        if !drums {
            var kept: [[Note]] = []
            var run = 0
            var prev: (pitches: [Int], start: Double)?
            for g in groups {
                let key = g.map(\.pitch).sorted()
                if let prev, key == prev.pitches, g[0].start - prev.start < repeatGap {
                    run += 1
                } else {
                    run = 1
                }
                prev = (key, g[0].start)
                // As in Python: `repeats` is fractional between busyness stops, and then
                // (run - repeats) % 2 is never exactly 1, so nothing is dropped here.
                if Double(run) > s.repeats, PythonMath.mod(Double(run) - s.repeats, 2) == 1 { continue }
                kept.append(g)
            }
            groups = kept
        }

        // 3. density: a minimum gap between onsets and a cap per second
        var densityKept: [[Note]] = []
        var starts: [Double] = []
        for g in groups {
            let t = g[0].start
            if let last = starts.last, t - last < s.minGap { continue }
            if Double(starts.filter { $0 > t - 1.0 }.count) >= s.perSec { continue }
            densityKept.append(g)
            starts.append(t)
        }
        groups = densityKept

        // 4. phrase rests: a part that never stops gets a breath
        if let phrase = s.phrase, s.rest > 0 {
            var kept: [[Note]] = []
            var phraseStart: Double?
            var lastEnd: Double?
            var restUntil = -1.0
            for g in groups {
                let t = g[0].start
                if t < restUntil { continue }
                if phraseStart == nil || (lastEnd.map { t - $0 >= phraseGap } ?? false) {
                    phraseStart = t
                }
                if t - phraseStart! > phrase {
                    restUntil = t + s.rest
                    for gi in kept.indices {               // nothing rings into the rest
                        for ni in kept[gi].indices where end(kept[gi][ni]) > t {
                            cut(&kept[gi][ni], at: t)
                        }
                    }
                    phraseStart = nil
                    lastEnd = nil
                    continue
                }
                kept.append(g)
                let groupEnd = g.map(end).max()!
                lastEnd = lastEnd.map { max($0, groupEnd) } ?? groupEnd
            }
            groups = kept
        }

        // 5. chord share, over the onsets that are left: too many full chords -> thin the
        // excess to top and bottom (a song with a single chord keeps it)
        if !drums {
            let full = groups.indices.filter { groups[$0].count >= 3 }
            let allowed = max(Int((s.chordShare * Double(groups.count)).rounded(.down)), 1)
            let excess = full.count - allowed
            if excess > 0 {
                for i in rng.sample(full, excess) {
                    let g = PythonMath.sorted(groups[i]) { $0.pitch < $1.pitch }
                    groups[i] = track == .vibes ? [g[g.count - 1]] : [g[0], g[g.count - 1]]
                }
            }
        }

        // 6. sounding notes: shorten older notes so no more than `voices` ring at once
        if !drums {
            var active: [(g: Int, n: Int)] = []
            for gi in groups.indices {
                let t = groups[gi][0].start
                active = active.filter { end(groups[$0.g][$0.n]) > t + 1e-6 }
                let over = active.count + groups[gi].count - s.voices
                let oldest = PythonMath.sorted(active) { groups[$0.g][$0.n].start < groups[$1.g][$1.n].start }
                for a in oldest.prefix(max(over, 0)) { cut(&groups[a.g][a.n], at: t) }
                active = active.filter { end(groups[$0.g][$0.n]) > t + 1e-6 }
                    + groups[gi].indices.map { (gi, $0) }
            }
        }

        return groups.flatMap { $0 }
    }

    /// At most `voices` notes of one onset: the lowest and highest, then the loudest between
    /// them (one voice: the lowest for bass, the highest otherwise).
    static func capGroup(_ group: [Note], voices: Int, bassLike: Bool) -> [Note] {
        guard group.count > voices else { return group }
        let byPitch = PythonMath.sorted(group) { $0.pitch < $1.pitch }
        if voices == 1 { return [bassLike ? byPitch[0] : byPitch[byPitch.count - 1]] }
        let middle = PythonMath.sorted(Array(byPitch[1..<(byPitch.count - 1)])) { $0.velocity > $1.velocity }
        let keep = [byPitch[0], byPitch[byPitch.count - 1]] + middle.prefix(voices - 2)
        return PythonMath.sorted(keep) { $0.pitch < $1.pitch }
    }
}
