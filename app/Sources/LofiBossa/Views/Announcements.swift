import SwiftUI
#if canImport(CoreHaptics)
import CoreHaptics
#endif

/// Speaks (through VoiceOver) when a generation, rewrite or export finishes or fails: those waits
/// are long and otherwise silent. Attach once, at the root of every layout.
struct ProgressAnnouncements: ViewModifier {
    let model: ProjectViewModel?

    private struct State: Equatable {
        var generating = false
        var rewriting: TrackID?
        var exporting = false
        var exported: String?
        var failure: String?
    }

    private var state: State {
        guard let model else { return State() }
        var failure: String?
        if case .failed(let message, _, _) = model.phase { failure = message }
        return State(generating: model.isGenerating, rewriting: model.rewritingTrack, exporting: model.isExporting,
                     exported: model.exportResult?.url.lastPathComponent, failure: failure)
    }

    func body(content: Content) -> some View {
        content.onChange(of: state) { old, new in
            if let failure = new.failure, failure != old.failure {
                post("\(failure)")
            } else if old.generating && !new.generating && new.failure == nil {
                post("New take ready")
            } else if let track = old.rewriting, new.rewriting == nil, new.failure == nil {
                post("\(track.title) rewritten")
            } else if old.exporting && !new.exporting {
                post(new.exported.map { "Export finished, \($0)" } ?? "Export failed")
            }
        }
    }

    private func post(_ text: String) {
        var announcement = AttributedString(text)
        announcement.accessibilitySpeechAnnouncementPriority = .high
        AccessibilityNotification.Announcement(announcement).post()
    }
}

extension View {
    func announcesProgress(of model: ProjectViewModel?) -> some View { modifier(ProgressAnnouncements(model: model)) }
}

// MARK: - Haptic beat (iPhone)

/// An optional pulse on the kick and snare while the song plays, so the groove can be felt. The
/// drum notes are already in the song; this only schedules them as a Core Haptics pattern that
/// starts from the playhead. Does nothing where the hardware has no haptic engine.
struct HapticBeatDriver: ViewModifier {
    let model: ProjectViewModel?
    @AppStorage("lfb.hapticBeat") private var enabled = false
    @State private var beat = HapticBeat()
    @State private var lastPosition = 0.0

    func body(content: Content) -> some View {
        content
            .onChange(of: model?.isPlaying == true && enabled) { _, on in
                if on, let model { beat.start(model.displayedSnapshot, from: model.position) } else { beat.stop() }
            }
            .onChange(of: model?.position ?? 0) { _, position in
                defer { lastPosition = position }
                // A seek or a loop wrap: line the pattern up with the playhead again.
                guard enabled, model?.isPlaying == true, position < lastPosition - 0.1 || position - lastPosition > 0.5
                else { return }
                beat.start(model?.displayedSnapshot, from: position)
            }
    }
}

extension View {
    func hapticBeat(of model: ProjectViewModel?) -> some View { modifier(HapticBeatDriver(model: model)) }
}

enum HapticSupport {
    static var isAvailable: Bool {
        #if canImport(CoreHaptics) && os(iOS)
        CHHapticEngine.capabilitiesForHardware().supportsHaptics
        #else
        false
        #endif
    }
}

@MainActor final class HapticBeat {
    #if canImport(CoreHaptics) && os(iOS)
    private var engine: CHHapticEngine?
    private var player: CHHapticPatternPlayer?
    #endif

    func start(_ snapshot: SongSnapshot?, from position: Double) {
        #if canImport(CoreHaptics) && os(iOS)
        stop()
        guard HapticSupport.isAvailable, let drums = snapshot?.tracks.first(where: { $0.id == .drums }) else { return }
        // General MIDI: 35/36 kick, 38/40 snare. Hats and the rest would only blur the feel.
        let events: [CHHapticEvent] = drums.notes.compactMap { note in
            let isKick = note.pitch == 35 || note.pitch == 36
            guard isKick || note.pitch == 38 || note.pitch == 40, note.start >= position else { return nil }
            return CHHapticEvent(
                eventType: .hapticTransient,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: isKick ? 1.0 : 0.65),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: isKick ? 0.25 : 0.8),
                ],
                relativeTime: note.start - position)
        }
        guard !events.isEmpty else { return }
        do {
            let engine = try self.engine ?? CHHapticEngine()
            engine.playsHapticsOnly = true
            engine.isAutoShutdownEnabled = true
            try engine.start()
            self.engine = engine
            let player = try engine.makePlayer(with: CHHapticPattern(events: events, parameters: []))
            try player.start(atTime: CHHapticTimeImmediate)
            self.player = player
        } catch {
            // Haptics are a nicety; a failure is silent.
        }
        #endif
    }

    func stop() {
        #if canImport(CoreHaptics) && os(iOS)
        try? player?.stop(atTime: CHHapticTimeImmediate)
        player = nil
        #endif
    }
}
