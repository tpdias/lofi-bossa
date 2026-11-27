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
    /// simulator checks need no Python and no model. Otherwise the app uses the model inside it
    /// (OnDeviceGeneratorClient) when the model files are present; the Mac falls back to
    /// launching its Python server, and iOS with `--local-generator` reaches a server already
    /// running on the Mac (from the Simulator).
    static func defaultGenerator() -> any GeneratorClient {
        let args = CommandLine.arguments
        if args.contains("--fake-generator") {
            let fake = FakeGeneratorClient()
            // `--fake-delay SECONDS` makes the fake take time, to look at the generating state.
            if let i = args.firstIndex(of: "--fake-delay"), args.count > i + 1, let s = Double(args[i + 1]) {
                fake.delay = .milliseconds(Int(s * 1000))
            }
            return fake
        }
        // The model inside the app when its files are there (bundled, or `--model-dir`);
        // `--server-generator` (Mac) / `--local-generator` (iOS Simulator) use the Python server.
        #if os(macOS)
        if args.contains("--server-generator") || !ModelFiles.isAvailable { return LocalGeneratorClient() }
        return OnDeviceGeneratorClient()
        #else
        return args.contains("--local-generator") ? LocalGeneratorClient() : OnDeviceGeneratorClient()
        #endif
    }

    func open(_ project: Project) { selection = .project(project.id) }

    /// Shows the New Project flow (style, then the song's settings) as a sheet on every layout.
    var isCreatingProject = false

    func newProject() { isCreatingProject = true }

    /// Makes the project the flow described and opens it; `generate` also starts its first take
    /// when the generator is ready (otherwise the project opens empty, ready for Generate).
    func createProject(from draft: ProjectDraft, generate: Bool) {
        let project = store.create(from: draft)
        isCreatingProject = false
        selection = .project(project.id)
        syncActiveModel()
        if generate, case .ready = generator.currentStatus { activeModel?.generate() }
    }

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
