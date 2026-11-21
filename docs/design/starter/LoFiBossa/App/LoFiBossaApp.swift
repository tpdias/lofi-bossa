import SwiftUI

/// One multiplatform target: macOS 14+, iPadOS and iOS (iPhone and iPhone Duo).
/// All devices have the same features; only the layout changes (see LayoutMode).
@main
struct LoFiBossaApp: App {
    @State private var store = ProjectStore()
    @State private var selection: Project.ID?

    var body: some Scene {
        WindowGroup {
            AdaptiveRootView(selection: $selection)
                .environment(store)
                #if os(macOS)
                .frame(minWidth: LFBSize.minWindow.width, minHeight: LFBSize.minWindow.height)
                #endif
                .task { store.load() }
        }
        #if os(macOS)
        .windowToolbarStyle(.unified)
        #endif
        .commands {
            // Shown in the Mac menu bar and in the iPad's hardware-keyboard shortcut list.
            CommandGroup(replacing: .newItem) {
                Button("New Project") { selection = store.create().id }.keyboardShortcut("n")
            }
            CommandMenu("Song") {
                Button("Generate New Take") { /* forward to the active ProjectSession */ }.keyboardShortcut(.return, modifiers: .command)
                Button("Rewrite Selected Track") {}.keyboardShortcut("r", modifiers: .command)
                Divider()
                Button("Copy Seed") {}.keyboardShortcut("c", modifiers: [.command, .shift])
                Button("Loop Selection") {}.keyboardShortcut("l", modifiers: .command)
                Divider()
                Button("Export…") {}.keyboardShortcut("e", modifiers: .command)
            }
        }
    }
}

/// Picks the layout. The ProjectSession is created above this switch, so changing layout
/// (unfolding a Duo, rotating, resizing a window, entering Split View) keeps playback,
/// selection and any generation in progress.
struct AdaptiveRootView: View {
    @Binding var selection: Project.ID?

    var body: some View {
        LayoutModeReader { mode in
            switch mode {
            case .regular:
                RootView(selection: $selection)
            #if os(iOS)
            case .compact:
                NavigationStack { Text("Library") }   // LibraryGrid (2 columns) → PhoneProjectView
            case .twoPage:
                Text("Library | Project")              // left: project list; right: preview. Open → TwoPageProjectView
            case .tabletop:
                Text("Tabletop")                       // TabletopProjectView for the open project
            #else
            default:
                RootView(selection: $selection)
            #endif
            }
        }
    }
}

/// Mac and iPad: sidebar, stage, inspector. On iPad the sidebar starts hidden while a project is open,
/// controls use the touch sizes in LFBSize, and the piano roll accepts Apple Pencil.
struct RootView: View {
    @Environment(ProjectStore.self) private var store
    @Binding var selection: Project.ID?
    @State private var showInspector = true

    var body: some View {
        NavigationSplitView {
            List(store.projects, selection: $selection) { p in
                Label(p.name, systemImage: "music.note")
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: LFBSize.isTouch ? 300 : 216, max: 320)
        } detail: {
            if let id = selection, let project = store.projects.first(where: { $0.id == id }) {
                ProjectView(project: project)
                    .inspector(isPresented: $showInspector) {
                        // PanelView(session:, panels: [.sound, .versions])
                        Text("Inspector").inspectorColumnWidth(min: 240, ideal: LFBSize.inspectorWidth, max: 360)
                    }
            } else {
                ContentUnavailableView("Make your first track", systemImage: "music.note")
            }
        }
    }
}

/// Stage: recipe bar, banner, ruler, four TrackRowViews (or compact rows + piano roll), transport.
struct ProjectView: View {
    let project: Project
    var body: some View {
        // Build from the "Project · loaded song" (Mac) and "iPad · Project" artboards.
        Text(project.name)
    }
}
