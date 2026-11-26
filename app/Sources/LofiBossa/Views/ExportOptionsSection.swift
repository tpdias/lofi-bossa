import SwiftUI

/// Fade in, fade out and "seamless loop" for the audio exports, shared by the Mac, iPad and
/// iPhone export sheets. It edits `model.exportOptions`; nothing shows for MIDI.
struct ExportOptionsSection: View {
    @Bindable var model: ProjectViewModel
    let format: ProjectViewModel.ExportFormat

    var body: some View {
        if format != .midi {
            VStack(alignment: .leading, spacing: 8) {
                Text("Fades and loops").font(.system(size: 15, weight: .medium))
                Toggle("Seamless loop", isOn: $model.exportOptions.seamlessLoop)
                    .accessibilityIdentifier("export-seamless-loop")
                HStack {
                    fadePicker("Fade in", selection: $model.exportOptions.fadeIn)
                    fadePicker("Fade out", selection: $model.exportOptions.fadeOut)
                }
                .disabled(model.exportOptions.seamlessLoop)
                Text(model.exportOptions.seamlessLoop
                     ? "The ring-out after the last note is folded onto the start, so the file repeats with no gap or click. Fades are off."
                     : "Fades start from and end in silence.")
                    .font(.footnote).foregroundStyle(Color.lfbTextSecondary)
            }
        }
    }

    private func fadePicker(_ title: String, selection: Binding<Double>) -> some View {
        Picker(title, selection: selection) {
            ForEach(ExportOptions.fadeChoices, id: \.self) { s in
                Text(s == 0 ? "None" : "\(Int(s)) s").tag(s)
            }
        }
    }
}
