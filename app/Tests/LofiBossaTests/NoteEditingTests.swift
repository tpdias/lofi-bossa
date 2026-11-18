import XCTest
@testable import LofiBossa

final class NoteEditingTests: XCTestCase {
    private func note(_ start: Double, _ duration: Double = 0.5, pitch: Int = 60) -> Note {
        Note(pitch: pitch, start: start, duration: duration, velocity: 90)
    }
    private func starts(_ notes: [Note]) -> [Double] { notes.map(\.start) }

    // MARK: selecting

    func testSectionIsHalfOpen() {
        let notes = [note(1), note(2), note(3), note(4)]
        XCTAssertEqual(starts(NoteEditing.notes(notes, in: 2...4)), [2, 3], "a note starting at the end belongs to the next section")
    }

    // MARK: clearing

    func testRemovingClearsTheRangeAndKeepsTheRest() {
        let notes = [note(1), note(2.5), note(3.5), note(5)]
        XCTAssertEqual(starts(NoteEditing.removing(notes, range: 2...4)), [1, 5])
    }

    func testRemovingShortensANoteRingingIntoTheRange() {
        let result = NoteEditing.removing([note(1.8, 1.0)], range: 2...4)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].duration, 0.2, accuracy: 1e-9, "must stop where the cleared range begins")
    }

    func testRemovingDropsASliverLeftOverByTruncation() {
        XCTAssertTrue(NoteEditing.removing([note(1.995, 1.0)], range: 2...4).isEmpty)
    }

    func testNoteEndingExactlyAtTheRangeStartIsUntouched() {
        let result = NoteEditing.removing([note(1.5, 0.5)], range: 2...4)
        XCTAssertEqual(result.first?.duration, 0.5)
    }

    // MARK: copy

    func testCopyIsRelativeToTheSectionStartAndClipsLongNotes() {
        let clip = NoteEditing.copy([note(10.5, 0.5), note(11.5, 5.0), note(20)], range: 10...12)
        XCTAssertEqual(clip.length, 2)
        XCTAssertEqual(starts(clip.notes), [0.5, 1.5])
        XCTAssertEqual(clip.notes[1].duration, 0.5, accuracy: 1e-9, "a note running past the section is cut at its end")
    }

    func testCopyOfAnEmptySectionIsAClipOfSilence() {
        let clip = NoteEditing.copy([note(1)], range: 5...7)
        XCTAssertEqual(clip.length, 2)
        XCTAssertTrue(clip.notes.isEmpty)
    }

    // MARK: paste

    func testPasteOverwritesTheDestinationAndKeepsOutsideNotes() {
        let clip = SectionClip(length: 2, notes: [note(0.5, 0.5, pitch: 72)], source: nil)
        let existing = [note(1, 0.5, pitch: 40), note(4.5, 0.5, pitch: 41), note(5.5, 0.5, pitch: 42), note(9, 0.5, pitch: 43)]
        let result = NoteEditing.pasting(clip, into: existing, at: 4, songLength: 20)
        XCTAssertEqual(result.map(\.pitch), [40, 72, 43],
                       "41 (starts 4.5) and 42 (starts 5.5) are both inside the pasted stretch [4,6) and are replaced; 40 and 43 are outside and stay")
    }

    func testPastedNotesAreNewNotes() {
        let original = note(1)
        let clip = NoteEditing.copy([original], range: 0...2)
        let result = NoteEditing.pasting(clip, into: [original], at: 5, songLength: 20)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(Set(result.map(\.id)).count, 2, "ids must be unique")
    }

    func testPasteIsClampedAtTheEndOfTheSong() {
        let clip = SectionClip(length: 4, notes: [note(0.5), note(3.5, 2.0)], source: nil)
        let result = NoteEditing.pasting(clip, into: [], at: 8, songLength: 10)
        XCTAssertEqual(starts(result), [8.5], "the note at 11.5 would start after the song ends")
        let clipped = NoteEditing.pasting(SectionClip(length: 4, notes: [note(1.5, 2.0)], source: nil), into: [], at: 8, songLength: 10)
        XCTAssertEqual(clipped[0].duration, 0.5, accuracy: 1e-9, "and a note running past the end is cut at it")
    }

    func testPastingStartingPastTheEndDoesNothing() {
        let notes = [note(1)]
        XCTAssertEqual(NoteEditing.pasting(SectionClip(length: 2, notes: [note(0)], source: nil), into: notes, at: 30, songLength: 20), notes)
    }

    func testPasteShortensANoteRingingIntoTheDestination() {
        let clip = SectionClip(length: 1, notes: [], source: nil)
        let result = NoteEditing.pasting(clip, into: [note(3.5, 1.5)], at: 4, songLength: 20)
        XCTAssertEqual(result[0].duration, 0.5, accuracy: 1e-9)
    }

    // MARK: duplicate

    func testDuplicatePlacesACopyRightAfterAndKeepsTheOriginal() {
        let notes = [note(1, 0.5, pitch: 60), note(1.5, 0.5, pitch: 62)]
        let result = NoteEditing.duplicating(notes, range: 1...2, songLength: 20)
        XCTAssertEqual(starts(result), [1, 1.5, 2, 2.5])
        XCTAssertEqual(result.map(\.pitch), [60, 62, 60, 62])
    }

    // MARK: move

    func testMoveEmptiesTheOldPlaceAndFillsTheNew() {
        let notes = [note(1, 0.5, pitch: 60), note(1.5, 0.5, pitch: 62), note(9, 0.5, pitch: 70)]
        let moved = NoteEditing.moving(notes, range: 1...2, by: 4, songLength: 20)
        XCTAssertEqual(moved.range, 5...6)
        XCTAssertEqual(starts(moved.notes), [5, 5.5, 9])
        XCTAssertEqual(moved.notes.map(\.pitch), [60, 62, 70])
    }

    func testMoveOverwritesWhatWasAtTheDestination() {
        let notes = [note(1, 0.5, pitch: 60), note(5.2, 0.5, pitch: 99)]
        let moved = NoteEditing.moving(notes, range: 1...2, by: 4, songLength: 20)
        XCTAssertFalse(moved.notes.contains { $0.pitch == 99 })
    }

    func testMoveIsLimitedToStayInsideTheSong() {
        let notes = [note(1, 0.5)]
        let late = NoteEditing.moving(notes, range: 1...3, by: 100, songLength: 10)
        XCTAssertEqual(late.range, 8...10, "a 2 s section can start no later than song end minus its length")
        let early = NoteEditing.moving(notes, range: 1...3, by: -100, songLength: 10)
        XCTAssertEqual(early.range, 0...2)
        XCTAssertEqual(starts(early.notes), [0])
    }

    func testMovingByLessThanTheSectionLengthDoesNotLoseNotes() {
        let notes = [note(1, 0.5, pitch: 60), note(1.5, 0.5, pitch: 62)]
        let moved = NoteEditing.moving(notes, range: 1...2, by: 0.5, songLength: 20)
        XCTAssertEqual(moved.notes.map(\.pitch), [60, 62])
        XCTAssertEqual(starts(moved.notes), [1.5, 2.0])
    }
}
