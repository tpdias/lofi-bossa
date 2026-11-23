import AVFoundation
#if os(macOS)
import AppKit
#endif
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
    /// While a piano roll is open, Undo / Redo step through that session's note edits (the
    /// version list stays put until the roll closes); otherwise they move the version pointer.
    var canUndo: Bool { isPianoRollOpen ? canUndoNoteEdit : canUndoVersion }
    var canRedo: Bool { isPianoRollOpen ? canRedoNoteEdit : canRedoVersion }
    var canUndoVersion: Bool { (currentIndex ?? 0) > 0 }
    var canRedoVersion: Bool { (currentIndex ?? -1) < project.versions.count - 1 }
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

    private var tracksToGenerate: [TrackID] { project.currentSnapshot?.trackIDs ?? TrackID.core }

    /// The busyness the model's notes for a track are cleaned to: the track's own, or the song's.
    func busyness(for id: TrackID) -> Double {
        project.currentSnapshot?.track(id).busyness ?? project.songBusyness
    }

    /// How long a track's new notes should be: the track's own, or the song's.
    func noteLength(for id: TrackID) -> Double {
        project.currentSnapshot?.track(id).noteLength ?? project.songNoteLength
    }

    /// Tracks the next Generate keeps as they are (and writes the others around).
    var lockedTracks: Set<TrackID> {
        Set(project.currentSnapshot?.tracks.filter(\.isLocked).map(\.id) ?? [])
    }

    /// Every track locked leaves nothing for Generate to write.
    var canGenerate: Bool {
        guard let snapshot = project.currentSnapshot else { return true }
        return !snapshot.tracks.allSatisfy(\.isLocked)
    }

    func generate() {
        guard !isGeneratorBusy, canGenerate else { return }
        let locked = lockedTracks
        let seed = project.pinnedSeed ?? UInt32.random(in: 0...UInt32.max)
        phase = .generating(startedAt: .now, seed: seed)
        generateTask = Task {
            do {
                for try await event in generator.generate(
                    style: project.style, model: activeModel, length: project.lengthSeconds,
                    seed: project.pinnedSeed, tracks: tracksToGenerate,
                    busyness: Dictionary(uniqueKeysWithValues: tracksToGenerate.map { ($0, busyness(for: $0)) }),
                    noteLength: Dictionary(uniqueKeysWithValues: tracksToGenerate.map { ($0, noteLength(for: $0)) }),
                    key: project.key, strictKey: project.isStrictKey,
                    keeping: locked.isEmpty ? nil : project.currentSnapshot, locked: locked
                ) {
                    guard case .finished(var snapshot) = event else { continue }
                    snapshot = carryOverMixIfSameStyle(onto: snapshot)
                    for i in snapshot.tracks.indices { snapshot.tracks[i].isLocked = locked.contains(snapshot.tracks[i].id) }
                    let kept = snapshot.trackIDs.filter(locked.contains)
                    appendVersion(kind: kept.isEmpty ? .newTake(seed: snapshot.seed)
                                                     : .takeAroundLocked(seed: snapshot.seed, kept: kept),
                                  changed: Set(snapshot.trackIDs).subtracting(locked), snapshot: snapshot)
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

    nonisolated static let maxSongLength: Double = 180
    nonisolated static let extendStep: Double = 30

    var canExtend: Bool {
        guard let snapshot = project.currentSnapshot else { return false }
        return !isGeneratorBusy && listeningVersionID == nil && snapshot.lengthSeconds < Self.maxSongLength - 1
    }

    /// Continues the current song for `seconds` more, every track at once; a new version.
    func extend(by seconds: Double = ProjectViewModel.extendStep) {
        guard canExtend, let snapshot = project.currentSnapshot else { return }
        let seed = UInt32.random(in: 0...UInt32.max)
        phase = .generating(startedAt: .now, seed: seed)
        generateTask = Task {
            do {
                let ids = snapshot.trackIDs
                let longer = try await generator.extend(
                    snapshot, by: seconds, model: activeModel, seed: seed,
                    busyness: Dictionary(uniqueKeysWithValues: ids.map { ($0, busyness(for: $0)) }),
                    noteLength: Dictionary(uniqueKeysWithValues: ids.map { ($0, noteLength(for: $0)) }),
                    key: project.key, strictKey: project.isStrictKey)
                appendVersion(kind: .extend(to: longer.lengthSeconds), changed: Set(ids), snapshot: longer)
                phase = .idle
            } catch is CancellationError {
                phase = .idle
            } catch {
                phase = .failed(message: "The song couldn't be extended.",
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
                let (notes, detectedKey) = try await generator.rewrite(
                    track: track, model: activeModel, in: snapshot, seed: seed, range: range,
                    busyness: busyness(for: track), noteLength: noteLength(for: track),
                    key: project.key, strictKey: project.isStrictKey)
                var newSnapshot = snapshot
                newSnapshot.detectedKey = detectedKey
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
            result.tracks[i].busyness = previous.busyness
            result.tracks[i].noteLength = previous.noteLength
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

    /// ⌘Z, the toolbar Undo buttons and the iPhone roll's Undo: a note edit while a roll is
    /// open, otherwise the previous version.
    func undo() { isPianoRollOpen ? undoNoteEdit() : undoVersion() }
    func redo() { isPianoRollOpen ? redoNoteEdit() : redoVersion() }

    func undoVersion() {
        guard !isPianoRollOpen, let i = currentIndex, i > 0 else { return }
        project.currentVersionID = project.versions[i - 1].id
        listeningVersionID = nil
        sectionSelection = nil
        persist()
        if let s = project.currentSnapshot { loadIntoAudio(s, resumeIfPlaying: isPlaying) }
    }

    func redoVersion() {
        guard !isPianoRollOpen, let i = currentIndex, i < project.versions.count - 1 else { return }
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
        appendVersion(kind: .restore(fromVersion: version.number), changed: Set(version.snapshot.trackIDs), snapshot: version.snapshot)
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

    // MARK: Adding and removing tracks

    /// The optional tracks this song doesn't have yet.
    var addableTracks: [TrackID] {
        guard let snapshot = displayedSnapshot else { return [] }
        return TrackID.optional.filter { !snapshot.hasTrack($0) }
    }
    var canChangeTracks: Bool {
        project.currentSnapshot != nil && !isListeningToPastVersion && !isGeneratorBusy && !isPianoRollOpen
    }

    /// Adds an optional track (as its own version, so it can be undone) and asks the model to
    /// write it. If the generator can't, the empty track stays and can be rewritten later.
    func addTrack(_ id: TrackID) {
        guard canChangeTracks, var snapshot = project.currentSnapshot, !snapshot.hasTrack(id) else { return }
        snapshot.tracks.append(Track(
            id: id, instrument: snapshot.style.defaultInstruments[id] ?? id.defaultInstrument,
            effects: snapshot.style.defaultTrackEffects[id] ?? TrackEffects()))
        snapshot.tracks.sort { TrackID.allCases.firstIndex(of: $0.id)! < TrackID.allCases.firstIndex(of: $1.id)! }
        appendVersion(kind: .addTrack(id), changed: [id], snapshot: snapshot)
        selectedTrack = id
        rewrite(id)
    }

    /// Removes an optional track. The four core tracks always stay.
    func removeTrack(_ id: TrackID) {
        guard canChangeTracks, !id.isCore, var snapshot = project.currentSnapshot, snapshot.hasTrack(id) else { return }
        snapshot.tracks.removeAll { $0.id == id }
        if selectedTrack == id { selectedTrack = nil }
        if sectionSelection?.track == id { sectionSelection = nil }
        appendVersion(kind: .removeTrack(id), changed: [id], snapshot: snapshot)
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
    /// nil = follow the song's busyness. Takes effect on the next generate or rewrite.
    func setTrackBusyness(_ value: Double?, for id: TrackID) { mutateCurrentTrack(id) { $0.busyness = value } }
    func setTrackNoteLength(_ value: Double?, for id: TrackID) { mutateCurrentTrack(id) { $0.noteLength = value } }
    func setLocked(_ locked: Bool, for id: TrackID) { mutateCurrentTrack(id) { $0.isLocked = locked } }

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
    func setBusyness(_ value: Double) { project.busyness = min(max(value, 0), 1); persist() }
    func setNoteLength(_ value: Double) { project.noteLength = min(max(value, 0), 1); persist() }
    /// `nil` (Auto) detects the key from the song; a name from `MusicKey.names` pins it.
    func setKey(_ name: String?) { project.key = name; persist() }
    func setStrictKey(_ strict: Bool) { project.strictKey = strict; persist() }

    /// What to show next to the Key menu: the detected key when Auto and there is a current
    /// song to have detected one from, otherwise nothing.
    var displayedKey: String? { project.key ?? project.currentSnapshot?.detectedKey }

    func pinSeed(_ seed: UInt32) { project.pinnedSeed = seed; persist() }
    func clearPinnedSeed() { project.pinnedSeed = nil; persist() }
    func copySeedToPasteboard() {
        guard let seed = displaySeed else { return }
        Pasteboard.copy(String(seed))
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
        if isPianoRollOpen {
            if editingTrack == track { return }   // already editing it: keep the session and its undo steps
            closeEditor()                         // another track: that session becomes its version first
        }
        editingTrack = track
        editingSnapshotBeforeSession = project.currentSnapshot
        isPianoRollOpen = true
        selectedTrack = track
        selectedNoteIDs = []
        resetNoteUndo()
    }

    func closeEditor() {
        defer {
            isPianoRollOpen = false; editingTrack = nil; selectedNoteIDs = []; editingSnapshotBeforeSession = nil
            resetNoteUndo()
        }
        guard let track = editingTrack, let before = editingSnapshotBeforeSession,
              let after = project.currentSnapshot, before.track(track).notes != after.track(track).notes else { return }
        // The notes were edited in place on the current version's snapshot as the user worked;
        // put that version back as it was, and add the edited song as one new version on top,
        // so Undo after closing steps back to the notes from before the session.
        if let vi = currentIndex, let ti = project.versions[vi].snapshot.tracks.firstIndex(where: { $0.id == track }) {
            project.versions[vi].snapshot.tracks[ti].notes = before.track(track).notes
        }
        appendVersion(kind: .noteEdit(track), changed: [track], snapshot: after)
    }

    /// Replaces one track's notes during an editing session, without creating a version yet
    /// (that happens once, in `closeEditor()`). Each call is one step on the session's undo
    /// stack, unless it falls inside `beginNoteGesture()` … `endNoteGesture()`.
    func updateEditingNotes(_ notes: [Note], for track: TrackID) {
        guard let vi = currentIndex else { return }
        guard let ti = project.versions[vi].snapshot.tracks.firstIndex(where: { $0.id == track }) else { return }
        let before = project.versions[vi].snapshot.tracks[ti].notes
        guard before != notes else { return }
        if isPianoRollOpen, track == editingTrack, !(isInNoteGesture && gestureRecorded) {
            recordNoteUndo(NoteEditStep(notes: before, selection: selectedNoteIDs))
            gestureRecorded = isInNoteGesture
        }
        setEditingNotes(notes, vi: vi, ti: ti)
        if isPianoRollOpen, track == editingTrack { nameUndoAction() }
    }

    private func setEditingNotes(_ notes: [Note], vi: Int, ti: Int) {
        project.versions[vi].snapshot.tracks[ti].notes = notes
        persist()
        loadIntoAudio(project.versions[vi].snapshot, resumeIfPlaying: isPlaying)
    }

    // MARK: Note-level undo (inside one piano-roll session)

    /// The notes of the track being edited, and which were selected, at one point in the session.
    struct NoteEditStep: Equatable {
        var notes: [Note]
        var selection: Set<Note.ID>
    }

    /// Before-states of the edits made since the roll opened (most recent last), and the ones
    /// undone since the last edit. Both are cleared when the roll opens or closes: once closed,
    /// the whole session is one version and Undo steps through versions again.
    private(set) var noteUndoStack: [NoteEditStep] = []
    private(set) var noteRedoStack: [NoteEditStep] = []
    private var isInNoteGesture = false
    private var gestureRecorded = false
    static let maxNoteUndoSteps = 200

    /// The window's undo manager, while a roll is open, so the Edit menu, the iPad hardware
    /// keyboard and the iPhone's shake / three-finger undo walk this same stack.
    @ObservationIgnored private weak var undoManager: UndoManager?

    var canUndoNoteEdit: Bool { isPianoRollOpen && !noteUndoStack.isEmpty }
    var canRedoNoteEdit: Bool { isPianoRollOpen && !noteRedoStack.isEmpty }
    var noteUndoTitle: String? {
        guard canUndoNoteEdit, let step = noteUndoStack.last else { return nil }
        return Self.describeNoteChange(from: step.notes, to: editingNotes)
    }
    var noteRedoTitle: String? {
        guard canRedoNoteEdit, let step = noteRedoStack.last else { return nil }
        return Self.describeNoteChange(from: editingNotes, to: step.notes)
    }

    private var editingNotes: [Note] {
        guard let track = editingTrack else { return [] }
        return project.currentSnapshot?.track(track).notes ?? []
    }

    /// Edits until `endNoteGesture()` (one drag, one slider pull) undo as a single step.
    /// Calling it again inside the same gesture (a drawn note that is then stretched) keeps it one step.
    func beginNoteGesture() {
        guard !isInNoteGesture else { return }
        isInNoteGesture = true; gestureRecorded = false
    }
    func endNoteGesture() { isInNoteGesture = false; gestureRecorded = false }

    /// Hands the window's undo manager to the open roll's undo stack (the roll views call this
    /// when they appear). Steps already made are registered with it, so the menu can undo them.
    func attachUndoManager(_ manager: UndoManager?) {
        guard manager !== undoManager else { return }
        undoManager?.removeAllActions(withTarget: undoTarget)
        undoManager = manager
        guard let manager, isPianoRollOpen else { return }
        for _ in noteUndoStack { registerUndoAction(with: manager) }
        nameUndoAction()
    }

    func undoNoteEdit() {
        guard canUndoNoteEdit else { return }
        // Through the undo manager when there is one, so it stays in step for the Edit menu and
        // shake-to-undo; it calls back into `applyNoteUndo()`.
        if let undoManager, undoManager.canUndo, !undoManager.isUndoing, !undoManager.isRedoing {
            undoManager.undo()
        } else {
            applyNoteUndo()
        }
    }

    func redoNoteEdit() {
        guard canRedoNoteEdit else { return }
        if let undoManager, undoManager.canRedo, !undoManager.isUndoing, !undoManager.isRedoing {
            undoManager.redo()
        } else {
            applyNoteRedo()
        }
    }

    private func recordNoteUndo(_ step: NoteEditStep) {
        noteUndoStack.append(step)
        if noteUndoStack.count > Self.maxNoteUndoSteps { noteUndoStack.removeFirst() }
        noteRedoStack.removeAll()
        if let undoManager { registerUndoAction(with: undoManager) }
    }

    /// The undo manager's target (it calls back by selector and doesn't retain it, so the model does).
    @ObservationIgnored private lazy var undoTarget = NoteUndoTarget(model: self)

    /// Names the top undo step for the Edit menu ("Undo Move Notes"). Only when the manager has
    /// one: naming with nothing to undo raises an Objective-C exception.
    private func nameUndoAction() {
        guard let undoManager, undoManager.canUndo, !undoManager.isUndoing, !undoManager.isRedoing,
              let title = noteUndoTitle else { return }
        undoManager.setActionName(title)
    }

    private func registerUndoAction(with manager: UndoManager) {
        manager.registerUndo(withTarget: undoTarget, selector: #selector(NoteUndoTarget.undoNoteEdit), object: nil)
    }
    private func registerRedoAction(with manager: UndoManager) {
        manager.registerUndo(withTarget: undoTarget, selector: #selector(NoteUndoTarget.redoNoteEdit), object: nil)
    }

    fileprivate func performNoteUndoFromManager() { applyNoteUndo() }
    fileprivate func performNoteRedoFromManager() { applyNoteRedo() }

    private func applyNoteUndo() {
        guard isPianoRollOpen, let step = noteUndoStack.popLast() else { return }
        endNoteGesture()
        let title = Self.describeNoteChange(from: step.notes, to: editingNotes)
        noteRedoStack.append(NoteEditStep(notes: editingNotes, selection: selectedNoteIDs))
        restore(step)
        if let undoManager {   // registered while undoing, so it lands on the redo stack
            registerRedoAction(with: undoManager)
            undoManager.setActionName(title)
        }
    }

    private func applyNoteRedo() {
        guard isPianoRollOpen, let step = noteRedoStack.popLast() else { return }
        endNoteGesture()
        let title = Self.describeNoteChange(from: editingNotes, to: step.notes)
        noteUndoStack.append(NoteEditStep(notes: editingNotes, selection: selectedNoteIDs))
        restore(step)
        if let undoManager {   // registered while redoing, so it lands on the undo stack
            registerUndoAction(with: undoManager)
            undoManager.setActionName(title)
        }
    }

    private func restore(_ step: NoteEditStep) {
        guard let track = editingTrack, let vi = currentIndex,
              let ti = project.versions[vi].snapshot.tracks.firstIndex(where: { $0.id == track }) else { return }
        setEditingNotes(step.notes, vi: vi, ti: ti)
        let ids = Set(step.notes.map(\.id))
        selectedNoteIDs = step.selection.intersection(ids)
    }

    private func resetNoteUndo() {
        noteUndoStack.removeAll()
        noteRedoStack.removeAll()
        endNoteGesture()
        undoManager?.removeAllActions(withTarget: undoTarget)
    }

    /// What an edit did, for the Edit menu ("Undo Move Notes").
    nonisolated static func describeNoteChange(from before: [Note], to after: [Note]) -> String {
        let old = Dictionary(before.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let new = Dictionary(after.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let added = after.filter { old[$0.id] == nil }.count
        let removed = before.filter { new[$0.id] == nil }.count
        func plural(_ n: Int) -> String { n == 1 ? "Note" : "Notes" }
        if added > 0 && removed == 0 { return "Add \(plural(added))" }
        if removed > 0 && added == 0 { return "Delete \(plural(removed))" }
        if added > 0 || removed > 0 { return "Note Edit" }
        let changed = after.compactMap { n in old[n.id].flatMap { $0 != n ? ($0, n) : nil } }
        guard !changed.isEmpty else { return "Note Edit" }
        if changed.allSatisfy({ $0.0.velocity != $0.1.velocity && $0.0.start == $0.1.start && $0.0.pitch == $0.1.pitch && $0.0.duration == $0.1.duration }) {
            return "Change Loudness"
        }
        if changed.allSatisfy({ $0.0.duration != $0.1.duration && $0.0.start == $0.1.start && $0.0.pitch == $0.1.pitch }) {
            return "Resize \(plural(changed.count))"
        }
        if changed.allSatisfy({ $0.0.duration == $0.1.duration && $0.0.velocity == $0.1.velocity }) {
            return "Move \(plural(changed.count))"
        }
        return "Note Edit"
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

    /// A click on the ruler moves the playhead; a click inside the loop that's set also removes
    /// that loop (the way to get rid of it without hunting for its ✕).
    func tapRuler(at time: Double) {
        clearSectionSelection()
        if let range = loopRange, range.contains(time) { clearLoop() }
        seek(to: time)
    }

    // MARK: Menu commands (Edit / Transport / Track menus)

    /// "New take · seed 5", the version Undo would step back from, or "Move Notes" while a roll
    /// is open; nil when there is nothing to undo.
    var undoTitle: String? {
        if isPianoRollOpen { return noteUndoTitle }
        return canUndoVersion ? currentIndex.map { project.versions[$0].kind.title } : nil
    }
    /// The version Redo would step forward to, or the note edit it would bring back.
    var redoTitle: String? {
        if isPianoRollOpen { return noteRedoTitle }
        return canRedoVersion ? currentIndex.map { project.versions[$0 + 1].kind.title } : nil
    }

    func nudgePlayhead(by seconds: Double) { seek(to: min(max(position + seconds, 0), duration)) }

    func selectTrack(_ id: TrackID) { selectedTrack = id }
    func toggleLockOfSelectedTrack() {
        guard let id = selectedTrack, let track = displayedSnapshot?.track(id) else { return }
        setLocked(!track.isLocked, for: id)
    }

    func toggleMuteOfSelectedTrack() {
        guard let id = selectedTrack, let track = displayedSnapshot?.track(id) else { return }
        setMuted(!track.isMuted, for: id)
    }
    func toggleSoloOfSelectedTrack() {
        guard let id = selectedTrack, let track = displayedSnapshot?.track(id) else { return }
        setSoloed(!track.isSoloed, for: id)
    }
    func rewriteSelectedTrack() { if let id = selectedTrack { rewrite(id) } }
    func openEditorForSelectedTrack() { if let id = selectedTrack { openEditor(for: id) } }
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
        #if os(iOS)
        // No save panel on iOS: export to a temporary file, then Share / Save to Files (HANDOFF §8).
        let seedPart = displaySeed.map { "-\($0)" } ?? ""
        // Spelled out: deriving it from the UTType gave ".mp4" for M4A.
        let ext = switch format { case .m4a: "m4a"; case .wav: "wav"; case .midi: "mid" }
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("\(project.name)\(seedPart)").appendingPathExtension(ext)
        #else
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.type]
        let seedPart = displaySeed.map { "-\($0)" } ?? ""
        panel.nameFieldStringValue = "\(project.name)\(seedPart)"
        guard panel.runModal() == .OK else { return nil }
        return panel.url
        #endif
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

/// What the window's `UndoManager` calls for a note edit; it forwards to the open roll's stack.
@MainActor
final class NoteUndoTarget: NSObject {
    private weak var model: ProjectViewModel?
    init(model: ProjectViewModel) { self.model = model }
    @objc func undoNoteEdit() { model?.performNoteUndoFromManager() }
    @objc func redoNoteEdit() { model?.performNoteRedoFromManager() }
}
