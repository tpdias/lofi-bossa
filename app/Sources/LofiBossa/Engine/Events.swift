import Foundation

/// The Anticipatory Music Transformer's token vocabulary and event helpers, ported from the
/// `anticipation` library (`vocab.py`, `config.py`, `ops.py`) and `training/tracks.py`.
///
/// Music is a flat list of (time, duration, note) triples. Times and durations are 10 ms ticks;
/// note = instrument × 128 + pitch, instrument 128 = drums, and `Vocab.maxNote` is the rest.
/// Events the model writes use the offsets below; "controls" (fixed notes it writes around) use
/// the anticipated offsets.
enum Vocab {
    static let timeOffset = 0
    static let durOffset = 10_000
    static let noteOffset = 11_000
    static let rest = 27_512
    static let controlOffset = 27_513          // = atimeOffset
    static let atimeOffset = 27_513
    static let adurOffset = 37_513
    static let anoteOffset = 38_513
    static let separator = 55_025
    static let autoregress = 55_026
    static let anticipate = 55_027

    static let timeResolution = 100            // ticks per second
    static let delta = 5 * timeResolution      // anticipation interval
    static let maxTime = 100 * timeResolution
    static let maxDur = 10 * timeResolution
    static let maxPitch = 128
    static let maxInstrument = 129
    static let maxNote = maxPitch * maxInstrument   // also the rest note index
    static let drums = 128
}

/// One (time, duration, note) triple, as token values (offsets included).
struct Event: Equatable {
    var time: Int
    var dur: Int
    var note: Int

    var isControl: Bool { note >= Vocab.controlOffset }
    /// Time in ticks, without the event or control offset.
    var tick: Int { isControl ? time - Vocab.atimeOffset : time - Vocab.timeOffset }
    var durationTicks: Int { isControl ? dur - Vocab.adurOffset : dur - Vocab.durOffset }
    /// instrument × 128 + pitch (or `Vocab.maxNote` for a rest), without offsets.
    var noteIndex: Int { isControl ? note - Vocab.anoteOffset : note - Vocab.noteOffset }
    var instrument: Int { noteIndex / Vocab.maxPitch }
    var pitch: Int { noteIndex % Vocab.maxPitch }
    var isRest: Bool { note == Vocab.rest }

    static func note(tick: Int, durationTicks: Int, instrument: Int, pitch: Int) -> Event {
        Event(time: Vocab.timeOffset + tick, dur: Vocab.durOffset + durationTicks,
              note: Vocab.noteOffset + instrument * Vocab.maxPitch + pitch)
    }

    /// The same event as a control (fixed note) for the model to write around.
    var asControl: Event { Event(time: time + Vocab.controlOffset, dur: dur + Vocab.controlOffset, note: note + Vocab.controlOffset) }
    var tokens: [Int] { [time, dur, note] }
}

/// The sequence operations the sampler needs, from `anticipation.ops`.
enum EventOps {
    static func flatten(_ events: [Event]) -> [Int] { events.flatMap(\.tokens) }

    /// Events whose time is within [start, end] ticks (`clip_duration` shortens notes ringing past end).
    static func clip(_ events: [Event], start: Int, end: Int, clipDuration: Bool = true) -> [Event] {
        events.compactMap { e in
            guard e.tick >= start, e.tick <= end else { return nil }
            var e = e
            if clipDuration, end < e.tick + e.durationTicks { e.dur -= e.tick + e.durationTicks - end }
            return e
        }
    }

    /// Stable sort by token time (events or controls, not mixed).
    static func sort(_ events: [Event]) -> [Event] {
        events.enumerated().sorted { ($0.element.time, $0.offset) < ($1.element.time, $1.offset) }.map(\.element)
    }

    static func split(_ events: [Event]) -> (events: [Event], controls: [Event]) {
        (events.filter { !$0.isControl }, events.filter(\.isControl))
    }

    /// Rests inserted so no gap between events is longer than `density` ticks, up to `endTime`.
    static func pad(_ events: [Event], endTime: Int? = nil, density: Int = Vocab.timeResolution) -> [Event] {
        let end = Vocab.timeOffset + (endTime ?? maxTime(events))
        var out: [Event] = []
        var previous = Vocab.timeOffset
        for e in events {
            precondition(!e.isControl, "pad before separating events and controls")
            while e.time > previous + density {
                out.append(Event(time: previous + density, dur: Vocab.durOffset, note: Vocab.rest))
                previous += density
            }
            out.append(e)
            previous = e.time
        }
        while end > previous + density {
            out.append(Event(time: previous + density, dur: Vocab.durOffset, note: Vocab.rest))
            previous += density
        }
        return out
    }

    static func unpad(_ events: [Event]) -> [Event] { events.filter { !$0.isRest } }

    /// Interleaves events with the controls due within `delta` of each; returns the controls not
    /// yet consumed (after the last event + delta).
    static func anticipate(_ events: [Event], controls: [Event], delta: Int = Vocab.delta) -> (tokens: [Event], pending: [Event]) {
        guard !controls.isEmpty else { return (events, controls) }
        var tokens: [Event] = []
        var remaining = controls[...]
        var eventTime = 0
        var controlTime = Double(remaining.first!.time - Vocab.atimeOffset)
        for e in events {
            while Double(eventTime) >= controlTime - Double(delta) {
                tokens.append(remaining.removeFirst())
                controlTime = remaining.first.map { Double($0.time - Vocab.atimeOffset) } ?? .infinity
            }
            eventTime = e.time - Vocab.timeOffset
            tokens.append(e)
        }
        return (tokens, Array(remaining))
    }

    /// Earliest tick (0 for none).
    static func minTime(_ events: [Event]) -> Int { events.lazy.filter { $0.note != Vocab.separator }.map(\.tick).min() ?? 0 }
    /// Latest tick (0 for none).
    static func maxTime(_ events: [Event]) -> Int { events.lazy.filter { $0.note != Vocab.separator }.map(\.tick).max() ?? 0 }
}

/// Which model instruments belong to each track, and the instrument a track's notes are written
/// as (training/tracks.py `ALL_FAMILY`, `OUT_PROGRAM`, `VELOCITY`).
extension TrackID {
    var modelInstruments: [Int] {
        switch self {
        case .piano: Array(0..<8)
        case .guitar: Array(24..<32)
        case .bass: Array(32..<40)
        case .drums: [Vocab.drums]
        case .keys: Array(48..<56) + Array(88..<96)
        case .lead: Array(56..<80)
        case .vibes: Array(8..<16)
        }
    }

    var outProgram: Int {
        switch self {
        case .piano: 0
        case .guitar: 24
        case .bass: 32
        case .drums: Vocab.drums
        case .keys: 48
        case .lead: 73
        case .vibes: 11
        }
    }

    /// The fixed loudness the model's notes get before the clean-up writes dynamics.
    var defaultVelocity: Int {
        switch self {
        case .piano: 72
        case .guitar: 70
        case .bass: 84
        case .drums: 88
        case .keys: 64
        case .lead: 76
        case .vibes: 70
        }
    }

    /// The track a model instrument belongs to, if any.
    static func forModelInstrument(_ instrument: Int) -> TrackID? {
        TrackID.allCases.first { $0.modelInstruments.contains(instrument) }
    }
}

/// Notes ⇄ events, as `json_to_midi` + `midi_to_events` do on the server, minus the MIDI file.
enum NoteEvents {
    /// One track's notes as events (sorted by time, then pitch).
    static func events(for notes: [Note], track: TrackID) -> [Event] {
        notes.sorted { ($0.start, $0.pitch) < ($1.start, $1.pitch) }.compactMap { n in
            guard (0..<Vocab.maxPitch).contains(n.pitch), n.start >= 0 else { return nil }
            let tick = Int((Double(Vocab.timeResolution) * n.start).rounded())
            let dur = min(Int((Double(Vocab.timeResolution) * max(n.duration, 0.01)).rounded()), Vocab.maxDur - 1)
            return .note(tick: tick, durationTicks: dur, instrument: track.outProgram, pitch: n.pitch)
        }
    }

    /// Every given track's notes as one time-sorted event list.
    static func events(for song: [TrackID: [Note]]) -> [Event] {
        EventOps.sort(TrackID.allCases.flatMap { id in song[id].map { events(for: $0, track: id) } ?? [] })
    }

    /// Events back to notes per track (rests and unknown instruments dropped).
    static func notes(from events: [Event]) -> [TrackID: [Note]] {
        var out: [TrackID: [Note]] = [:]
        for e in events where !e.isControl && !e.isRest {
            guard let track = TrackID.forModelInstrument(e.instrument) else { continue }
            out[track, default: []].append(Note(
                pitch: e.pitch, start: Double(e.tick) / Double(Vocab.timeResolution),
                duration: Double(max(e.durationTicks, 5)) / Double(Vocab.timeResolution),
                velocity: track.defaultVelocity))
        }
        for id in out.keys { out[id]!.sort { ($0.start, $0.pitch) < ($1.start, $1.pitch) } }
        return out
    }
}
