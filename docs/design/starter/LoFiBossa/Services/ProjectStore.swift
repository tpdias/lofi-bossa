import Foundation
import Observation

/// Autosave project store. Single-window app: there is no Save command.
///
/// - One folder per project under Application Support/LoFiBossa/Projects/<uuid>/project.json
///   (a folder leaves room for audio caches and thumbnails later).
/// - Every mutation calls `touch(_:)`; writes are debounced by 800 ms and written atomically.
/// - Window title subtitle shows "Saved" or "Saving…" from `saveState`.
/// - Delete moves a project to Recently Deleted (30 days) before it is really removed.
@MainActor @Observable
final class ProjectStore {
    enum SaveState { case saved, saving, failed(String) }

    private(set) var projects: [Project] = []
    private(set) var saveState: SaveState = .saved
    private var pending: [Project.ID: Task<Void, Never>] = [:]

    private let root: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("LoFiBossa/Projects", isDirectory: true)
    }()

    func load() {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        projects = dirs.compactMap { dir in
            (try? Data(contentsOf: dir.appendingPathComponent("project.json")))
                .flatMap { try? decoder.decode(Project.self, from: $0) }
        }.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    func create(name: String = "Untitled Track") -> Project {
        let p = Project(name: name)
        projects.insert(p, at: 0)
        touch(p)
        return p
    }

    func duplicate(_ p: Project) -> Project {
        var copy = p; copy.id = UUID(); copy.name = p.name + " Copy"; copy.createdAt = .now; copy.modifiedAt = .now
        projects.insert(copy, at: 0); touch(copy)
        return copy
    }

    func update(_ p: Project) {
        guard let i = projects.firstIndex(where: { $0.id == p.id }) else { return }
        var updated = p; updated.modifiedAt = .now
        projects[i] = updated
        touch(updated)
    }

    private func touch(_ p: Project) {
        saveState = .saving
        pending[p.id]?.cancel()
        pending[p.id] = Task { [root] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            do {
                let dir = root.appendingPathComponent(p.id.uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
                try encoder.encode(p).write(to: dir.appendingPathComponent("project.json"), options: .atomic)
                await MainActor.run { self.saveState = .saved }
            } catch {
                await MainActor.run { self.saveState = .failed(error.localizedDescription) }
            }
        }
    }
}
