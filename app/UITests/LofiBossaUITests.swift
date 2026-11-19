import XCTest

/// Drives the real app with `--fake-generator` (instant, deterministic songs: no Python
/// server) and a throwaway data folder, so these never touch the real library.
final class LofiBossaUITests: XCTestCase {
    private var app: XCUIApplication!
    private var dataDir: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        dataDir = FileManager.default.temporaryDirectory.appendingPathComponent("lfb-ui-\(UUID().uuidString)")
        app = XCUIApplication()
        app.launchArguments = ["--fake-generator", "--data-dir", dataDir.path, "--window", "1300x800"]
        app.launch()
    }

    override func tearDownWithError() throws {
        app.terminate()
        try? FileManager.default.removeItem(at: dataDir)
    }

    // MARK: helpers

    private var subtitle: XCUIElement { app.staticTexts["project-subtitle"] }

    /// New project, then Generate; returns once version 1 exists.
    private func makeProjectWithSong() {
        app.typeKey("n", modifierFlags: .command)   // File ▸ New Project
        let generate = app.buttons["generate"]
        XCTAssertTrue(generate.waitForExistence(timeout: 10), "project stage did not open")
        XCTAssertTrue(generate.isEnabled)
        generate.click()
        XCTAssertTrue(subtitle.waitForLabel(containing: "Version 1", timeout: 10), "no version after generating")
    }

    private func trackRow(_ name: String) -> XCUIElement { app.groups["\(name) track"].firstMatch }

    // MARK: tests

    func testGenerateFillsFourTracksAndMakesVersionOne() {
        makeProjectWithSong()
        for name in ["Piano", "Guitar", "Bass", "Drums"] {
            XCTAssertTrue(trackRow(name).waitForExistence(timeout: 5), "\(name) row is missing")
        }
        XCTAssertTrue(subtitle.label.contains("Saved"))
    }

    func testPlayAndPauseButton() {
        makeProjectWithSong()
        let play = app.buttons["play"]
        XCTAssertEqual(play.label, "Play")
        play.click()
        XCTAssertEqual(play.label, "Pause")
        play.click()
        XCTAssertEqual(play.label, "Play")
    }

    func testListeningToAnOlderVersionAndGoingBack() {
        makeProjectWithSong()
        app.buttons["generate"].click()
        XCTAssertTrue(subtitle.waitForLabel(containing: "Version 2", timeout: 10))
        app.radioButtons["Versions"].firstMatch.click()
        app.buttons["version-play-1"].click()
        let back = app.buttons["Back to Current"]
        XCTAssertTrue(back.waitForExistence(timeout: 5), "no listening banner")
        back.click()
        XCTAssertFalse(back.exists)
    }

    func testPianoRollOpensZoomsAndCloses() {
        makeProjectWithSong()
        trackRow("Guitar").doubleClick()
        let done = app.buttons["roll-done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5), "piano roll did not open")
        let zoom = app.sliders["roll-zoom"]
        XCTAssertTrue(zoom.exists)
        zoom.adjust(toNormalizedSliderPosition: 0.6)
        XCTAssertGreaterThan((zoom.normalizedSliderPosition), 0.3)
        done.click()
        XCTAssertFalse(done.exists)
    }

    func testSelectingASectionAndDeletingItMakesAVersion() {
        makeProjectWithSong()
        let row = trackRow("Bass")
        let from = row.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.5))
        let to = row.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5))
        from.click(forDuration: 0.1, thenDragTo: to)
        let delete = app.buttons["Delete"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5), "no section pill after dragging on the lane")
        delete.click()
        XCTAssertTrue(subtitle.waitForLabel(containing: "Version 2", timeout: 5))
    }
}

private extension XCUIElement {
    /// Waits for the element's label to contain `text`.
    func waitForLabel(containing text: String, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "label CONTAINS %@", text)
        return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: self)], timeout: timeout) == .completed
    }
}
