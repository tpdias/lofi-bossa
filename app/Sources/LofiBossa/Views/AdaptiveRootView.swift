import SwiftUI

/// The root of every window on every platform. Picks the layout from `LayoutMode` (size class
/// and fold, never the device model); everything that must survive a layout change lives in
/// `AppSession` above this switch.
///
/// Seams for the layout work: each case hands off to one view in its own folder, so the iPhone,
/// iPad and iPhone Duo layouts can be built in parallel without touching each other's files.
/// - `.regular` on iOS → `Views/Pad/PadRootView.swift` (the Mac layout, touch-sized)
/// - `.compact` → `Views/Phone/PhoneRootView.swift`
/// - `.twoPage`, `.tabletop` → `Views/Duo/DuoRootView.swift`
/// The Mac always gets `.regular` and the unchanged `RootView`.
struct AdaptiveRootView: View {
    @Environment(AppSession.self) private var session

    var body: some View {
        LayoutModeReader { mode in
            switch mode {
            #if os(macOS)
            default:
                RootView()
            #else
            case .regular:
                PadRootView()
            case .compact:
                PhoneRootView()
            case .twoPage, .tabletop:
                DuoRootView(mode: mode)
            #endif
            }
        }
        .environment(\.lfbTheme, LFBTheme(session.activeModel?.project.style))
        .environment(\.noteClock, NoteClock { [weak session] in
            (session?.activeModel?.position ?? 0, session?.activeModel?.isPlaying ?? false)
        })
        .sheet(isPresented: Binding(get: { session.isCreatingProject }, set: { session.isCreatingProject = $0 })) {
            NewProjectFlow(onCancel: { session.isCreatingProject = false })
                .environment(session)
                .environment(session.store)
                #if os(iOS)
                .presentationSizing(.page)
                #endif
        }
        .onAppear { session.syncActiveModel(); DevTools.runDemoIfAsked(session) }
        .announcesProgress(of: session.activeModel)
        .hapticBeat(of: session.activeModel)
        // App-wide commands that the menus (Mac) and hardware-keyboard shortcuts (iPad) post.
        .onReceive(NotificationCenter.default.publisher(for: .lfbNewProject)) { _ in session.newProject() }
        .onReceive(NotificationCenter.default.publisher(for: .lfbGenerate)) { _ in session.activeModel?.generate() }
        .onReceive(NotificationCenter.default.publisher(for: .lfbCopySeed)) { _ in session.activeModel?.copySeedToPasteboard() }
        .onReceive(NotificationCenter.default.publisher(for: .lfbToggleLoop)) { _ in session.activeModel?.toggleLoop() }
    }
}
