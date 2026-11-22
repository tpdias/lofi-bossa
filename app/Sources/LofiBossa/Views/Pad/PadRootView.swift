#if os(iOS)
import SwiftUI

/// iPad (and any regular-width iOS window): the Mac layout, touch-sized (docs/design/HANDOFF.md §4).
///
/// - **Sidebar** (300 pt): pinned beside the library; hidden while a project is open, and the
///   toolbar button then shows it as an overlay so the lanes keep their width.
/// - **Library**: the shared grid (3 columns in landscape, a tap opens a card, long press for the
///   context menu).
/// - **Project**: `PadProjectView` (recipe bar, track rows, transport, inspector, piano roll).
///
/// Narrow Split View / Slide Over windows get the compact size class and never reach this view.
struct PadRootView: View {
    @Environment(AppSession.self) private var session
    @State private var sidebarShown = true
    @State private var showShortcuts = false

    private var isProjectOpen: Bool {
        if case .project = session.selection { return true }
        return false
    }

    var body: some View {
        @Bindable var session = session
        HStack(spacing: 0) {
            if sidebarShown && !isProjectOpen {
                sidebar(selection: $session.selection)
                    .transition(.move(edge: .leading))
                Divider()
            }
            NavigationStack {
                detail
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button {
                                withAnimation(.snappy) { sidebarShown.toggle() }
                            } label: {
                                Image(systemName: "sidebar.leading")
                            }
                            .accessibilityLabel(sidebarShown ? "Hide Projects" : "Show Projects")
                            .accessibilityIdentifier("pad-sidebar-toggle")
                        }
                    }
            }
        }
        .overlay(alignment: .leading) {
            // While a project is open the sidebar slides in over the stage instead of squeezing it.
            if sidebarShown && isProjectOpen {
                ZStack(alignment: .leading) {
                    Color.black.opacity(0.18).ignoresSafeArea()
                        .onTapGesture { withAnimation(.snappy) { sidebarShown = false } }
                        .accessibilityLabel("Close Projects")
                        .accessibilityAddTraits(.isButton)
                    sidebar(selection: $session.selection)
                        .shadow(color: .black.opacity(0.2), radius: 16, x: 4)
                }
                .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .background(Color.lfbWindow)
        .onChange(of: session.selection) { _, _ in
            withAnimation(.snappy) { sidebarShown = !isProjectOpen }
        }
        .onAppear { sidebarShown = !isProjectOpen }
        .onReceive(NotificationCenter.default.publisher(for: .lfbShowShortcuts)) { _ in showShortcuts = true }
        .sheet(isPresented: $showShortcuts) { ShortcutsSheet() }
    }

    private func sidebar(selection: Binding<SidebarSelection>) -> some View {
        SidebarView(selection: selection)
            .scrollContentBackground(.hidden)
            .background(Color.lfbSidebar.ignoresSafeArea())
            .frame(width: LFBTouchSize.sidebarWidth)
    }

    @ViewBuilder private var detail: some View {
        switch session.selection {
        case .allProjects:
            LibraryGridView(isTrash: false, status: session.generator.currentStatus, onOpen: session.open)
        case .recentlyDeleted:
            LibraryGridView(isTrash: true, onOpen: session.open)
        case .project(let id):
            if let model = session.activeModel, model.project.id == id {
                PadProjectView(model: model)
                    .id(id)   // fresh toolbar and focus state when switching projects
            } else {
                ProgressView()
            }
        }
    }
}
#endif
