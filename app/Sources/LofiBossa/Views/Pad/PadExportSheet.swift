#if os(iOS)
import SwiftUI
import UniformTypeIdentifiers

/// Export on iPad (HANDOFF §4, §8): format and range, a determinate progress bar with Cancel,
/// then "Exported" with **Share…** (the system share sheet) and **Save to Files**. The file is
/// rendered to a temporary folder first; Save to Files moves a copy of it where the user picks.
struct PadExportSheet: View {
    @Bindable var model: ProjectViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var format: ProjectViewModel.ExportFormat = .m4a
    @State private var range: ProjectViewModel.ExportRange = .whole
    @State private var task: Task<Void, Never>?
    @State private var saveCopy: URL?
    @State private var savedToFiles = false
    @State private var showVideo = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: LFBSpace.lg) {
                if let result = model.exportResult, task == nil {
                    finished(result)
                } else if model.isExporting || task != nil {
                    exporting
                } else {
                    form
                }
                Spacer(minLength: 0)
            }
            .padding(LFBSpace.xl)
            .navigationTitle("Export")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(model.exportResult == nil ? "Cancel" : "Done") { cancelAndDismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .sheet(isPresented: $showVideo) { VideoSoundtrackSheet(model: model) }
        .fileMover(isPresented: Binding(get: { saveCopy != nil }, set: { if !$0 { saveCopy = nil } }),
                   file: saveCopy) { result in
            if case .success = result { savedToFiles = true }
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: LFBSpace.lg) {
            VStack(alignment: .leading, spacing: LFBSpace.sm) {
                Text("Format").font(.system(size: 15, weight: .medium))
                Picker("Format", selection: $format) {
                    ForEach(ProjectViewModel.ExportFormat.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
                Text(format.note).font(.footnote).foregroundStyle(Color.lfbTextSecondary)
            }
            VStack(alignment: .leading, spacing: LFBSpace.sm) {
                Text("Range").font(.system(size: 15, weight: .medium))
                Picker("Range", selection: $range) {
                    ForEach(ProjectViewModel.ExportRange.allCases) { r in
                        Text(r.rawValue).tag(r)
                    }
                }
                .pickerStyle(.segmented).labelsHidden()
                .disabled(!model.canExport(range: .loop))
                if !model.canExport(range: .loop) {
                    Text("Drag in the ruler to choose a loop range.").font(.footnote).foregroundStyle(Color.lfbTextSecondary)
                }
            }
            ExportOptionsSection(model: model, format: format)
            Button("Video soundtrack…") { showVideo = true }
            Button {
                guard let url = model.chooseExportDestination(format: format) else { return }
                let chosen = model.canExport(range: range) ? range : .whole
                task = Task {
                    await model.export(format: format, range: chosen, to: url)
                    task = nil
                }
            } label: {
                Text("Export").frame(maxWidth: .infinity, minHeight: 36)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("export-confirm")
        }
    }

    private var exporting: some View {
        VStack(alignment: .leading, spacing: LFBSpace.md) {
            Text("Rendering audio…").font(.lfbTitle)
            ProgressView(value: model.exportProgress)
            Button("Cancel", role: .cancel) { cancelAndDismiss() }
        }
    }

    private func finished(_ result: (url: URL, seconds: Double, bytes: Int64)) -> some View {
        VStack(alignment: .leading, spacing: LFBSpace.md) {
            Label("Exported", systemImage: "checkmark.circle.fill").font(.lfbTitle).foregroundStyle(Color.lfbReady)
            Text("\(result.url.lastPathComponent) · \(formatTimecode(result.seconds)) · "
                 + ByteCountFormatter.string(fromByteCount: result.bytes, countStyle: .file))
                .font(.system(size: 15)).foregroundStyle(Color.lfbTextSecondary)
            if savedToFiles {
                Label("Saved to Files", systemImage: "folder").font(.footnote).foregroundStyle(Color.lfbTextSecondary)
            }
            HStack(spacing: LFBSpace.md) {
                ShareLink(item: result.url) {
                    Label("Share…", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity, minHeight: 36)
                }
                .buttonStyle(.borderedProminent)
                Button { saveCopy = copyForFiles(result.url) } label: {
                    Label("Save to Files", systemImage: "folder").frame(maxWidth: .infinity, minHeight: 36)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    /// `fileMover` moves its file, so it gets a copy and the original stays shareable.
    private func copyForFiles(_ url: URL) -> URL? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let copy = dir.appendingPathComponent(url.lastPathComponent)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: url, to: copy)
            return copy
        } catch {
            return nil
        }
    }

    private func cancelAndDismiss() {
        task?.cancel()
        dismiss()
    }
}
#endif
