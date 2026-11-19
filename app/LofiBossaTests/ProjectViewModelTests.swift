import AVFoundation
import XCTest
@testable import LofiBossa

/// The view model with a real store (in a temporary folder) and the instant fake generator.
/// These cover the flows that kept breaking by hand: generating, versions, switching to a past
/// version, undo/redo, section edits, rewrites and piano-roll sessions.
@MainActor
final class ProjectViewModelTests: XCTestCase {
    private var folder: URL!
    private var store: ProjectStore!
    private var generator: FakeGeneratorClient!
    private var model: ProjectViewModel!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("lfb-tests-\(UUID().uuidString)")
        store = ProjectStore(root: folder)
        generator = FakeGeneratorClient()
        var project = store.create(style: .bossa)
        project.lengthSeconds = 20
        store.update(project)
        model = ProjectViewModel(project: project, store: store, generator: generator)
    }

    override func tearDown() async throws {
        model.teardown()
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: helpers

    private func waitUntilIdle(file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<400 where model.isGeneratorBusy || model.project.versions.isEmpty && model.phase == .idle {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(model.isGeneratorBusy, "still busy", file: file, line: line)
    }

    private func generate(seed: UInt32? = nil) async {
        if let seed { model.pinSeed(seed) }
        model.generate()
        await waitUntilIdle()
    }

    private var versions: [Version] { model.project.versions }
    private func notes(_ track: TrackID) -> [Note] { model.project.currentSnapshot?.track(track).notes ?? [] }

    // MARK: generating

    func testGenerateCreatesVersionOneWithAllFourTracks() async {
        await generate(seed: 1)
        XCTAssertEqual(versions.count, 1)
        XCTAssertEqual(versions[0].number, 1)
        XCTAssertEqual(model.project.currentSnapshot?.trackIDs, TrackID.core)
        for id in TrackID.core { XCTAssertFalse(notes(id).isEmpty, "\(id) is empty") }
        XCTAssertEqual(model.phase, .idle)
    }

    func testGeneratingAgainAddsAVersionAndMovesCurrent() async {
        await generate(seed: 1)
        await generate(seed: 2)
        XCTAssertEqual(versions.map(\.number), [1, 2])
        XCTAssertEqual(model.project.currentVersionID, versions[1].id)
    }

    func testGenerationIsSavedToDisk() async throws {
        await generate(seed: 1)
        store.flushPendingSaves()
        let reloaded = ProjectStore(root: folder)
        reloaded.load()
        XCTAssertEqual(reloaded.projects.first { $0.id == model.project.id }?.versions.count, 1)
    }

    func testFailedGenerationShowsAnErrorAndKeepsTheOldSong() async {
        await generate(seed: 1)
        generator.failure = FakeGeneratorClient.Failure()
        model.generate()
        await waitUntilIdle()
        guard case .failed = model.phase else { return XCTFail("expected a failure, got \(model.phase)") }
        XCTAssertEqual(versions.count, 1)
        model.dismissError()
        XCTAssertEqual(model.phase, .idle)
    }

    func testGenerateIgnoredWhileBusy() async {
        generator.delay = .milliseconds(200)
        model.generate()
        model.generate()
        await waitUntilIdle()
        XCTAssertEqual(generator.generateCalls, 1)
    }

    // MARK: versions

    func testUndoAndRedoMoveTheVersionPointer() async {
        await generate(seed: 1)
        await generate(seed: 2)
        XCTAssertTrue(model.canUndo); XCTAssertFalse(model.canRedo)
        model.undo()
        XCTAssertEqual(model.project.currentVersionID, versions[0].id)
        XCTAssertTrue(model.canRedo)
        model.redo()
        XCTAssertEqual(model.project.currentVersionID, versions[1].id)
    }

    func testListeningToAPastVersionShowsItsNotesWithoutChangingCurrent() async {
        await generate(seed: 1)
        await generate(seed: 2)
        let first = versions[0]
        model.listen(to: first)
        XCTAssertTrue(model.isListeningToPastVersion)
        XCTAssertEqual(model.displayedSnapshot?.seed, 1)
        XCTAssertEqual(model.project.currentVersionID, versions[1].id)
        model.backToCurrentVersion()
        XCTAssertEqual(model.displayedSnapshot?.seed, 2)
    }

    func testRestoringAPastVersionAddsANewVersionOnTop() async {
        await generate(seed: 1)
        await generate(seed: 2)
        model.listen(to: versions[0])
        model.restoreListeningVersion()
        XCTAssertEqual(versions.count, 3)
        XCTAssertEqual(model.project.currentSnapshot?.seed, 1)
        XCTAssertFalse(model.isListeningToPastVersion)
        if case .restore(let from) = versions[2].kind { XCTAssertEqual(from, 1) } else { XCTFail("not a restore") }
    }

    // MARK: mix

    func testMixChangesDoNotCreateVersions() async {
        await generate(seed: 1)
        model.setMuted(true, for: .bass)
        model.setVolume(0.3, for: .piano)
        model.setSoloed(true, for: .drums)
        var fx = TrackEffects(); fx.grit = 0.5
        model.setTrackEffects(fx, for: .guitar)
        XCTAssertEqual(versions.count, 1)
        XCTAssertFalse(model.isAudible(.bass))
        XCTAssertFalse(model.isAudible(.piano), "solo on drums silences the rest")
        XCTAssertTrue(model.isAudible(.drums))
        XCTAssertEqual(model.project.currentSnapshot?.track(.guitar).effects.grit, 0.5)
    }

    // MARK: sections

    func testCutRemovesTheNotesAndPasteBringsThemBack() async {
        await generate(seed: 1)
        let before = notes(.guitar)
        model.selectSection(track: .guitar, from: 4, to: 8)
        model.cutSection()
        XCTAssertEqual(versions.count, 2)
        XCTAssertTrue(NoteEditing.notes(notes(.guitar), in: 4...8).isEmpty)
        XCTAssertEqual(notes(.guitar).count, NoteEditing.notes(before, in: 0...4).count + NoteEditing.notes(before, in: 8...20).count)
        model.seek(to: 4)
        model.pasteSection(onto: .guitar)
        XCTAssertEqual(versions.count, 3)
        XCTAssertEqual(notes(.guitar).map(\.start), before.map(\.start))
        XCTAssertEqual(notes(.guitar).map(\.pitch), before.map(\.pitch))
    }

    func testSectionEditsLeaveOtherTracksAlone() async {
        await generate(seed: 1)
        let piano = notes(.piano)
        model.selectSection(track: .guitar, from: 2, to: 6)
        model.deleteSection()
        XCTAssertEqual(notes(.piano), piano)
    }

    func testDuplicateAndMoveSelectTheirResult() async {
        await generate(seed: 1)
        model.selectSection(track: .bass, from: 0, to: 4)
        model.duplicateSection()
        XCTAssertEqual(model.sectionSelection?.range, 4...8)
        model.moveSection(by: 8)
        XCTAssertEqual(model.sectionSelection?.range, 12...16)
        XCTAssertEqual(versions.count, 3)
    }

    func testSectionEditsAreOffWhileListeningToAPastVersion() async {
        await generate(seed: 1)
        await generate(seed: 2)
        model.selectSection(track: .guitar, from: 0, to: 4)
        model.listen(to: versions[0])
        model.deleteSection()
        XCTAssertEqual(versions.count, 2)
    }

    func testSectionRewriteOnlyChangesTheRange() async {
        await generate(seed: 1)
        let before = notes(.guitar)
        model.selectSection(track: .guitar, from: 8, to: 12)
        model.rewriteSection()
        await waitUntilIdle()
        XCTAssertEqual(versions.count, 2)
        guard case .rewriteSection(let track, let start, let end) = versions[1].kind else { return XCTFail("wrong kind") }
        XCTAssertEqual(track, .guitar); XCTAssertEqual(start, 8); XCTAssertEqual(end, 12)
        let outside: (Note) -> Bool = { $0.start < 8 || $0.start >= 12 }
        XCTAssertEqual(notes(.guitar).filter(outside).map(\.start), before.filter(outside).map(\.start))
        XCTAssertNotEqual(notes(.guitar).filter { !outside($0) }.map(\.pitch), before.filter { !outside($0) }.map(\.pitch))
        XCTAssertEqual(model.sectionSelection?.range, 8...12, "selection is kept to try again")
    }

    func testWholeTrackRewriteMakesARewriteVersion() async {
        await generate(seed: 1)
        model.rewrite(.bass)
        await waitUntilIdle()
        if case .rewrite(.bass) = versions[1].kind {} else { XCTFail("expected rewrite(bass)") }
        XCTAssertEqual(versions[1].changedTracks, [.bass])
    }

    // MARK: piano roll

    func testNoEditMakesNoVersionAndOneEditSessionMakesExactlyOne() async {
        await generate(seed: 1)
        model.openEditor(for: .piano)
        model.closeEditor()
        XCTAssertEqual(versions.count, 1)

        model.openEditor(for: .piano)
        var edited = notes(.piano)
        edited[0].pitch += 2
        model.updateEditingNotes(edited, for: .piano)
        edited[1].pitch += 2
        model.updateEditingNotes(edited, for: .piano)
        model.closeEditor()
        XCTAssertEqual(versions.count, 2)
        if case .noteEdit(.piano) = versions[1].kind {} else { XCTFail("expected noteEdit(piano)") }
    }

    // MARK: transport

    func testPlayAndPauseTogglesAndSeekClamps() async {
        await generate(seed: 1)
        model.play()
        XCTAssertTrue(model.isPlaying)
        model.pause()
        XCTAssertFalse(model.isPlaying)
        model.seek(to: 999)
        XCTAssertLessThanOrEqual(model.position, 20)
    }

    // MARK: menu commands

    func testUndoAndRedoMenuTitlesNameTheVersion() async {
        XCTAssertNil(model.undoTitle)
        await generate(seed: 7)
        XCTAssertNil(model.undoTitle, "version 1 has nothing before it")
        model.selectSection(track: .guitar, from: 2, to: 6)
        model.deleteSection()
        XCTAssertEqual(model.undoTitle, versions[1].kind.title)
        XCTAssertTrue(model.undoTitle?.contains("guitar") == true)
        XCTAssertNil(model.redoTitle)
        model.undo()
        XCTAssertEqual(model.redoTitle, versions[1].kind.title)
        XCTAssertNil(model.undoTitle)
    }

    func testTrackCommandsActOnTheSelectedTrack() async {
        await generate(seed: 1)
        model.toggleMuteOfSelectedTrack()                       // nothing selected: nothing happens
        XCTAssertTrue(TrackID.allCases.allSatisfy { model.isAudible($0) })
        model.selectTrack(.bass)
        model.toggleMuteOfSelectedTrack()
        XCTAssertFalse(model.isAudible(.bass))
        model.toggleMuteOfSelectedTrack()
        XCTAssertTrue(model.isAudible(.bass))
        model.toggleSoloOfSelectedTrack()
        XCTAssertTrue(model.isAudible(.bass)); XCTAssertFalse(model.isAudible(.piano))
        XCTAssertEqual(versions.count, 1, "mix changes are not versions")
    }

    func testRewriteAndOpenEditorForTheSelectedTrack() async {
        await generate(seed: 1)
        model.selectTrack(.piano)
        model.rewriteSelectedTrack()
        await waitUntilIdle()
        if case .rewrite(.piano) = versions[1].kind {} else { XCTFail("expected rewrite(piano)") }
        model.openEditorForSelectedTrack()
        XCTAssertEqual(model.editingTrack, .piano)
        model.closeEditor()
    }

    func testNudgingThePlayheadStaysInsideTheSong() async {
        await generate(seed: 1)
        model.nudgePlayhead(by: -5)
        XCTAssertEqual(model.position, 0, accuracy: 0.01)
        model.nudgePlayhead(by: 5)
        XCTAssertEqual(model.position, 5, accuracy: 0.1)
        model.nudgePlayhead(by: 100)
        XCTAssertEqual(model.position, 20, accuracy: 0.1)
    }

    func testEveryShortcutListedHasText() {
        for group in KeyboardShortcuts.groups {
            XCTAssertFalse(group.items.isEmpty)
            for item in group.items { XCTAssertFalse(item.keys.isEmpty || item.what.isEmpty) }
        }
    }

    // MARK: loop

    func testClickingInsideTheLoopRemovesItAndMovesThePlayhead() async {
        await generate(seed: 1)
        model.setLoopRange(4...8)
        model.tapRuler(at: 6)
        XCTAssertNil(model.loopRange)
        XCTAssertFalse(model.isLoopEnabled)
        XCTAssertEqual(model.position, 6, accuracy: 0.1)
    }

    func testClickingOutsideTheLoopKeepsItAndMovesThePlayhead() async {
        await generate(seed: 1)
        model.setLoopRange(4...8)
        model.tapRuler(at: 12)
        XCTAssertEqual(model.loopRange, 4...8)
        XCTAssertTrue(model.isLoopEnabled)
        XCTAssertEqual(model.position, 12, accuracy: 0.1)
    }

    // MARK: audio, in the real flows (each of these was a "no sound" bug once)

    /// Loudest sample that reaches the output while `body` runs and for a moment after.
    private func peak(during seconds: Double = 1.5, _ body: () -> Void) async -> Float {
        var peak: Float = 0
        model.audioOutput.installTap(onBus: 0, bufferSize: 2048, format: nil) { buffer, _ in
            guard let data = buffer.floatChannelData?[0] else { return }
            for i in 0..<Int(buffer.frameLength) { peak = max(peak, abs(data[i])) }
        }
        body()
        try? await Task.sleep(for: .seconds(seconds))
        model.audioOutput.removeTap(onBus: 0)
        return peak
    }

    func testPlayingTheCurrentVersionIsAudible() async {
        await generate(seed: 1)
        let level = await peak { model.play() }
        model.pause()
        XCTAssertGreaterThan(level, 0.01)
    }

    func testPlayingAfterListeningToAPastVersionIsAudible() async {
        await generate(seed: 1)
        await generate(seed: 2)
        model.play()
        try? await Task.sleep(for: .milliseconds(400))
        let level = await peak(during: 2.0) {
            model.listen(to: versions[0])      // switching version while playing
        }
        XCTAssertGreaterThan(level, 0.01, "silent after switching to a past version")
        model.pause()
        let again = await peak { model.seek(to: 0); model.play() }   // and pressing play again
        model.pause()
        XCTAssertGreaterThan(again, 0.01, "silent when pressing play again")
    }

    func testUndoWhilePlayingIsAudible() async {
        await generate(seed: 1)
        await generate(seed: 2)
        model.play()
        try? await Task.sleep(for: .milliseconds(400))
        let level = await peak(during: 2.0) { model.undo() }
        model.pause()
        XCTAssertGreaterThan(level, 0.01)
    }

    func testEditingANoteWhilePlayingIsAudible() async {
        await generate(seed: 1)
        model.openEditor(for: .piano)
        model.play()
        try? await Task.sleep(for: .milliseconds(400))
        var edited = notes(.piano)
        edited[0].pitch += 1
        let level = await peak(during: 2.0) { model.updateEditingNotes(edited, for: .piano) }
        model.pause()
        model.closeEditor()
        XCTAssertGreaterThan(level, 0.01)
    }

    // MARK: adding and removing tracks

    func testAddingATrackMakesTwoVersionsAndTheModelWritesIt() async {
        await generate(seed: 1)
        model.addTrack(.lead)
        await waitUntilIdle()
        XCTAssertEqual(versions.map(\.kind.title), [versions[0].kind.title, "Added Lead", "Rewrote lead"])
        XCTAssertEqual(model.project.currentSnapshot?.trackIDs, TrackID.core + [.lead])
        XCTAssertFalse(notes(.lead).isEmpty)
        XCTAssertEqual(generator.rewriteCalls.last?.track, .lead)
        XCTAssertFalse(model.addableTracks.contains(.lead))
    }

    func testRemovingATrackIsAVersionAndUndoBringsItBack() async {
        await generate(seed: 1)
        model.addTrack(.vibes)
        await waitUntilIdle()
        let before = versions.count
        model.removeTrack(.vibes)
        XCTAssertEqual(versions.count, before + 1)
        XCTAssertEqual(model.project.currentSnapshot?.trackIDs, TrackID.core)
        model.undo()
        XCTAssertTrue(model.project.currentSnapshot?.hasTrack(.vibes) ?? false)
        XCTAssertFalse(notes(.vibes).isEmpty)
    }

    func testCoreTracksCannotBeRemoved() async {
        await generate(seed: 1)
        model.removeTrack(.piano)
        XCTAssertEqual(versions.count, 1)
        XCTAssertTrue(model.project.currentSnapshot?.hasTrack(.piano) ?? false)
    }

    func testGeneratingAgainKeepsTheAddedTracks() async {
        await generate(seed: 1)
        model.addTrack(.keys)
        await waitUntilIdle()
        await generate(seed: 2)
        XCTAssertEqual(model.project.currentSnapshot?.trackIDs, TrackID.core + [.keys])
        XCTAssertFalse(notes(.keys).isEmpty)
    }

    func testAddedTracksPlayThroughTheAudioEngine() async {
        await generate(seed: 1)
        model.addTrack(.lead)
        await waitUntilIdle()
        model.play()
        XCTAssertTrue(model.isPlaying)
        model.pause()
    }
}
