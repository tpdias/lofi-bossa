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
    enum SaveState: Equatable { case saved, saving, failed(String) }

    static let trashRetentionDays = 30

    private(set) var projects: [Project] = []
    private(set) var saveState: SaveState = .saved
    private var pending: [Project.ID: Task<Void, Never>] = [:]
    private var unsaved: [Project.ID: Project] = [:]   // latest value behind each pending debounce

    private let root: URL = {
        // `--data-dir PATH` keeps a test run out of the real library (the dev flags create
        // projects, and nothing should ever have to delete the real folder to get a clean start).
        let args = CommandLine.arguments
        if let flag = args.firstIndex(of: "--data-dir"), args.count > flag + 1 {
            return URL(fileURLWithPath: args[flag + 1], isDirectory: true).appendingPathComponent("Projects", isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("LoFiBossa/Projects", isDirectory: true)
    }()

    /// Not deleted, newest-edited first by default (callers may re-sort for the library view).
    var active: [Project] { projects.filter { $0.deletedAt == nil } }
    /// In Recently Deleted, most recently deleted first.
    var trashed: [Project] {
        let deleted: [Project] = projects.filter { $0.deletedAt != nil }
        return deleted.sorted { (a: Project, b: Project) -> Bool in
            let aDate: Date = a.deletedAt ?? .distantPast
            let bDate: Date = b.deletedAt ?? .distantPast
            return aDate > bDate
        }
    }
    var recent: [Project] { Array(active.sorted { $0.modifiedAt > $1.modifiedAt }.prefix(6)) }

    func load() {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        projects = dirs.compactMap { dir in
            (try? Data(contentsOf: dir.appendingPathComponent("project.json")))
                .flatMap { try? decoder.decode(Project.self, from: $0) }
        }.sorted { $0.modifiedAt > $1.modifiedAt }
        purgeExpiredTrash()
    }

    @discardableResult
    func create(name: String? = nil, style: MusicStyle = .lofi) -> Project {
        var p = Project(name: name ?? nextUntitledName())
        p.style = style
        projects.insert(p, at: 0)
        touch(p)
        return p
    }

    @discardableResult
    func duplicate(_ p: Project) -> Project {
        var copy = p
        copy.id = UUID(); copy.name = p.name + " Copy"; copy.createdAt = .now; copy.modifiedAt = .now
        copy.deletedAt = nil
        projects.insert(copy, at: 0); touch(copy)
        return copy
    }

    func update(_ p: Project) {
        guard let i = projects.firstIndex(where: { $0.id == p.id }) else { return }
        var updated = p; updated.modifiedAt = .now
        projects[i] = updated
        touch(updated)
    }

    func rename(_ p: Project, to name: String) {
        var updated = p
        updated.name = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? p.name : name.trimmingCharacters(in: .whitespacesAndNewlines)
        update(updated)
    }

    /// Moves to Recently Deleted. No confirmation needed for this step; only permanent
    /// deletion asks for confirmation (handled by the caller, in the UI layer).
    func moveToTrash(_ p: Project) {
        var updated = p
        updated.deletedAt = .now
        update(updated)
    }

    func restoreFromTrash(_ p: Project) {
        var updated = p
        updated.deletedAt = nil
        update(updated)
    }

    func permanentlyDelete(_ p: Project) {
        projects.removeAll { $0.id == p.id }
        pending[p.id]?.cancel()
        pending[p.id] = nil
        let dir = root.appendingPathComponent(p.id.uuidString, isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
    }

    private func purgeExpiredTrash() {
        let cutoff = Calendar.current.date(byAdding: .day, value: -Self.trashRetentionDays, to: .now)!
        for p in projects where (p.deletedAt ?? .distantFuture) < cutoff {
            permanentlyDelete(p)
        }
    }

    private func nextUntitledName() -> String {
        let used = Set(projects.map(\.name))
        var n = 1
        while used.contains("Untitled Track \(n)") { n += 1 }
        return "Untitled Track \(n)"
    }

    private func touch(_ p: Project) {
        saveState = .saving
        unsaved[p.id] = p
        pending[p.id]?.cancel()
        pending[p.id] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            self?.writeNow(p)
        }
    }

    private func writeNow(_ p: Project) {
        do {
            let dir = root.appendingPathComponent(p.id.uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(p).write(to: dir.appendingPathComponent("project.json"), options: .atomic)
            saveState = .saved
        } catch {
            saveState = .failed(error.localizedDescription)
        }
        unsaved[p.id] = nil
        pending[p.id] = nil
    }

    /// Writes every debounced edit immediately, bypassing the 800 ms wait. Called when the
    /// app is about to quit, so an edit made just before Cmd-Q is never lost.
    func flushPendingSaves() {
        for (id, task) in pending {
            task.cancel()
            if let p = unsaved[id] { writeNow(p) }
        }
    }
}
