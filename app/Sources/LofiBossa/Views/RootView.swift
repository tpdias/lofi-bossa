import SwiftUI

/// The regular layout (Mac, iPad): library when the sidebar points at "All Projects" or
/// "Recently Deleted", otherwise the open project. The generator, the selection and the open
/// project's view model live in `AppSession`, above the layout switch.
struct RootView: View {
    @Environment(ProjectStore.self) private var store
    @Environment(AppSession.self) private var session
    @State private var showInspector: Bool
    @State private var showShortcuts = false

    /// On compact width `.inspector` becomes a sheet, so the phone placeholder starts with it closed.
    init(showsInspectorInitially: Bool = true) {
        _showInspector = State(initialValue: showsInspectorInitially)
    }

    var body: some View {
        @Bindable var session = session
        NavigationSplitView {
            SidebarView(selection: $session.selection)
        } detail: {
            detail
        }
        .onReceive(NotificationCenter.default.publisher(for: .lfbToggleInspector)) { _ in showInspector.toggle() }
        .onReceive(NotificationCenter.default.publisher(for: .lfbShowShortcuts)) { _ in showShortcuts = true }
        .sheet(isPresented: $showShortcuts) { ShortcutsSheet() }
    }

    @ViewBuilder private var detail: some View {
        switch session.selection {
        case .allProjects:
            LibraryGridView(isTrash: false, status: session.generator.currentStatus, onOpen: session.open)
        case .recentlyDeleted:
            LibraryGridView(isTrash: true, onOpen: session.open)
        case .project(let id):
            if let model = session.activeModel, model.project.id == id {
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
}
