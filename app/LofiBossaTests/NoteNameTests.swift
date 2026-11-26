import XCTest
@testable import LofiBossa

final class NoteNameTests: XCTestCase {
    private func name(_ pitch: Int, _ id: String) -> String { NoteName.localized(pitch: pitch, locale: Locale(identifier: id)) }

    func testLettersInEnglishAndChinese() {
        XCTAssertEqual(name(60, "en"), "C4")
        XCTAssertEqual(name(70, "en"), "A#4")
        XCTAssertEqual(name(71, "zh-Hans"), "B4")
    }

    func testSolfegeInRomanceLanguages() {
        for id in ["it", "fr", "es", "pt-BR"] {
            XCTAssertEqual(name(60, id), "Do4", id)
            XCTAssertEqual(name(64, id), "Mi4", id)
            XCTAssertEqual(name(69, id), "La4", id)
            XCTAssertEqual(name(71, id), "Si4", id)
        }
    }

    func testGermanUsesHForB() {
        XCTAssertEqual(name(71, "de"), "H4")
        XCTAssertEqual(name(70, "de"), "B4")
        XCTAssertEqual(name(60, "de"), "C4")
    }

    func testOctaveNumberingFollowsMIDI() {
        XCTAssertEqual(name(21, "en"), "A0")
        XCTAssertEqual(name(108, "en"), "C8")
    }

    func testKeysAreNamedInTheReadersLanguage() {
        func key(_ k: String, _ id: String) -> String { MusicKey.display(k, locale: Locale(identifier: id)) }
        XCTAssertEqual(key("A minor", "en"), "A minor")
        XCTAssertEqual(key("A minor", "fr"), "La mineur")
        XCTAssertEqual(key("B major", "de"), "H-Dur")
        XCTAssertEqual(key("A# minor", "de"), "B-Moll")
        XCTAssertEqual(key("C major", "es"), "Do mayor")
        XCTAssertEqual(key("D major", "pt-BR"), "Re maior")
        XCTAssertEqual(key("E minor", "it"), "Mi minore")
        XCTAssertEqual(key("G minor", "zh-Hans"), "G小调")
    }

    func testEveryStoredKeyHasADisplayName() {
        for k in MusicKey.names { XCTAssertFalse(MusicKey.display(k, locale: Locale(identifier: "fr")).isEmpty) }
    }
}
