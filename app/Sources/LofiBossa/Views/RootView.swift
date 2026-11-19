import SwiftUI

/// Library when the sidebar points at "All Projects" or "Recently Deleted", otherwise the
/// open project. One shared GeneratorClient for the app's lifetime (it owns the one generator
/// process); one ProjectViewModel for whichever project is currently open.
struct RootView: View {
    @Environment(ProjectStore.self) private var store
    /// `--fake-generator` swaps the model server for an instant fake, so UI tests need no Python.
    @State private var generator: any GeneratorClient =
        CommandLine.arguments.contains("--fake-generator") ? FakeGeneratorClient() : LocalGeneratorClient()
    @State private var selection: SidebarSelection = .allProjects
    @State private var activeModel: ProjectViewModel?
    @State private var showInspector = true
    @State private var showShortcuts = false

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selection)
        } detail: {
            detail
        }
        .onAppear {
            syncActiveModel()
            // `--demo [style]` creates a project and generates, exactly as the UI would,
            // so this build's core flow can be checked (and screenshotted) without clicking.
            if let flag = CommandLine.arguments.firstIndex(of: "--demo") {
                let args = CommandLine.arguments
                let style = args.count > flag + 1 ? (MusicStyle(rawValue: args[flag + 1]) ?? .lofi) : .lofi
                let length = args.count > flag + 2 ? (Double(args[flag + 2]) ?? 90) : 90
                var project = store.create(style: style)
                project.lengthSeconds = length
                store.update(project)
                selection = .project(project.id)
                syncActiveModel()
                activeModel?.generate()
                if args.contains("--sections") {
                    Task {
                        while activeModel?.isGeneratorBusy == true || activeModel?.project.currentSnapshot == nil {
                            try? await Task.sleep(for: .milliseconds(300))
                        }
                        if let model = activeModel { await DevTools.runSectionDemo(model) }
                    }
                }
                if args.contains("--editor") {
                    Task {
                        while activeModel?.isGeneratorBusy == true { try? await Task.sleep(for: .milliseconds(300)) }
                        activeModel?.openEditor(for: .guitar)
                    }
                }
            }
        }
        .onChange(of: selection) { syncActiveModel() }
        .onReceive(NotificationCenter.default.publisher(for: .lfbNewProject)) { _ in
            selection = .project(store.create().id)
        }
        .onReceive(NotificationCenter.default.publisher(for: .lfbGenerate)) { _ in activeModel?.generate() }
        .onReceive(NotificationCenter.default.publisher(for: .lfbCopySeed)) { _ in activeModel?.copySeedToPasteboard() }
        .onReceive(NotificationCenter.default.publisher(for: .lfbToggleLoop)) { _ in activeModel?.toggleLoop() }
        .onReceive(NotificationCenter.default.publisher(for: .lfbToggleInspector)) { _ in showInspector.toggle() }
        .onReceive(NotificationCenter.default.publisher(for: .lfbShowShortcuts)) { _ in showShortcuts = true }
        .sheet(isPresented: $showShortcuts) { ShortcutsSheet() }
    }

    @ViewBuilder private var detail: some View {
        switch selection {
        case .allProjects:
            LibraryGridView(isTrash: false, status: generator.currentStatus, onOpen: open)
        case .recentlyDeleted:
            LibraryGridView(isTrash: true, onOpen: open)
        case .project(let id):
            if let model = activeModel, model.project.id == id {
                ProjectStageView(model: model, showInspector: $showInspector)
                    .inspector(isPresented: $showInspector) {
                        InspectorView(model: model)
                            .inspectorColumnWidth(min: 240, ideal: LFBSize.inspectorWidth, max: 340)
                    }
                    .id(id)   // fresh toolbar/focus state when switching projects
            } else {
                ProgressView()
            }
        }
    }

    private func open(_ project: Project) { selection = .project(project.id) }

    private func syncActiveModel() {
        guard case .project(let id) = selection,
              let project = store.projects.first(where: { $0.id == id }) else {
            activeModel = nil
            return
        }
        if activeModel?.project.id != id {
            activeModel?.teardown()
            activeModel = ProjectViewModel(project: project, store: store, generator: generator)
        }
    }
}
