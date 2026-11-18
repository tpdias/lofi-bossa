import Foundation

/// A copied stretch of one track: its length and the notes inside it, with start times
/// relative to the start of the stretch, so it can be pasted anywhere.
struct SectionClip: Equatable {
    var length: Double
    var notes: [Note]
    /// The track it came from (a clip may be pasted onto a different track).
    var source: TrackID?
}

/// Section operations on a track's notes: pure functions, no UI and no audio, so the rules
/// are in one place and testable.
///
/// Rules, all following from "a section is a stretch of time on one track":
/// - A range is half-open, `[lowerBound, upperBound)`. A note belongs to the section it
///   *starts* in, so a note starting exactly at the end belongs to the next section.
/// - Clearing a range (cut, delete, or being pasted over) also shortens a note that starts
///   before the range and rings into it, so the cleared stretch really is silent.
/// - Pasting overwrites the destination: whatever was in that stretch is replaced, not mixed.
/// - Nothing may start at or after the end of the song, and notes are clipped at it.
/// - Pasted notes are new notes (fresh ids) so selections and edits never see two notes
///   sharing an id.
enum NoteEditing {
    /// Smallest note that survives being truncated; anything shorter is dropped.
    static let minimumDuration = 0.02

    static func notes(_ notes: [Note], in range: ClosedRange<Double>) -> [Note] {
        notes.filter { $0.start >= range.lowerBound && $0.start < range.upperBound }
    }

    /// The notes with the range cleared (see the rules above).
    static func removing(_ notes: [Note], range: ClosedRange<Double>) -> [Note] {
        var result: [Note] = []
        for var note in notes {
            if note.start >= range.lowerBound && note.start < range.upperBound { continue }
            if note.start < range.lowerBound, note.start + note.duration > range.lowerBound {
                note.duration = range.lowerBound - note.start
                if note.duration < minimumDuration { continue }
            }
            result.append(note)
        }
        return result
    }

    static func copy(_ notes: [Note], range: ClosedRange<Double>) -> SectionClip {
        let length = range.upperBound - range.lowerBound
        let inside: [Note] = Self.notes(notes, in: range).map { note in
            var n = note
            n.start = note.start - range.lowerBound
            n.duration = min(note.duration, length - n.start)   // stay inside the section
            return n
        }
        return SectionClip(length: length, notes: inside.filter { $0.duration >= minimumDuration }, source: nil)
    }

    /// Replaces the stretch `[at, at + clip.length)` with the clip's notes.
    static func pasting(_ clip: SectionClip, into notes: [Note], at: Double, songLength: Double) -> [Note] {
        let start = max(at, 0)
        guard start < songLength else { return notes }
        let end = min(start + clip.length, songLength)
        var result = removing(notes, range: start...end)
        for var note in clip.notes {
            note.id = UUID()
            note.start += start
            guard note.start < end else { continue }
            note.duration = min(note.duration, end - note.start)
            if note.duration >= minimumDuration { result.append(note) }
        }
        return sorted(result)
    }

    /// A copy of the section placed right after it.
    static func duplicating(_ notes: [Note], range: ClosedRange<Double>, songLength: Double) -> [Note] {
        pasting(copy(notes, range: range), into: notes, at: range.upperBound, songLength: songLength)
    }

    /// Moves the section by `offset` seconds, overwriting what's at the destination and leaving
    /// the old place empty. The move is limited so the section stays inside the song; the range
    /// it ended up in is returned so a selection can follow it.
    static func moving(_ notes: [Note], range: ClosedRange<Double>, by offset: Double, songLength: Double)
        -> (notes: [Note], range: ClosedRange<Double>) {
        let length = range.upperBound - range.lowerBound
        let newStart = min(max(range.lowerBound + offset, 0), max(songLength - length, 0))
        let clip = copy(notes, range: range)
        let vacated = removing(notes, range: range)
        let moved = pasting(clip, into: vacated, at: newStart, songLength: songLength)
        return (moved, newStart...(newStart + length))
    }

    static func sorted(_ notes: [Note]) -> [Note] {
        notes.sorted { ($0.start, $0.pitch) < ($1.start, $1.pitch) }
    }
}
