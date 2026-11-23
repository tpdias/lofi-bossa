import SwiftUI

/// Tempo, groove and dynamics, shared by the song settings on every layout (Mac popover, iPad
/// popover, iPhone sheet). They apply to the next take, rewrite or extension; the user's own
/// notes are never moved or re-voiced.
struct MusicSettingsSection: View {
    @Bindable var model: ProjectViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: LFBSpace.sm) {
            HStack {
                Text("Tempo").font(.lfbBodyMedium)
                Spacer()
                Toggle("Auto", isOn: Binding(
                    get: { model.project.tempo == nil },
                    set: { model.setTempo($0 ? nil : (model.displayedTempo ?? 90)) }))
                    .checkboxToggleStyle().font(.lfbCaption)
                    .accessibilityIdentifier("tempoAuto")
            }
            if let bpm = model.project.tempo {
                HStack(spacing: LFBSpace.sm) {
                    Slider(value: Binding(get: { bpm }, set: { model.setTempo($0) }),
                           in: Project.tempoRange, step: 1)
                        .accessibilityLabel("Tempo").accessibilityIdentifier("tempo")
                    Text("\(Int(bpm)) BPM").monospacedDigit().frame(minWidth: 64, alignment: .trailing)
                }
            } else {
                Text(model.displayedTempo.map { "Detected \(Int($0.rounded())) BPM" } ?? "Detected from the song")
                    .font(.lfbCaption).foregroundStyle(Color.lfbTextSecondary)
            }
            labeled("Groove", low: "Loose", high: "Tight", id: "groove",
                    value: Binding(get: { model.project.songGroove }, set: { model.setGroove($0) }))
            labeled("Dynamics", low: "Flat", high: "Expressive", id: "dynamics",
                    value: Binding(get: { model.project.songDynamics }, set: { model.setDynamics($0) }))
            Text("Groove pulls new notes onto the beat; dynamics adds accents and swells.")
                .font(.lfbCaption).foregroundStyle(Color.lfbTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func labeled(_ title: String, low: String, high: String, id: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.lfbBodyMedium)
            HStack(spacing: LFBSpace.sm) {
                Text(low).font(.lfbCaption).foregroundStyle(Color.lfbTextTertiary)
                Slider(value: value, in: 0...1).accessibilityLabel(title).accessibilityIdentifier(id)
                Text(high).font(.lfbCaption).foregroundStyle(Color.lfbTextTertiary)
            }
        }
    }
}

extension ProjectViewModel {
    /// "A minor · 90" for the song settings button: the key (or Auto) and the tempo, if known.
    var musicSummary: String {
        let key = displayedKey ?? "Auto"
        return displayedTempo.map { "\(key) · \(Int($0.rounded()))" } ?? key
    }
}
