import SwiftUI

/// Export sheet: format, range, progress, finished. Rendering is offline and faster than
/// real time, so the sheet stays modal — no background export queue is needed.
struct ExportSheetView: View {
    @Bindable var model: ProjectViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var format: ProjectViewModel.ExportFormat = .m4a
    @State private var range: ProjectViewModel.ExportRange = .whole
    @State private var showVideo = false

    var body: some View {
        VStack(alignment: .leading, spacing: LFBSpace.lg) {
            if let result = model.exportResult {
                finished(result)
            } else if model.isExporting {
                exporting
            } else {
                form
            }
        }
        .padding(LFBSpace.xl)
        .frame(width: 440)
        .sheet(isPresented: $showVideo) { VideoSoundtrackSheet(model: model) }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: LFBSpace.lg) {
            Text("Export").font(.lfbTitle)

            VStack(alignment: .leading, spacing: LFBSpace.xs) {
                Text("Format").font(.lfbBodyMedium)
                Picker("Format", selection: $format) {
                    ForEach(ProjectViewModel.ExportFormat.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
                .accessibilityLabel("Format")
                Text(format.note).font(.lfbCaption).foregroundStyle(Color.lfbTextSecondary)
            }

            VStack(alignment: .leading, spacing: LFBSpace.xs) {
                Text("Range").font(.lfbBodyMedium)
                Picker("Range", selection: $range) {
                    ForEach(ProjectViewModel.ExportRange.allCases) { r in
                        Text(r.rawValue).tag(r).disabled(!model.canExport(range: r))
                    }
                }
                .pickerStyle(.segmented).labelsHidden()
                .accessibilityLabel("Range")
            }

            ExportOptionsSection(model: model, format: format)

            HStack {
                Button("Video soundtrack…") { showVideo = true }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Export") {
                    guard let url = model.chooseExportDestination(format: format) else { return }
                    Task { await model.export(format: format, range: range, to: url) }
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                .accessibilityHint("Chooses where to save, then renders the audio")
            }
        }
    }

    private var exporting: some View {
        VStack(alignment: .leading, spacing: LFBSpace.md) {
            Text("Rendering audio…").font(.lfbTitle)
            ProgressView(value: model.exportProgress)
                .accessibilityLabel("Export progress")
                .accessibilityValue("\(Int(model.exportProgress * 100)) percent")
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
            }
        }
    }

    private func finished(_ result: (url: URL, seconds: Double, bytes: Int64)) -> some View {
        VStack(alignment: .leading, spacing: LFBSpace.md) {
            Label("Exported", systemImage: "checkmark.circle.fill").font(.lfbTitle).foregroundStyle(Color.lfbReady)
            Text("\(result.url.lastPathComponent) · \(formatTimecode(result.seconds)) · \(formatBytes(result.bytes))")
                .font(.lfbBody).foregroundStyle(Color.lfbTextSecondary)
            HStack {
                Spacer()
                #if os(macOS)
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([result.url]) }
                #else
                ShareLink("Share…", item: result.url)
                #endif
                Button("Done") { dismiss() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
    }
}

private func formatBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}
