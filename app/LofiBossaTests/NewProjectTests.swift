import AVFoundation
import XCTest
@testable import LofiBossa

/// The New Project flow's draft, and the background sound: saving, carrying across takes, and
/// the synthesized sounds themselves.
@MainActor
final class NewProjectTests: XCTestCase {
    private var folder: URL!
    private var store: ProjectStore!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("lfb-new-\(UUID().uuidString)")
        store = ProjectStore(root: folder)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: Draft

    func testTheDraftBecomesTheProject() {
        var draft = ProjectDraft()
        draft.name = "  Rainy afternoon "
        draft.style = .bossa
        draft.length = 45
        draft.busyness = 0.2
        draft.noteLength = 0.8
        draft.key = "D minor"
        draft.strictKey = true
        draft.tempo = 96
        draft.groove = 0.9
        draft.dynamics = 0.1
        draft.background = BackgroundSound(ambience: .rain, level: 0.3)
        draft.seed = 1234
        let p = store.create(from: draft)
        XCTAssertEqual(p.name, "Rainy afternoon")
        XCTAssertEqual(p.style, .bossa)
        XCTAssertEqual(p.lengthSeconds, 45)
        XCTAssertEqual(p.songBusyness, 0.2)
        XCTAssertEqual(p.songNoteLength, 0.8)
        XCTAssertEqual(p.key, "D minor")
        XCTAssertTrue(p.isStrictKey)
        XCTAssertEqual(p.tempo, 96)
        XCTAssertEqual(p.songGroove, 0.9)
        XCTAssertEqual(p.songDynamics, 0.1)
        XCTAssertEqual(p.startingBackground, BackgroundSound(ambience: .rain, level: 0.3))
        XCTAssertEqual(p.pinnedSeed, 1234)
        XCTAssertEqual(store.projects.first?.id, p.id, "saved, first in the library")
        XCTAssertFalse(p.hasGenerated, "nothing is written until Generate")
    }

    func testAnEmptyNameKeepsTheUntitledOneAndAutoStaysAuto() {
        let p = store.create(from: ProjectDraft())
        XCTAssertFalse(p.name.isEmpty)
        XCTAssertNil(p.key)
        XCTAssertNil(p.tempo)
        XCTAssertNil(p.pinnedSeed)
        XCTAssertNil(p.startingBackground)
    }

    func testAScenePresetFillsTheDraft() throws {
        let rainy = try XCTUnwrap(ScenePreset.all.first { $0.name == "Rainy study" })
        var draft = ProjectDraft()
        draft.apply(rainy)
        XCTAssertEqual(draft.style, rainy.style)
        XCTAssertEqual(draft.tempo, rainy.tempo)
        XCTAssertEqual(draft.key, rainy.key)
        XCTAssertEqual(draft.background.ambience, .rain)
    }

    func testTheSessionOpensTheNewProject() {
        let session = AppSession(store: store, generator: FakeGeneratorClient())
        session.newProject()
        XCTAssertTrue(session.isCreatingProject, "New Project shows the flow instead of making a project")
        XCTAssertTrue(store.projects.isEmpty)
        var draft = ProjectDraft()
        draft.style = .bossa
        session.createProject(from: draft, generate: false)
        XCTAssertFalse(session.isCreatingProject)
        XCTAssertEqual(session.activeModel?.project.style, .bossa)
        XCTAssertEqual(store.projects.count, 1)
        session.activeModel?.teardown()
    }

    // MARK: Background in the project

    func testMixEffectsSavedBeforeTheBackgroundStillDecode() throws {
        let old = #"{"warmth":0.2,"reverb":0.5,"vinyl":0.1}"#.data(using: .utf8)!
        let e = try JSONDecoder().decode(MixEffects.self, from: old)
        XCTAssertEqual(e.warmth, 0.2)
        XCTAssertEqual(e.background, BackgroundSound())
        var withSound = e
        withSound.background = BackgroundSound(ambience: .ocean, level: 0.7)
        let back = try JSONDecoder().decode(MixEffects.self, from: JSONEncoder().encode(withSound))
        XCTAssertEqual(back, withSound)
    }

    func testTheBackgroundGoesIntoTheFirstTakeAndCarriesOver() async {
        var draft = ProjectDraft()
        draft.length = 15
        draft.background = BackgroundSound(ambience: .forest, level: 0.6)
        let project = store.create(from: draft)
        let model = ProjectViewModel(project: project, store: store, generator: FakeGeneratorClient())
        defer { model.teardown() }
        XCTAssertEqual(model.currentEffects.background.ambience, .forest, "shown before the first take")

        model.generate()
        await waitForVersions(1, model)
        XCTAssertEqual(model.project.currentSnapshot?.effects.background, draft.background)

        model.setBackground(BackgroundSound(ambience: .wind, level: 0.4))
        model.resetEffectsToStyleDefault()
        XCTAssertEqual(model.project.currentSnapshot?.effects.background.ambience, .wind, "Reset leaves the background alone")
        XCTAssertTrue(model.effectsAreAtStyleDefault, "the background isn't one of the style's effects")

        model.setStyle(.bossa)   // a new style gets its own effects, but keeps the background
        model.generate()
        await waitForVersions(2, model)
        XCTAssertEqual(model.project.currentSnapshot?.effects.background.ambience, .wind)
    }

    private func waitForVersions(_ n: Int, _ model: ProjectViewModel) async {
        for _ in 0..<400 where model.project.versions.count < n || model.isGeneratorBusy {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(model.project.versions.count, n)
    }

    // MARK: The sounds

    func testEverySoundIsAudibleAndBounded() {
        for sound in Ambience.allCases where sound != .none {
            var l = BackgroundNoise.Voice(seed: 1), r = BackgroundNoise.Voice(seed: 2), c = BackgroundNoise.Voice(seed: 3)
            var scene = BackgroundNoise.Scene()
            var sum: Float = 0, peak: Float = 0, finite = true
            let frames = Int(BackgroundNoise.sampleRate) * 12   // long enough for waves and birds
            for _ in 0..<frames {
                let (a, b) = BackgroundNoise.render(sound, &l, &r, &scene, &c)
                finite = finite && a.isFinite && b.isFinite
                sum += a * a
                peak = max(peak, abs(a), abs(b))
            }
            let rms = (sum / Float(frames)).squareRoot()
            XCTAssertTrue(finite, "\(sound)")
            XCTAssertGreaterThan(rms, 0.005, "\(sound) is too quiet")
            XCTAssertLessThan(peak, 0.9, "\(sound) clips")
        }
    }

    func testTheBackgroundIsInTheExportedMix() throws {
        let audio = AudioEngine()
        var effects = MixEffects(warmth: 0, reverb: 0, vinyl: 0)
        effects.background = BackgroundSound(ambience: .rain, level: 1)
        audio.apply(effects)
        audio.load(SongSnapshot.empty(style: .lofi, length: 3))   // no notes: only the rain can sound
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lfb-rain-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try audio.export(to: url, format: .wav, range: 0...3, tail: 0)
        let file = try AVAudioFile(forReading: url)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        let data = buffer.floatChannelData![0]
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) { sum += data[i] * data[i] }
        XCTAssertGreaterThan((sum / Float(max(buffer.frameLength, 1))).squareRoot(), 0.005)
    }
}
