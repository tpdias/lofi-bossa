import Foundation

/// Anything that turns tokens into next-token logits: the Core AI model in the app, a fake in
/// tests. Tokens are fed at absolute positions in the model's 1024-token window.
protocol LogitsModel: AnyObject {
    /// Feeds `tokens` at positions `start...` and returns the logits after the last one.
    func feed(_ tokens: [Int32], at start: Int) async throws -> [Float]
}

/// A small seedable generator (SplitMix64), so a seed reproduces a take.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// The constraints `training/sampler.py` applies while sampling; same names and defaults.
struct SamplerOptions {
    var topP: Float = 0.98
    /// Subtracted from the rest logit; `.infinity` forbids rests.
    var restPenalty: Float = 0
    var maxNotesPerSecond = 24
    var maxRests = 2
    /// Pitch classes (0 = C) new non-drum notes are nudged toward, or confined to when strict.
    var key: Set<Int>? = nil
    var keyStrict = false
    var keyPenalty: Float = 3
    /// Hard floor on new notes' duration in ticks (single-track writing only).
    var minDurationTicks = 0
    var durationBiasTicks = 200
    var durationBias: Float = 1.5
    /// GM drum pitch -> minimum ticks since that pitch's last hit.
    var drumMinGapTicks: [Int: Int] = [:]
    /// A tempo's sixteenth-note grid (step, offset) in ticks; onsets on it get `gridBonus`.
    var grid: (step: Double, offset: Double)? = nil
    var gridBonus: Float = 0
}

/// The model's cached view of the token sequence (`_Context` in sampler.py). Position 0 holds
/// the mode token; event and control tokens follow, with times relative to `offset`.
final class SamplerContext {
    static let window = 1017      // event/control tokens the model sees (+1 mode token, room for 1 event)
    static let keep = 678         // tokens kept when the window is rebuilt
    static let maxSpan = 6000     // ticks; relative times stay well under maxTime (100 s)

    private let model: LogitsModel
    private let mode: Int
    private(set) var offset = 0
    private(set) var length = 0
    private(set) var logits: [Float] = []

    init(model: LogitsModel, mode: Int) {
        self.model = model
        self.mode = mode
    }

    func rebuild(_ tokens: [Event], current: Int, keep: Int = SamplerContext.window) async throws {
        var keepEvents = (keep - keep % 3) / 3
        var window: [Event]
        while true {
            window = keepEvents > 0 ? Array(tokens.suffix(keepEvents)) : []
            offset = window.isEmpty ? current : min(EventOps.minTime(window), current)
            if current - offset <= Self.maxSpan || keepEvents <= 1 { break }
            let halfTokens = keepEvents * 3 / 2
            keepEvents = (halfTokens - halfTokens % 3) / 3
        }
        length = window.count * 3
        logits = try await model.feed([Int32(mode)] + relative(window), at: 0)
    }

    private func relative(_ events: [Event]) -> [Int32] {
        events.flatMap { [Int32($0.time - offset), Int32($0.dur), Int32($0.note)] }
    }

    func needsRebuild(extraTokens: Int, current: Int) -> Bool {
        length + extraTokens > Self.window || current - offset > Self.maxSpan
    }

    /// Appends whole triples (absolute times).
    func feed(_ events: [Event]) async throws {
        let tokens = relative(events)
        logits = try await model.feed(tokens, at: 1 + length)
        length += tokens.count
    }

    /// Appends one token of the event being sampled (already relative).
    func feed(token: Int) async throws {
        logits = try await model.feed([Int32(token)], at: 1 + length)
        length += 1
    }
}

/// The sampling loop of `training/sampler.py`: `generate`, `accompany` and `rewriteRange`.
enum Sampler {
    static let maxSameTick = 12   // notes allowed on one 10 ms tick before time is forced forward
    static let maxStep = 150      // ticks; the furthest one event may be from the previous one
    static let maxAhead = 120     // fixed notes shown ahead of the current time

    /// Generates events between `start` and `end` seconds. `inputs` are events to continue from
    /// (those after `start` are kept fixed); `controls` are fixed notes (as controls) to write
    /// around; `instruments` are the model instruments new notes may use (nil = any).
    /// Returns the new events merged with the inputs, sorted; controls aren't included.
    static func generate(model: LogitsModel, start startSeconds: Double, end endSeconds: Double,
                         inputs: [Event] = [], controls: [Event] = [], instruments: [Int]? = nil,
                         options: SamplerOptions = SamplerOptions(), seed: UInt64,
                         progress: ((Double) -> Void)? = nil) async throws -> [Event] {
        var rng = SeededGenerator(seed: seed)
        let start = Int(Double(Vocab.timeResolution) * startSeconds)
        let end = Int(Double(Vocab.timeResolution) * endSeconds)

        // Notes the model may choose (whitelisted instruments + the rest), and their biases.
        var allowed = [Bool](repeating: false, count: Vocab.maxNote + 1)
        for instrument in instruments ?? Array(0..<Vocab.maxInstrument) {
            for p in 0..<Vocab.maxPitch { allowed[instrument * Vocab.maxPitch + p] = true }
        }
        allowed[Vocab.maxNote] = true
        var noteBias = [Float](repeating: 0, count: Vocab.maxNote + 1)
        noteBias[Vocab.maxNote] = -options.restPenalty
        if let key = options.key {
            for instrument in 0..<(Vocab.maxInstrument - 1) {
                for pitch in 0..<Vocab.maxPitch where !key.contains(pitch % 12) {
                    let i = instrument * Vocab.maxPitch + pitch
                    if options.keyStrict { allowed[i] = false } else { noteBias[i] -= options.keyPenalty }
                }
            }
        }
        var noRest = allowed
        noRest[Vocab.maxNote] = false
        let drumsAllowed = allowed[Vocab.drums * Vocab.maxPitch]
        var drumLast: [Int: Int] = [:]

        var durationBias = [Float](repeating: 0, count: Vocab.maxDur)
        if options.durationBiasTicks > 0, options.durationBias > 0 {
            for d in 1..<min(options.durationBiasTicks, Vocab.maxDur) {
                durationBias[d] = -options.durationBias * (1 - Float(d) / Float(options.durationBiasTicks))
            }
        }

        let prompt = EventOps.pad(EventOps.clip(inputs, start: 0, end: start, clipDuration: false), endTime: start)
        let future = inputs.isEmpty ? [] :
            EventOps.clip(inputs, start: start + 1, end: EventOps.maxTime(inputs), clipDuration: false)
        let allPending = EventOps.sort(controls + future.map(\.asControl))
        let mode = allPending.isEmpty ? Vocab.autoregress : Vocab.anticipate
        var (tokens, pending) = EventOps.anticipate(prompt, controls: allPending)
        var current = prompt.isEmpty ? 0 : EventOps.maxTime(prompt)

        let context = SamplerContext(model: model, mode: mode)
        try await context.rebuild(tokens, current: current)
        var sameTick = 0, restRun = 0
        var recent: [Int] = []          // start ticks of the latest new notes
        var ahead: [Int] = []           // revealed fixed notes still to come
        var nextFixed = 0

        while true {
            try Task.checkCancellation()
            // Reveal fixed notes up to `delta` ahead (only the nearest `maxAhead` when dense).
            ahead.removeAll { $0 <= current }
            var due: [Event] = []
            while nextFixed < pending.count {
                let fixedTime = pending[nextFixed].tick
                if fixedTime > current, fixedTime > current + Vocab.delta || ahead.count >= maxAhead { break }
                due.append(pending[nextFixed])
                nextFixed += 1
                if fixedTime > current { ahead.append(fixedTime) }
            }
            tokens += due
            if context.needsRebuild(extraTokens: due.count * 3 + 3, current: current) {
                try await context.rebuild(tokens, current: current, keep: SamplerContext.keep)
            } else if !due.isEmpty {
                try await context.feed(due)
            }

            // Time: never in the past, pushed forward when notes pile up on a tick or in a second.
            var earliest = max(start, current) + (sameTick >= maxSameTick ? 1 : 0)
            if recent.count == options.maxNotesPerSecond, let first = recent.first {
                earliest = max(earliest, first + Vocab.timeResolution)
            }
            if earliest >= end { break }
            let offset = context.offset
            var timeLogits = Array(context.logits[Vocab.timeOffset..<(Vocab.timeOffset + Vocab.maxTime)])
            let lo = max(earliest - offset, 0), hi = min(earliest - offset + maxStep + 1, timeLogits.count)
            for i in 0..<timeLogits.count where i < lo || i >= hi { timeLogits[i] = -.infinity }
            if let grid = options.grid, options.gridBonus > 0, lo < hi {
                for i in lo..<hi {
                    var phase = (Double(i + offset) - grid.offset).truncatingRemainder(dividingBy: grid.step)
                    if phase < 0 { phase += grid.step }
                    if min(phase, grid.step - phase) <= 1 { timeLogits[i] += options.gridBonus }
                }
            }
            let relTime = sample(timeLogits, topP: options.topP, using: &rng)
            let newTime = relTime + offset
            if newTime >= end { break }
            try await context.feed(token: Vocab.timeOffset + relTime)

            var durLogits = zip(context.logits[Vocab.durOffset..<(Vocab.durOffset + Vocab.maxDur)], durationBias).map { $0 + $1 }
            let forceNote = restRun >= options.maxRests
            if options.restPenalty > 0 || forceNote { durLogits[0] = -.infinity }
            if options.minDurationTicks > 1 {
                for d in 1..<min(options.minDurationTicks, Vocab.maxDur) { durLogits[d] = -.infinity }
            }
            let dur = sample(durLogits, topP: options.topP, using: &rng)
            try await context.feed(token: Vocab.durOffset + dur)

            var mask = forceNote ? noRest : allowed
            if drumsAllowed {
                for (pitch, gap) in options.drumMinGapTicks {
                    if let last = drumLast[pitch], newTime - last < gap { mask[Vocab.drums * Vocab.maxPitch + pitch] = false }
                }
            }
            var noteLogits = Array(context.logits[Vocab.noteOffset...(Vocab.noteOffset + Vocab.maxNote)])
            for i in 0..<noteLogits.count { noteLogits[i] = mask[i] ? noteLogits[i] + noteBias[i] : -.infinity }
            let note = sample(noteLogits, topP: options.topP, using: &rng)
            try await context.feed(token: Vocab.noteOffset + note)
            if note / Vocab.maxPitch == Vocab.drums { drumLast[note % Vocab.maxPitch] = newTime }

            tokens.append(Event(time: Vocab.timeOffset + newTime, dur: Vocab.durOffset + dur, note: Vocab.noteOffset + note))
            sameTick = newTime == current ? sameTick + 1 : 0
            if note != Vocab.maxNote {
                recent.append(newTime)
                if recent.count > options.maxNotesPerSecond { recent.removeFirst() }
                restRun = 0
            } else {
                restRun += 1
            }
            current = newTime
            progress?(Double(current - start) / Double(max(end - start, 1)))
        }
        let events = EventOps.split(tokens).events
        return EventOps.sort(EventOps.unpad(events) + future)
    }

    /// New notes for `instruments` around fixed events; retried with rests discouraged, then
    /// forbidden, while sparser than `minNotesPerSecond`. Returns only the new events.
    /// `restPenalties` are the attempts in order (the server's are 0, 4, then forbidden).
    static func accompany(model: LogitsModel, fixed: [Event], seconds: Double, instruments: [Int],
                          options: SamplerOptions = SamplerOptions(), seed: UInt64,
                          minNotesPerSecond: Double = 0.5, restPenalties: [Float] = [0, 4, .infinity],
                          progress: ((Double) -> Void)? = nil) async throws -> [Event] {
        var new: [Event] = []
        for penalty in restPenalties {
            var o = options
            o.restPenalty = penalty
            o.maxNotesPerSecond = 12
            o.maxRests = 8
            new = try await generate(model: model, start: 0, end: seconds, controls: fixed.map(\.asControl),
                                     instruments: instruments, options: o, seed: seed, progress: progress)
            if Double(new.count) >= minNotesPerSecond * seconds { break }
        }
        return new
    }

    /// Rewrites `instruments` between `start` and `end` seconds; everything else is kept as
    /// context. Returns only the new events, all starting inside the range.
    static func rewriteRange(model: LogitsModel, events: [Event], instruments: [Int], start: Double, end: Double,
                             options: SamplerOptions = SamplerOptions(), seed: UInt64,
                             minNotesPerSecond: Double = 0.5, progress: ((Double) -> Void)? = nil) async throws -> [Event] {
        let startTick = Int(Double(Vocab.timeResolution) * start), endTick = Int(Double(Vocab.timeResolution) * end)
        let wanted = Set(instruments)
        let inRange = { (e: Event) in wanted.contains(e.instrument) && startTick <= e.tick && e.tick < endTick }
        let kept = events.filter { !inRange($0) }
        var new: [Event] = []
        for penalty in [Float(0), 4, .infinity] {
            var o = options
            o.restPenalty = penalty
            o.maxNotesPerSecond = 12
            o.maxRests = 8
            let merged = try await generate(model: model, start: start, end: end, inputs: kept,
                                            instruments: instruments, options: o, seed: seed, progress: progress)
            new = merged.filter(inRange).map { e in
                var e = e
                e.dur = Vocab.durOffset + min(e.durationTicks, endTick - e.tick)
                return e
            }
            if Double(new.count) >= minNotesPerSecond * (end - start) { break }
        }
        return new
    }

    /// Top-p (nucleus) sampling over logits; -infinity entries are never chosen.
    static func sample(_ logits: [Float], topP: Float, using rng: inout SeededGenerator) -> Int {
        let maxLogit = logits.max() ?? 0
        guard maxLogit > -.infinity else { return 0 }
        var order = logits.indices.filter { logits[$0] > -.infinity }
        var weights = order.map { exp(logits[$0] - maxLogit) }
        if topP < 1 {
            let sortedPositions = weights.indices.sorted { weights[$0] > weights[$1] }
            let total = weights.reduce(0, +)
            var cumulative: Float = 0
            var keep: [Int] = []
            for p in sortedPositions {
                keep.append(p)
                cumulative += weights[p] / total
                if cumulative > topP { break }      // keep the token that crosses top_p, as torch does
            }
            order = keep.map { order[$0] }
            weights = keep.map { weights[$0] }
        }
        let total = weights.reduce(0, +)
        var r = Float.random(in: 0..<total, using: &rng)
        for (i, w) in weights.enumerated() {
            if r < w { return order[i] }
            r -= w
        }
        return order.last!
    }
}
