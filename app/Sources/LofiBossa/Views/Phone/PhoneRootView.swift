import SwiftUI

#if os(iOS)
/// iPhone, iPhone Duo closed and narrow iPad Split View (docs/design/HANDOFF.md §5).
///
/// A NavigationStack: the library (or the first-launch welcome) at the root, the project screen
/// pushed when `AppSession.selection` points at a project, and the piano roll pushed from there.
/// Everything lives in `AppSession` / `ProjectViewModel`, so rotating or unfolding never loses
/// the open project, playback or a generation in progress.
struct PhoneRootView: View {
    @Environment(AppSession.self) private var session
    /// Set by the library's "Export…" so the project opens with the Export sheet up.
    @State private var exportOnOpen = false

    var body: some View {
        NavigationStack {
            PhoneLibraryView(exportOnOpen: $exportOnOpen)
                .navigationDestination(isPresented: projectIsOpen) {
                    if let model = session.activeModel {
                        PhoneProjectView(model: model, exportOnOpen: $exportOnOpen)
                            .id(model.project.id)
                    } else {
                        ProgressView()
                    }
                }
        }
        .tint(Color.lfbAccent)
        .onAppear { PhoneOrientation.set(.portrait) }
        .onDisappear { PhoneOrientation.set(.all) }   // e.g. an iPad leaving narrow Split View
    }

    private var projectIsOpen: Binding<Bool> {
        Binding(
            get: { if case .project = session.selection { true } else { false } },
            set: { open in
                if !open, case .project = session.selection {
                    session.activeModel?.pause()
                    session.selection = .allProjects
                }
            })
    }
}
#endif
