import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            GenerateBar()
            Divider()
            if state.song == nil {
                emptyState
            } else {
                VStack(spacing: 10) {
                    ForEach(TrackKind.allCases) { TrackRow(kind: $0) }
                }
                .padding(16)
                .frame(maxHeight: .infinity, alignment: .top)
            }
            if let error = state.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }
            Divider()
            BottomBar()
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "music.quarternote.3")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text(state.busy == .generating ? "Writing your track…" : "Pick a style and length, then Generate")
                .foregroundStyle(.secondary)
            if !state.serverUp {
                Text("Generator not running. Start it with:  .venv/bin/python training/server.py")
                    .font(.callout.monospaced())
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct GenerateBar: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        HStack(spacing: 16) {
            Picker("Style", selection: $state.style) {
                ForEach(Style.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            HStack(spacing: 8) {
                Text("Length")
                    .foregroundStyle(.secondary)
                    .fixedSize()
                Slider(value: $state.seconds, in: 15...180, step: 15)
                    .frame(width: 150)
                Text(timecode(state.seconds))
                    .monospacedDigit()
                    .frame(width: 36, alignment: .leading)
            }

            Button {
                Task { await state.generate() }
            } label: {
                HStack(spacing: 6) {
                    if state.busy == .generating {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "sparkles")
                    }
                    Text(state.busy == .generating ? "Generating…" : "Generate")
                }
                .frame(minWidth: 110)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("g")
            .disabled(state.busy != nil || !state.serverUp)

            Spacer()

            HStack(spacing: 6) {
                Circle()
                    .fill(state.serverUp ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                Text(state.serverUp ? "Generator ready" : "Generator offline")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

private struct BottomBar: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        HStack(spacing: 18) {
            Button(action: state.togglePlay) {
                Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .frame(width: 28, height: 22)
            }
            .keyboardShortcut(.space, modifiers: [])
            .disabled(state.song == nil)
            .help(state.isPlaying ? "Pause" : "Play")

            Text("\(timecode(state.position)) / \(timecode(state.song?.seconds ?? 0))")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .leading)

            Divider().frame(height: 24)

            EffectSlider(title: "Warmth", value: $state.effects.warmth)
            EffectSlider(title: "Reverb", value: $state.effects.reverb)
            EffectSlider(title: "Vinyl", value: $state.effects.vinyl)

            Spacer()

            if state.undoSong != nil {
                Button("Undo Regenerate", action: state.undo)
                    .keyboardShortcut("z")
            }
            Menu("Export") {
                ForEach(AppState.ExportKind.allCases, id: \.self) { kind in
                    Button(kind.rawValue) { state.export(kind) }
                }
            }
            .fixedSize()
            .disabled(state.song == nil || state.busy != nil)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

private struct EffectSlider: View {
    let title: String
    @Binding var value: Double

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
            Slider(value: $value, in: 0...1)
                .controlSize(.small)
                .frame(width: 80)
        }
    }
}

func timecode(_ seconds: Double) -> String {
    let total = Int(seconds.rounded(.down))
    return String(format: "%d:%02d", total / 60, total % 60)
}
