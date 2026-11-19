import AVFoundation
import AppKit
import Observation
import UniformTypeIdentifiers

/// A stretch of time on one track, picked by dragging on its lane.
struct SectionSelection: Equatable {
    var track: TrackID
    var range: ClosedRange<Double>
}

enum InspectorTab: String, CaseIterable, Identifiable {
    case sound = "Sound", versions = "Versions"
    var id: String { rawValue }
}

/// One project's live state: the song, playback, generation, versions and the piano-roll
/// editing session. One instance per open project; owns its own AudioEngine.
///
/// Mix changes (mute, solo, volume, instrument, effects) mutate the current version's
/// snapshot in place and are not themselves versioned — only Generate, Rewrite, a
/// note-editing session, and Restore create a new version (see design handoff §3.9).
@MainActor @Observable
final class ProjectViewModel {
    private(set) var project: Project
    let generator: any GeneratorClient
    private let audio = AudioEngine()
    /// The mixed output, for tests that listen to what the app plays.
    var audioOutput: AVAudioNode { audio.outputNode }
    private let store: ProjectStore

    // Generation
    private(set) var phase: GenerationPhase = .idle
    var status: GeneratorStatus { generator.currentStatus }
    private var generateTask: Task<Void, Never>?
    private var rewriteAttempts: [TrackID: Int] = [:]

    // Transport
    private(set) var isPlaying = false
    private(set) var position: Double = 0
    var loopRange: ClosedRange<Double>?
    var isLoopEnabled = false
    private var ticker: Timer?

    // Selection / editing
    var selectedTrack: TrackID?
    var isPianoRollOpen = false
    var editingTrack: TrackID?
    private var editingSnapshotBeforeSession: SongSnapshot?
    var selectedNoteIDs: Set<Note.ID> = []

    // Section editing (cut / copy / paste of a stretch of one track)
    var sectionSelection: SectionSelection?
    private(set) var clipboard: SectionClip?
    /// Selections and pastes land on this grid, in seconds.
    static let sectionGrid = 0.25

    // Inspector
    var inspectorTab: InspectorTab = .sound
    /// Set while "listening" to a past version from the Versions tab, without restoring it.
    var listeningVersionID: Version.ID?

    init(project: Project, store: ProjectStore, generator: any GeneratorClient) {
        self.project = project
        self.store = store
        self.generator = generator
        if let snapshot = project.currentSnapshot { loadIntoAudio(snapshot) }
    }

    /// Called by the owner (RootView) before dropping its reference, since a class that is
    /// both `@MainActor` and `@Observable` can't touch its own main-actor state from a plain
    /// `deinit` (deinit runs nonisolated). Stops the playback timer so it does not keep firing
    /// after the view model that scheduled it is gone.
    func teardown() {
        pause()
        generateTask?.cancel()
    }

    // MARK: Derived state

    var displayedSnapshot: SongSnapshot? {
        if let id = listeningVersionID { return project.versions.first { $0.id == id }?.snapshot }
        return project.currentSnapshot
    }
    var duration: Double { displayedSnapshot?.lengthSeconds ?? project.lengthSeconds }
    var isListeningToPastVersion: Bool { listeningVersionID != nil }
    var listeningVersion: Version? { project.versions.first { $0.id == listeningVersionID } }

    private var currentIndex: Int? { project.versions.firstIndex { $0.id == project.currentVersionID } }
    var canUndo: Bool { (currentIndex ?? 0) > 0 }
    var canRedo: Bool { (currentIndex ?? -1) < project.versions.count - 1 }
    var isGeneratorBusy: Bool { if case .idle = phase { false } else { if case .failed = phase { false } else { true } } }
    var isGenerating: Bool { if case .generating = phase { true } else { false } }
    var rewritingTrack: TrackID? { if case .rewriting(let t, _) = phase { t } else { nil } }

    /// What the seed field shows: the pinned value, the last used seed, or "Random".
    var displaySeed: UInt32? { project.pinnedSeed ?? displayedSnapshot?.seed }
    var isDiceOn: Bool { project.pinnedSeed == nil }

    /// The user's choice, unless the current style has no fine-tuned checkpoint, in which
    /// case the pretrained model is used regardless — asking the server for a checkpoint
    /// that doesn't exist is a 422, not a style we have any business requesting silently.
    var hasFinetunedForStyle: Bool { generator.finetunedStyles.contains(project.style) }
    var activeModel: NoteModel { hasFinetunedForStyle ? project.model : .pretrained }

    func isAudible(_ id: TrackID) -> Bool {
        guard let track = displayedSnapshot?.track(id) else { return true }
        let anySolo = displayedSnapshot?.tracks.contains { $0.isSoloed } ?? false
        return anySolo ? track.isSoloed : !track.isMuted
    }
    func isDimmedBySolo(_ id: TrackID) -> Bool {
        let anySolo = displayedSnapshot?.tracks.contains { $0.isSoloed } ?? false
        return anySolo && !(displayedSnapshot?.track(id).isSoloed ?? false)
    }

    // MARK: Generation

    func generate() {
        guard !isGeneratorBusy else { return }
        let seed = project.pinnedSeed ?? UInt32.random(in: 0...UInt32.max)
        phase = .generating(startedAt: .now, seed: seed)
        generateTask = Task {
            do {
                for try await event in generator.generate(
                    style: project.style, model: activeModel, length: project.lengthSeconds,
                    seed: project.pinnedSeed
                ) {
                    guard case .finished(var snapshot) = event else { continue }
                    snapshot = carryOverMixIfSameStyle(onto: snapshot)
                    appendVersion(kind: .newTake(seed: snapshot.seed), changed: Set(TrackID.allCases), snapshot: snapshot)
                }
                phase = .idle
            } catch is CancellationError {
                phase = .idle
            } catch {
                phase = .failed(message: "That take didn't finish.",
                                detail: (error as? API.ServerError)?.message ?? error.localizedDescription,
                                trackScope: nil)
            }
        }
    }

    func cancelGenerate() {
        generateTask?.cancel()
    }

    /// The stretch being rewritten, when only part of `rewritingTrack` is (nil = the whole track).
    private(set) var rewritingRange: ClosedRange<Double>?

    /// Rewrites just the selected section of its track with the model.
    func rewriteSection() {
        guard let sel = sectionSelection, canEditSections else { return }
        rewrite(sel.track, range: sel.range)
    }

    func rewrite(_ track: TrackID, range: ClosedRange<Double>? = nil) {
        guard !isGeneratorBusy, let snapshot = project.currentSnapshot else { return }
        rewritingRange = range
        phase = .rewriting(track, startedAt: .now)
        let attempt = (rewriteAttempts[track] ?? 0) + 1
        rewriteAttempts[track] = attempt
        let seed = rewriteSeed(songSeed: snapshot.seed, track: track, attempt: attempt)
        generateTask = Task {
            do {
                let notes = try await generator.rewrite(track: track, model: activeModel, in: snapshot, seed: seed, range: range)
                var newSnapshot = snapshot
                if let i = newSnapshot.tracks.firstIndex(where: { $0.id == track }) {
                    newSnapshot.tracks[i].notes = notes
                }
                if let range {
                    appendVersion(kind: .rewriteSection(track, start: range.lowerBound, end: range.upperBound),
                                  changed: [track], snapshot: newSnapshot)
                    sectionSelection = SectionSelection(track: track, range: range)   // keep it, to try again
                } else {
                    appendVersion(kind: .rewrite(track), changed: [track], snapshot: newSnapshot)
                }
                rewritingRange = nil
                phase = .idle
            } catch is CancellationError {
                rewritingRange = nil
                phase = .idle
            } catch {
                rewritingRange = nil
                phase = .failed(message: "The \(track.rawValue) didn't finish rewriting.",
                                detail: (error as? API.ServerError)?.message ?? error.localizedDescription,
                                trackScope: track)
            }
        }
    }

    func cancelRewrite() { cancelGenerate() }
    func dismissError() { if case .failed = phase { phase = .idle } }

    /// First generate for a new style (or the project's first ever) gets that style's default
    /// instruments and effects; later generates keep whatever the user has set up.
    private func carryOverMixIfSameStyle(onto fresh: SongSnapshot) -> SongSnapshot {
        guard let current = project.currentSnapshot, current.style == fresh.style else { return fresh }
        var result = fresh
        result.effects = current.effects
        for i in result.tracks.indices {
            let id = result.tracks[i].id
            let previous = current.track(id)
            result.tracks[i].instrument = previous.instrument
            result.tracks[i].volume = previous.volume
            result.tracks[i].isMuted = previous.isMuted
            result.tracks[i].isSoloed = previous.isSoloed
            result.tracks[i].effects = previous.effects
        }
        return result
    }

    private func appendVersion(kind: VersionKind, changed: Set<TrackID>, snapshot: SongSnapshot) {
        let number = (project.versions.map(\.number).max() ?? 0) + 1
        let version = Version(number: number, createdAt: .now, kind: kind, changedTracks: changed, snapshot: snapshot)
        project.versions.append(version)
        project.currentVersionID = version.id
        project.lengthSeconds = snapshot.lengthSeconds
        if listeningVersionID != nil { listeningVersionID = nil }
        if case .sectionEdit = kind {} else { sectionSelection = nil }   // a new take, rewrite or restore invalidates it
        persist()
        loadIntoAudio(snapshot, resumeIfPlaying: true)
    }

    // MARK: Versions (history)

    func undo() {
        guard let i = currentIndex, i > 0 else { return }
        project.currentVersionID = project.versions[i - 1].id
        listeningVersionID = nil
        sectionSelection = nil
        persist()
        if let s = project.currentSnapshot { loadIntoAudio(s, resumeIfPlaying: isPlaying) }
    }

    func redo() {
        guard let i = currentIndex, i < project.versions.count - 1 else { return }
        project.currentVersionID = project.versions[i + 1].id
        listeningVersionID = nil
        sectionSelection = nil
        persist()
        if let s = project.currentSnapshot { loadIntoAudio(s, resumeIfPlaying: isPlaying) }
    }

    /// Plays a past version from the current playhead position, without restoring it.
    func listen(to version: Version) {
        listeningVersionID = version.id
        loadIntoAudio(version.snapshot, resumeIfPlaying: isPlaying)
    }

    func backToCurrentVersion() {
        listeningVersionID = nil
        if let s = project.currentSnapshot { loadIntoAudio(s, resumeIfPlaying: isPlaying) }
    }

    /// Adds a new version on top of the one being listened to, rather than rewinding, so
    /// nothing is lost and the restore is itself undoable.
    func restoreListeningVersion() {
        guard let version = listeningVersion else { return }
        appendVersion(kind: .restore(fromVersion: version.number), changed: Set(TrackID.allCases), snapshot: version.snapshot)
    }

    func toggleKept(_ version: Version) {
        guard let i = project.versions.firstIndex(where: { $0.id == version.id }) else { return }
        project.versions[i].isKept.toggle()
        persist()
    }

    // MARK: Section editing

    /// Edits apply to the current version, so they are off while listening to a past one, while
    /// the generator is busy (its result would overwrite them), and while the piano roll is open
    /// (which has its own editing session).
    var canEditSections: Bool {
        project.currentSnapshot != nil && !isListeningToPastVersion && !isGeneratorBusy && !isPianoRollOpen
    }
    var canPasteSection: Bool { canEditSections && clipboard != nil }
    private var pasteTarget: TrackID? { sectionSelection?.track ?? clipboard?.source }

    private func snapToGrid(_ t: Double) -> Double {
        (t / Self.sectionGrid).rounded() * Self.sectionGrid
    }

    /// Selects `from...to` on one track, snapped to the grid and kept inside the song.
    func selectSection(track: TrackID, from: Double, to: Double) {
        let length = duration
        let lo = min(max(snapToGrid(min(from, to)), 0), length)
        let hi = min(max(snapToGrid(max(from, to)), 0), length)
        guard hi - lo >= Self.sectionGrid else { sectionSelection = nil; return }
        sectionSelection = SectionSelection(track: track, range: lo...hi)
    }

    func clearSectionSelection() { sectionSelection = nil }

    private func notes(of track: TrackID) -> [Note] { project.currentSnapshot?.track(track).notes ?? [] }

    private func label(_ range: ClosedRange<Double>) -> String {
        "\(formatTimecode(range.lowerBound))–\(formatTimecode(range.upperBound))"
    }

    private func commitSection(_ title: String, track: TrackID, notes newNotes: [Note]) {
        guard var snapshot = project.currentSnapshot,
              let i = snapshot.tracks.firstIndex(where: { $0.id == track }) else { return }
        snapshot.tracks[i].notes = newNotes
        appendVersion(kind: .sectionEdit(track, title), changed: [track], snapshot: snapshot)
    }

    func copySection() {
        guard let sel = sectionSelection, canEditSections else { return }
        var clip = NoteEditing.copy(notes(of: sel.track), range: sel.range)
        clip.source = sel.track
        clipboard = clip
    }

    func cutSection() {
        guard let sel = sectionSelection, canEditSections else { return }
        copySection()
        commitSection("Cut \(sel.track.rawValue) \(label(sel.range))", track: sel.track,
                      notes: NoteEditing.removing(notes(of: sel.track), range: sel.range))
    }

    func deleteSection() {
        guard let sel = sectionSelection, canEditSections else { return }
        commitSection("Deleted \(sel.track.rawValue) \(label(sel.range))", track: sel.track,
                      notes: NoteEditing.removing(notes(of: sel.track), range: sel.range))
    }

    /// Pastes at the playhead (on the grid), onto the selected track, or the track it was
    /// copied from if nothing is selected. The pasted stretch becomes the selection.
    func pasteSection(onto track: TrackID? = nil) {
        guard canPasteSection, let clip = clipboard, let track = track ?? pasteTarget else { return }
        let at = min(snapToGrid(position), max(duration - Self.sectionGrid, 0))
        let result = NoteEditing.pasting(clip, into: notes(of: track), at: at, songLength: duration)
        let end = min(at + clip.length, duration)
        commitSection("Pasted into \(track.rawValue) at \(formatTimecode(at))", track: track, notes: result)
        if end - at >= Self.sectionGrid { sectionSelection = SectionSelection(track: track, range: at...end) }
    }

    func duplicateSection() {
        guard let sel = sectionSelection, canEditSections, sel.range.upperBound < duration else { return }
        let result = NoteEditing.duplicating(notes(of: sel.track), range: sel.range, songLength: duration)
        let length = sel.range.upperBound - sel.range.lowerBound
        let newEnd = min(sel.range.upperBound + length, duration)
        commitSection("Duplicated \(sel.track.rawValue) \(label(sel.range))", track: sel.track, notes: result)
        sectionSelection = SectionSelection(track: sel.track, range: sel.range.upperBound...newEnd)
    }

    /// Moves the selected stretch by `seconds` (snapped to the grid), overwriting the destination.
    func moveSection(by seconds: Double) {
        guard let sel = sectionSelection, canEditSections else { return }
        let offset = snapToGrid(seconds)
        guard abs(offset) >= Self.sectionGrid else { return }
        let moved = NoteEditing.moving(notes(of: sel.track), range: sel.range, by: offset, songLength: duration)
        guard moved.range != sel.range else { return }
        commitSection("Moved \(sel.track.rawValue) \(label(sel.range)) to \(formatTimecode(moved.range.lowerBound))",
                      track: sel.track, notes: moved.notes)
        sectionSelection = SectionSelection(track: sel.track, range: moved.range)
    }

    func useSectionAsLoop() {
        guard let sel = sectionSelection else { return }
        setLoopRange(sel.range)
    }

    // MARK: Mix (not versioned)

    private func mutateCurrentTrack(_ id: TrackID, _ body: (inout Track) -> Void) {
        guard let vi = currentIndex else { return }
        guard let ti = project.versions[vi].snapshot.tracks.firstIndex(where: { $0.id == id }) else { return }
        body(&project.versions[vi].snapshot.tracks[ti])
        persist()
        pushMixToAudio()
    }

    func setMuted(_ muted: Bool, for id: TrackID) { mutateCurrentTrack(id) { $0.isMuted = muted } }
    func setSoloed(_ soloed: Bool, for id: TrackID) { mutateCurrentTrack(id) { $0.isSoloed = soloed } }
    func setVolume(_ v: Double, for id: TrackID) { mutateCurrentTrack(id) { $0.volume = v } }
    func setInstrument(_ name: String, for id: TrackID) { mutateCurrentTrack(id) { $0.instrument = name } }
    func setTrackEffects(_ effects: TrackEffects, for id: TrackID) { mutateCurrentTrack(id) { $0.effects = effects } }

    /// Back to the style's starting effects for this track (neutral if the style gives it none).
    func resetTrackEffects(for id: TrackID) {
        setTrackEffects(project.style.defaultTrackEffects[id] ?? TrackEffects(), for: id)
    }

    func setEffects(_ effects: MixEffects) {
        guard let vi = currentIndex else { return }
        project.versions[vi].snapshot.effects = effects
        persist()
        audio.apply(effects)
    }

    var effectsAreAtStyleDefault: Bool {
        guard let e = project.currentSnapshot?.effects else { return true }
        return e == project.style.defaultEffects
    }

    func resetEffectsToStyleDefault() {
        setEffects(project.style.defaultEffects)
    }

    private func pushMixToAudio() {
        guard let snapshot = displayedSnapshot else { return }
        let anySolo = snapshot.tracks.contains { $0.isSoloed }
        for track in snapshot.tracks {
            let audible = anySolo ? track.isSoloed : !track.isMuted
            audio.setInstrument(track.id.program(for: track.instrument), for: track.id)
            audio.setVolume(audible ? track.volume : 0, for: track.id)
            audio.apply(track.effects, for: track.id)
        }
        audio.apply(snapshot.effects)
    }

    // MARK: Project-level settings

    func setStyle(_ style: MusicStyle) { project.style = style; persist() }
    func setModel(_ model: NoteModel) { project.model = model; persist() }
    func setLength(_ seconds: Double) { project.lengthSeconds = seconds; persist() }

    func pinSeed(_ seed: UInt32) { project.pinnedSeed = seed; persist() }
    func clearPinnedSeed() { project.pinnedSeed = nil; persist() }
    func copySeedToPasteboard() {
        guard let seed = displaySeed else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(String(seed), forType: .string)
    }

    func rename(to name: String) {
        project.name = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? project.name : name.trimmingCharacters(in: .whitespacesAndNewlines)
        persist()
    }

    private func persist() { store.update(project) }

    // MARK: Piano-roll editing session

    /// Sounds a note through the track's instrument and effects, for auditioning while editing.
    func previewNote(pitch: Int, velocity: Int, track: TrackID) {
        audio.preview(pitch: pitch, velocity: velocity, track: track)
    }

    func openEditor(for track: TrackID) {
        editingTrack = track
        editingSnapshotBeforeSession = project.currentSnapshot
        isPianoRollOpen = true
        selectedTrack = track
        selectedNoteIDs = []
    }

    func closeEditor() {
        defer { isPianoRollOpen = false; editingTrack = nil; selectedNoteIDs = []; editingSnapshotBeforeSession = nil }
        guard let track = editingTrack, let before = editingSnapshotBeforeSession,
              let after = project.currentSnapshot, before.track(track).notes != after.track(track).notes else { return }
        // The notes already live in the current version's snapshot (edited in place as the
        // user works); committing here only records that a note-editing version happened.
        appendVersion(kind: .noteEdit(track), changed: [track], snapshot: after)
    }

    /// Replaces one track's notes during an editing session, without creating a version yet
    /// (that happens once, in `closeEditor()`).
    func updateEditingNotes(_ notes: [Note], for track: TrackID) {
        guard let vi = currentIndex else { return }
        guard let ti = project.versions[vi].snapshot.tracks.firstIndex(where: { $0.id == track }) else { return }
        project.versions[vi].snapshot.tracks[ti].notes = notes
        persist()
        loadIntoAudio(project.versions[vi].snapshot, resumeIfPlaying: isPlaying)
    }

    // MARK: Transport

    private func loadIntoAudio(_ snapshot: SongSnapshot, resumeIfPlaying: Bool = false) {
        let wasPlaying = resumeIfPlaying && isPlaying
        let savedPosition = position
        audio.load(snapshot)
        pushMixToAudio()
        position = min(savedPosition, snapshot.lengthSeconds)
        audio.position = position
        if wasPlaying { play() }
    }

    func togglePlay() { isPlaying ? pause() : play() }

    func play() {
        guard displayedSnapshot != nil else { return }
        do {
            try audio.play()
            isPlaying = true
            ticker?.invalidate()
            ticker = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
        } catch {
            phase = .failed(message: "Couldn't start audio.", detail: error.localizedDescription, trackScope: nil)
        }
    }

    func pause() {
        audio.stop()
        ticker?.invalidate(); ticker = nil
        isPlaying = false
    }

    func seek(to time: Double) {
        audio.position = time
        position = audio.position
    }

    func toggleLoop() { isLoopEnabled.toggle() }
    func setLoopRange(_ range: ClosedRange<Double>?) {
        loopRange = range
        isLoopEnabled = range != nil
    }
    func clearLoop() { loopRange = nil; isLoopEnabled = false }

    private func tick() {
        position = audio.position
        if isLoopEnabled, let range = loopRange, position >= range.upperBound {
            seek(to: range.lowerBound)
            return
        }
        if position >= audio.seconds + 1.5 {   // let the last notes ring out
            pause()
            seek(to: 0)
        }
    }

    // MARK: Export

    enum ExportFormat: String, CaseIterable, Identifiable {
        case m4a = "M4A", wav = "WAV", midi = "MIDI"
        var id: String { rawValue }
        var type: UTType {
            switch self {
            case .wav: .wav
            case .m4a: .mpeg4Audio
            case .midi: .midi
            }
        }
        var note: String {
            switch self {
            case .m4a: "Compressed audio, smaller file. The mix and effects exactly as heard."
            case .wav: "Uncompressed audio, larger file. The mix and effects exactly as heard."
            case .midi: "Notes only. Effects and instruments are not included."
            }
        }
    }
    enum ExportRange: String, CaseIterable, Identifiable {
        case whole = "Whole song", loop = "Loop range"
        var id: String { rawValue }
    }

    private(set) var isExporting = false
    private(set) var exportProgress: Double = 0
    private(set) var exportResult: (url: URL, seconds: Double, bytes: Int64)?

    func canExport(range: ExportRange) -> Bool { range == .whole || loopRange != nil }

    func chooseExportDestination(format: ExportFormat) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.type]
        let seedPart = displaySeed.map { "-\($0)" } ?? ""
        panel.nameFieldStringValue = "\(project.name)\(seedPart)"
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    func export(format: ExportFormat, range: ExportRange, to url: URL) async {
        guard let snapshot = project.currentSnapshot else { return }
        isExporting = true
        exportProgress = 0
        exportResult = nil
        let wasPlaying = isPlaying
        let bounds: ClosedRange<Double>? = range == .loop ? loopRange : nil
        do {
            if format == .midi {
                try audio.midiData().write(to: url)
            } else {
                try audio.export(to: url, format: format == .wav ? .wav : .m4a, range: bounds)
            }
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? nil
            let seconds = (bounds.map { $0.upperBound - $0.lowerBound }) ?? snapshot.lengthSeconds
            exportResult = (url, seconds, size ?? 0)
        } catch {
            phase = .failed(message: "Export failed.", detail: error.localizedDescription, trackScope: nil)
        }
        isExporting = false
        exportProgress = 1
        loadIntoAudio(snapshot, resumeIfPlaying: wasPlaying)
    }
}
