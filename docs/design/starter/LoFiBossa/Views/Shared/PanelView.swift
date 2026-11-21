import SwiftUI

/// Sound, Versions and Notes. One view, used as the Mac/iPad inspector (without Notes),
/// inside iPhone sheets (one panel at a time) and as the iPhone Duo's right-hand page.
struct PanelView: View {
    @Bindable var session: ProjectSession
    var panels: [Panel] = Panel.allCases
    var showsPicker = true

    var body: some View {
        VStack(alignment: .leading, spacing: LFBSpace.md) {
            if showsPicker {
                Picker("Panel", selection: $session.panel) {
                    ForEach(panels) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            switch session.panel {
            case .sound: SoundPanel(effects: $session.song.effects)
            case .versions: VersionsPanel(session: session)
            case .notes: PianoRollView(session: session)
            }
        }
    }
}

struct SoundPanel: View {
    @Binding var effects: MixEffects
    var body: some View {
        VStack(spacing: 10) {
            EffectCard(title: "Warmth", caption: "Softens the highs", symbol: "sun.max", amount: $effects.warmth)
            EffectCard(title: "Reverb", caption: "Room around the band", symbol: "dot.radiowaves.left.and.right", amount: $effects.reverb)
            EffectCard(title: "Vinyl", caption: "Hiss and crackle", symbol: "opticaldisc", amount: $effects.vinyl)
            HStack {
                Text("Style defaults, adjusted").font(.lfbBody).foregroundStyle(Color.lfbTextSecondary)
                Spacer()
                Button("Reset") { effects = MixEffects() }   // TODO: per-style defaults
            }
        }
    }
}

struct VersionsPanel: View {
    @Bindable var session: ProjectSession
    var body: some View {
        // Newest first. Each row: four change bars in the track colors, title, "Version N · time",
        // star if kept, Current / Listening badge, listen button.
        // Listening plays that version from the current playhead; Restore adds a new version on top.
        List(session.project.versions.reversed()) { version in
            HStack(spacing: 10) {
                HStack(spacing: 2) {
                    ForEach(TrackID.allCases) { id in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(version.changedTracks.contains(id) ? id.color : Color.lfbHairline)
                            .frame(width: 4, height: 20)
                    }
                }
                .accessibilityHidden(true)
                VStack(alignment: .leading) {
                    Text(title(for: version)).font(.lfbBody.weight(.medium))
                    Text("Version \(version.number) · \(version.createdAt.formatted(date: .omitted, time: .shortened))")
                        .font(.lfbCaption).foregroundStyle(Color.lfbTextTertiary)
                }
                Spacer()
                Button {
                    session.listeningVersion = session.listeningVersion == version.id ? nil : version.id
                } label: {
                    Image(systemName: session.listeningVersion == version.id ? "stop.fill" : "play.fill")
                }
                .accessibilityLabel("Listen to version \(version.number)")
            }
        }
        .listStyle(.plain)
    }

    private func title(for v: Version) -> String {
        switch v.kind {
        case .newTake(let seed): "New take · seed \(seed)"
        case .rewrite(let t): "Rewrote \(t.rawValue)"
        case .noteEdit(let t): "Edited \(t.rawValue) notes"
        case .restore(let n): "Restored version \(n)"
        }
    }
}

/// Piano-roll editor. Same model on every device; input differs.
///
/// Pointer (Mac, iPad with trackpad): click select, shift-click add, drag empty = marquee,
///   drag note = move, drag right edge = resize, double-click empty = add, Delete removes.
/// Finger (iPhone, iPad, Duo): tap select, drag a selected note = move, drag its edge handle = resize,
///   one-finger drag on empty = scroll, long-press then drag on empty = marquee,
///   Draw tool + tap = add, pinch = zoom. Rows are 18 pt on iPhone (12 pt with a pointer).
/// Apple Pencil (iPad): Pencil draws notes directly, finger moves and scrolls (no tool switch needed).
///   Distinguish touch types with a UIKit gesture recognizer (`allowedTouchTypes`) wrapped in
///   UIGestureRecognizerRepresentable (iOS 18).
/// Loudness lane: drag a stem; with a selection, the Loudness slider sets all selected notes.
/// Draw the grid, notes and ghost notes of the other parts in one Canvas; hit-test against the model.
struct PianoRollView: View {
    @Bindable var session: ProjectSession
    var body: some View {
        Text("Piano roll · \(session.selectedTrack?.title ?? "no track")")   // build from the artboards
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
