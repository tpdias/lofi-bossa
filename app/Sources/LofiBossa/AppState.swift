import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AppState: ObservableObject {
    enum Busy: Equatable {
        case generating
        case regenerating(TrackKind)
    }

    @Published var style: Style = .lofi
    @Published var seconds: Double = 30
    @Published private(set) var song: Song?
    @Published private(set) var undoSong: Song?
    @Published private(set) var busy: Busy?
    @Published var error: String?
    @Published private(set) var serverUp = false
    /// Styles the generator has a fine-tuned checkpoint for.
    @Published private(set) var finetunedStyles: Set<Style> = []
    /// The user's preference; `activeModel` is what is actually used for the current style.
    @Published var model: ModelChoice = .finetuned

    var hasFinetuned: Bool { finetunedStyles.contains(style) }
    var activeModel: ModelChoice { hasFinetuned ? model : .pretrained }
    @Published private(set) var isPlaying = false
    @Published private(set) var position: Double = 0

    @Published var mix: [TrackKind: TrackMix] {
        didSet { pushMix(old: oldValue) }
    }
    @Published var effects: Effects {
        didSet { audio.apply(effects) }
    }

    private let audio = AudioEngine()
    private let api = API()
    private var ticker: Timer?

    init() {
        let style = Style.lofi
        mix = Dictionary(uniqueKeysWithValues: TrackKind.allCases.map { kind in
            (kind, TrackMix(preset: Self.preset(for: kind, in: style)))
        })
        effects = style.effects
        audio.apply(effects)
        pushMix(old: [:])
        Task { await watchServer() }

        // `LofiBossa --open song.json [lofi|bossa]` starts with a saved song loaded.
        let args = CommandLine.arguments
        if let flag = args.firstIndex(of: "--open"), args.count > flag + 1,
           let data = try? Data(contentsOf: URL(fileURLWithPath: args[flag + 1])),
           let saved = try? JSONDecoder().decode(Song.self, from: data) {
            if args.count > flag + 2, let named = Style(rawValue: args[flag + 2]) {
                self.style = named
                applySound(of: named)
            }
            seconds = min(max((saved.seconds / 15).rounded() * 15, 15), 180)
            show(saved, at: 0, playing: false)
        }
    }

    private static func preset(for kind: TrackKind, in style: Style) -> InstrumentPreset {
        kind.presets.first { $0.name == style.presetNames[kind] } ?? kind.presets[0]
    }

    // MARK: Mixer

    private func pushMix(old: [TrackKind: TrackMix]) {
        let anySolo = mix.values.contains { $0.soloed }
        for (kind, track) in mix {
            if old[kind]?.preset != track.preset { audio.setInstrument(track.preset, for: kind) }
            let audible = anySolo ? track.soloed : !track.muted
            audio.setVolume(audible ? track.volume : 0, for: kind)
        }
    }

    func isAudible(_ kind: TrackKind) -> Bool {
        guard let track = mix[kind] else { return false }
        return mix.values.contains { $0.soloed } ? track.soloed : !track.muted
    }

    /// Switch instruments and effects to the sound that goes with a style.
    func applySound(of style: Style) {
        for kind in TrackKind.allCases { mix[kind]?.preset = Self.preset(for: kind, in: style) }
        effects = style.effects
    }

    // MARK: Generation

    func generate() async {
        await run(.generating) {
            let new = try await self.api.generate(style: self.style, model: self.activeModel, seconds: self.seconds)
            self.undoSong = nil
            self.applySound(of: self.style)
            self.show(new, at: 0, playing: true)
        }
    }

    func regenerate(_ kind: TrackKind) async {
        guard let current = song else { return }
        await run(.regenerating(kind)) {
            var new = try await self.api.regenerate(kind, in: current, style: self.style, model: self.activeModel)
            new.seconds = max(new.seconds, current.seconds)
            self.undoSong = current
            self.show(new, at: self.position, playing: self.isPlaying)
        }
    }

    func undo() {
        guard let previous = undoSong else { return }
        undoSong = nil
        show(previous, at: position, playing: isPlaying)
    }

    private func run(_ kind: Busy, _ work: @escaping () async throws -> Void) async {
        guard busy == nil else { return }
        busy = kind
        error = nil
        do { try await work() } catch { self.error = error.localizedDescription }
        busy = nil
    }

    private func show(_ new: Song, at time: Double, playing: Bool) {
        song = new
        audio.load(new)
        audio.position = time
        position = audio.position
        if playing { play() } else { stopTicker() }
    }

    private func watchServer() async {
        while !Task.isCancelled {
            let health = await api.health()
            serverUp = health != nil
            if let health { finetunedStyles = health }
            try? await Task.sleep(for: .seconds(serverUp ? 5 : 2))
        }
    }

    // MARK: Transport

    func togglePlay() {
        isPlaying ? pause() : play()
    }

    func play() {
        guard song != nil else { return }
        do {
            try audio.play()
            isPlaying = true
            ticker?.invalidate()
            ticker = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                // Timers fire on the main run loop, so no task hop is needed 30 times a second.
                MainActor.assumeIsolated { self?.tick() }
            }
        } catch {
            self.error = "Couldn't start audio: \(error.localizedDescription)"
        }
    }

    func pause() {
        audio.stop()
        stopTicker()
    }

    func seek(to time: Double) {
        audio.position = time
        position = audio.position
    }

    private func tick() {
        position = audio.position
        if position >= audio.seconds + 1.5 {   // let the last notes ring out
            pause()
            seek(to: 0)
        }
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
        isPlaying = false
    }

    // MARK: Export

    enum ExportKind: String, CaseIterable {
        case wav = "WAV", m4a = "M4A", midi = "MIDI"

        var type: UTType {
            switch self {
            case .wav: .wav
            case .m4a: .mpeg4Audio
            case .midi: .midi
            }
        }
    }

    func export(_ kind: ExportKind) {
        guard let song else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [kind.type]
        panel.nameFieldStringValue = "\(style.rawValue)-\(song.seed)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        pause()
        do {
            switch kind {
            case .wav: try audio.export(to: url, format: .wav)
            case .m4a: try audio.export(to: url, format: .m4a)
            case .midi: try audio.midiData().write(to: url)
            }
            seek(to: 0)
        } catch {
            self.error = "Export failed: \(error.localizedDescription)"
        }
    }
}
