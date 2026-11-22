import Foundation
import Observation

/// App-wide state that sits above the layout switch (`AdaptiveRootView`), so changing layout
/// (rotating, resizing an iPad window, entering Split View, unfolding an iPhone Duo) never
/// recreates the generator or the open project: playback, selection and any generation in
/// progress carry across (docs/design/HANDOFF.md §2.3).
///
/// Every layout reads it with `@Environment(AppSession.self)`: `selection` says what is shown
/// (library, trash, or a project) and `activeModel` is the open project's view model.
@MainActor @Observable
final class AppSession {
    let store: ProjectStore
    /// One GeneratorClient for the app's lifetime (on the Mac it owns the one generator process).
    let generator: any GeneratorClient
    var selection: SidebarSelection = .allProjects {
        didSet { if selection != oldValue { syncActiveModel() } }
    }
    private(set) var activeModel: ProjectViewModel?

    init(store: ProjectStore, generator: (any GeneratorClient)? = nil) {
        self.store = store
        self.generator = generator ?? Self.defaultGenerator()
    }

    /// `--fake-generator` swaps the model for an instant fake on every platform, so UI tests and
    /// simulator checks need no Python and no model. Otherwise the Mac launches its local server;
    /// iOS uses the in-app engine (not ready yet, see OnDeviceGeneratorClient), or with
    /// `--local-generator` a server already running on the Mac (reachable from the Simulator).
    static func defaultGenerator() -> any GeneratorClient {
        let args = CommandLine.arguments
        if args.contains("--fake-generator") {
            let fake = FakeGeneratorClient()
            // `--fake-delay N`: each take takes N seconds, so the generating state can be looked at.
            if let i = args.firstIndex(of: "--fake-delay"), args.count > i + 1, let s = Double(args[i + 1]) {
                fake.delay = .seconds(s)
            }
            return fake
        }
        #if os(macOS)
        return LocalGeneratorClient()
        #else
        return args.contains("--local-generator") ? LocalGeneratorClient() : OnDeviceGeneratorClient()
        #endif
    }

    func open(_ project: Project) { selection = .project(project.id) }

    func newProject() { selection = .project(store.create().id) }

    /// Keeps `activeModel` matching `selection`: creates the view model when a project opens and
    /// tears the old one down when it closes.
    func syncActiveModel() {
        guard case .project(let id) = selection,
              let project = store.projects.first(where: { $0.id == id }) else {
            activeModel = nil   // as before on the Mac: no teardown when going back to the library
            return
        }
        if activeModel?.project.id != id {
            activeModel?.teardown()
            activeModel = ProjectViewModel(project: project, store: store, generator: generator)
        }
    }
}
