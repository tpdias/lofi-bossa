import SwiftUI

struct TrackRow: View {
    @EnvironmentObject private var state: AppState
    let kind: TrackKind

    private var mix: Binding<TrackMix> {
        Binding(get: { state.mix[kind]! }, set: { state.mix[kind] = $0 })
    }
    private var isRegenerating: Bool { state.busy == .regenerating(kind) }

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 2)
                .fill(kind.color)
                .frame(width: 4)

            VStack(alignment: .leading, spacing: 4) {
                Text(kind.title).font(.headline)
                Picker("Instrument", selection: mix.preset) {
                    ForEach(kind.presets, id: \.self) { Text($0.name).tag($0) }
                }
                .labelsHidden()
                .controlSize(.small)
            }
            .frame(width: 150, alignment: .leading)

            NoteOverview(
                notes: state.song?.notes(kind) ?? [],
                seconds: state.song?.seconds ?? 1,
                position: state.position,
                color: kind.color,
                onSeek: state.seek
            )
            .opacity(isRegenerating ? 0.25 : state.isAudible(kind) ? 1 : 0.35)
            .overlay { if isRegenerating { ProgressView().controlSize(.small) } }

            HStack(spacing: 4) {
                ToggleChip(label: "M", isOn: mix.muted, tint: .orange).help("Mute")
                ToggleChip(label: "S", isOn: mix.soloed, tint: .yellow).help("Solo")
            }

            HStack(spacing: 4) {
                Image(systemName: "speaker.fill").font(.caption).foregroundStyle(.secondary)
                Slider(value: mix.volume, in: 0...1)
                    .controlSize(.small)
                    .frame(width: 90)
            }

            Button {
                Task { await state.regenerate(kind) }
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
            }
            .disabled(state.busy != nil || !state.serverUp)
            .help("Write a new \(kind.rawValue) part that fits the other tracks")
        }
        .padding(10)
        .frame(height: 76)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct ToggleChip: View {
    let label: String
    @Binding var isOn: Bool
    let tint: Color

    var body: some View {
        Button { isOn.toggle() } label: {
            Text(label)
                .font(.caption.bold())
                .frame(width: 24, height: 22)
                .foregroundStyle(isOn ? Color.black : Color.secondary)
                .background(isOn ? tint : Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
    }
}

/// The track's notes drawn as a miniature piano roll with a playhead. Click or drag to seek.
private struct NoteOverview: View {
    let notes: [Note]
    let seconds: Double
    let position: Double
    let color: Color
    let onSeek: (Double) -> Void

    var body: some View {
        GeometryReader { geo in
            Canvas { context, size in
                guard !notes.isEmpty, seconds > 0 else { return }
                let low = notes.map(\.pitch).min()!
                let high = max(notes.map(\.pitch).max()!, low + 11)
                let rows = Double(high - low + 1)
                let rowHeight = max(size.height / rows, 1.5)
                for note in notes {
                    let x = note.start / seconds * size.width
                    let width = max(note.duration / seconds * size.width, 1.5)
                    let y = size.height - (Double(note.pitch - low) + 1) / rows * size.height
                    context.fill(
                        Path(CGRect(x: x, y: y, width: width, height: rowHeight)),
                        with: .color(color))
                }
            }
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(Color.primary.opacity(0.7))
                    .frame(width: 1)
                    .offset(x: min(position / max(seconds, 0.01), 1) * geo.size.width)
            }
            .overlay {
                if notes.isEmpty {
                    Text("No notes").font(.caption).foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                onSeek(min(max(drag.location.x / geo.size.width, 0), 1) * seconds)
            })
        }
        .padding(4)
        .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 6))
    }
}
