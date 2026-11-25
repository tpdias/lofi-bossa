#if os(iOS)
import SwiftUI

/// The project on iPad: the Mac stage, touch-sized (HANDOFF §4, artboards "iPad · …").
///
/// - Toolbar: project name (tap to rename) with "Style · length · Version N · Saved", Undo, Redo,
///   Export, inspector toggle. Keyboard hints are not drawn; with a hardware keyboard the same
///   shortcuts come from `AppCommands` (hold ⌘ to list them).
/// - Inspector (Sound, Versions) is a 320 pt column when the window is at least 1100 pt wide; in
///   portrait or a narrow window it starts hidden and the toggle slides it over the stage from the
///   trailing edge. The Model popup leaves the recipe bar at the same width, as on a narrow Mac.
/// - While the piano roll is open the inspector hides to give the roll its width.
struct PadProjectView: View {
    @Bindable var model: ProjectViewModel

    /// The user's choice; nil follows the width (shown when wide, hidden when narrow).
    @State private var inspectorChoice: Bool?
    @State private var width: CGFloat = LFBDevice.ipad11.width
    @State private var showExport = false
    @State private var showLog = false
    @State private var renaming = false
    @State private var draftName = ""

    static let wideBreakpoint: CGFloat = 1100

    private var isWide: Bool { width >= Self.wideBreakpoint }
    private var inspectorShown: Bool { !model.isPianoRollOpen && (inspectorChoice ?? isWide) }
    private var snapshot: SongSnapshot? { model.displayedSnapshot }

    var body: some View {
        HStack(spacing: 0) {
            stage
            if inspectorShown && isWide {
                Divider()
                inspector
            }
        }
        .overlay(alignment: .trailing) {
            if inspectorShown && !isWide {
                ZStack(alignment: .trailing) {
                    Color.black.opacity(0.12)
                        .onTapGesture { withAnimation(.snappy) { inspectorChoice = false } }
                        .accessibilityLabel("Close Inspector")
                        .accessibilityAddTraits(.isButton)
                    inspector
                        .clipShape(UnevenRoundedRectangle(topLeadingRadius: LFBRadius.card, bottomLeadingRadius: LFBRadius.card))
                        .shadow(color: .black.opacity(0.2), radius: 16, x: -4)
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width = $0 }
        .onChange(of: isWide) { _, _ in inspectorChoice = nil }   // rotating starts from the default again
        .background(Color.lfbWindow)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .focusedSceneValue(\.projectModel, model)   // lets the hardware-keyboard commands act on this project
        .onReceive(NotificationCenter.default.publisher(for: .lfbExport)) { _ in
            if snapshot != nil { showExport = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: .lfbToggleInspector)) { _ in toggleInspector() }
        .sheet(isPresented: $showExport) { PadExportSheet(model: model) }
        .sheet(isPresented: $showLog) { PadLogSheet(log: model.generator.fullLog) }
        .alert("Rename Project", isPresented: $renaming) {
            TextField("Name", text: $draftName)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { model.rename(to: draftName) }
        }
    }

    private func toggleInspector() {
        withAnimation(.snappy) { inspectorChoice = !inspectorShown }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Button {
                draftName = model.project.name
                renaming = true
            } label: {
                VStack(spacing: 0) {
                    Text(model.project.name).font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.lfbText).lineLimit(1)
                    Text(subtitle).font(.system(size: 12, weight: .medium)).foregroundStyle(Color.lfbTextSecondary)
                        .lineLimit(1)
                        .accessibilityIdentifier("project-subtitle")
                }
                .padding(.horizontal, LFBSpace.md)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Rename the project")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button(action: model.undo) { Image(systemName: "arrow.uturn.backward") }
                .disabled(!model.canUndo)
                .accessibilityLabel(model.undoTitle.map { L("Undo \($0)") } ?? L("Undo"))
            Button(action: model.redo) { Image(systemName: "arrow.uturn.forward") }
                .disabled(!model.canRedo)
                .accessibilityLabel(model.redoTitle.map { L("Redo \($0)") } ?? L("Redo"))
            Button { showExport = true } label: { Label("Export", systemImage: "square.and.arrow.up") }
                .labelStyle(.titleAndIcon)
                .disabled(snapshot == nil || model.isGenerating)
                .accessibilityIdentifier("export")
            Button(action: toggleInspector) { Image(systemName: "sidebar.trailing") }
                .disabled(model.isPianoRollOpen)
                .accessibilityLabel(inspectorShown ? L("Hide Inspector") : L("Show Inspector"))
                .accessibilityIdentifier("inspector-toggle")
        }
    }

    private var subtitle: String {
        let version = model.project.current.map { L("Version \($0.number)") }
        guard let version else { return L("\(model.project.style.title) · not generated yet") }
        return L("\(model.project.style.title) · \(formatTimecode(model.project.lengthSeconds)) · \(version) · Saved")
    }

    // MARK: Stage

    private var stage: some View {
        VStack(spacing: 0) {
            PadRecipeBar(model: model, showsModel: isWide)
            Divider()
            banner
            if let snapshot {
                if model.isListeningToPastVersion, let version = model.listeningVersion {
                    PadListeningBanner(version: version, onBack: model.backToCurrentVersion,
                                       onRestore: model.restoreListeningVersion)
                }
                PadTracksView(model: model, snapshot: snapshot)
            } else {
                PadEmptyProjectView(model: model)
            }
            Divider()
            PadTransportBar(model: model)
        }
        .frame(maxWidth: .infinity)
    }

    private var inspector: some View {
        InspectorView(model: model)
            .frame(width: LFBTouchSize.inspectorWidth)
            .frame(maxHeight: .infinity)
            .background(Color.lfbSurface)
    }

    @ViewBuilder private var banner: some View {
        switch model.status {
        case .starting where snapshot == nil: EmptyView()   // the empty-project card explains it
        case .starting: StartingBanner()
        case .offline(let reason):
            OfflineBanner(reason: reason, onRestart: { Task { try? await model.generator.restart() } },
                          onShowLog: { showLog = true })
        case .ready:
            switch model.phase {
            case .generating(let startedAt, let seed):
                GeneratingBanner(style: model.project.style, length: model.project.lengthSeconds,
                                 seed: seed, startedAt: startedAt, onCancel: model.cancelGenerate)
            case .failed(let message, let detail, let trackScope) where trackScope == nil:
                GenerationErrorBanner(message: message, detail: detail, onRetry: { model.dismissError(); model.generate() })
            default: EmptyView()
            }
        }
    }
}

// MARK: - Listening banner

struct PadListeningBanner: View {
    let version: Version
    let onBack: () -> Void
    let onRestore: () -> Void

    var body: some View {
        BannerView(tint: .lfbAccent) {
            Image(systemName: "waveform").foregroundStyle(Color.lfbAccent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Listening to version \(version.number).").font(.lfbBodyMedium)
                Text(version.kind.title).font(.lfbCaption).foregroundStyle(Color.lfbTextSecondary)
            }
            Spacer()
            Button("Back to Current", action: onBack)
                .buttonStyle(.bordered)
            Button("Restore This Version", action: onRestore)
                .buttonStyle(.borderedProminent)
        }
    }
}

// MARK: - Generator log

/// "Show Log" on iOS: the generator's output in a sheet, with Copy.
struct PadLogSheet: View {
    let log: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(log.isEmpty ? L("No output yet.") : log)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(log.isEmpty ? Color.lfbTextSecondary : Color.lfbText)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(LFBSpace.lg)
            }
            .navigationTitle("Generator Log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Copy") { Pasteboard.copy(log) }.disabled(log.isEmpty)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
#endif
