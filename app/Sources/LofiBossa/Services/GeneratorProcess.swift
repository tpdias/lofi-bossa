import Foundation

#if os(macOS)

/// Launches and supervises the local Python generator (`training/server.py`) as a child
/// process, so the app does not depend on the user starting it by hand in a terminal.
///
/// The repo root is found from `#filePath` of this very file, resolved at compile time to its
/// absolute path on the machine that built the app. That is safe here only because this app
/// is built and run on one person's own Mac, straight from the checkout: it is never
/// distributed, so "the path where it happened to be built" and "the path where it runs" are
/// always the same machine and (for `swift run`) usually the same checkout. If this ever
/// becomes a distributed app, replace this with a bundled resource or a user-chosen location.
@MainActor
final class GeneratorProcess {
    private(set) var isRunning = false
    private(set) var recentLog: [String] = []
    private var process: Process?
    private var failureStreak = 0

    static let repoRoot: URL = {
        // Services/GeneratorProcess.swift -> Services -> LofiBossa -> Sources -> app -> repo root
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }()
    private static let pythonPath = repoRoot.appendingPathComponent(".venv/bin/python")
    private static let serverScript = repoRoot.appendingPathComponent("training/server.py")

    var isAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: Self.pythonPath.path) &&
        FileManager.default.fileExists(atPath: Self.serverScript.path)
    }

    /// Starts the server if it is not already running under this GeneratorProcess. Does nothing
    /// (and is not an error) if a server is already answering on the port, whoever started it.
    func start() {
        guard !isRunning, isAvailable else { return }
        let process = Process()
        process.executableURL = Self.pythonPath
        process.arguments = [Self.serverScript.path]
        process.currentDirectoryURL = Self.repoRoot
        process.environment = ProcessInfo.processInfo.environment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            // Empty data means the child closed its output (it exited). Left installed, the
            // handler would then fire again immediately, forever, pinning a CPU core.
            if data.isEmpty { handle.readabilityHandler = nil; return }
            guard let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in self?.append(log: text) }
        }
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                self?.isRunning = false
                self?.failureStreak += 1
            }
        }

        do {
            try process.run()
            self.process = process
            isRunning = true
        } catch {
            append(log: "Could not launch the generator: \(error.localizedDescription)")
            failureStreak += 1
        }
    }

    func stop() {
        process?.terminationHandler = nil
        process?.interrupt()
        process = nil
        isRunning = false
    }

    /// Stops and starts again, as "Restart generator" in the offline banner.
    func restart() {
        stop()
        failureStreak = 0
        recentLog.removeAll()
        start()
    }

    /// The offline banner shows this after two failed launches in a row.
    var hasFailedRepeatedly: Bool { failureStreak >= 2 }
    var lastLogLine: String? { recentLog.last(where: { !$0.isEmpty }) }
    var fullLog: String { recentLog.joined(separator: "\n") }

    private func append(log text: String) {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            recentLog.append(String(line))
        }
        if recentLog.count > 200 { recentLog.removeFirst(recentLog.count - 200) }
    }
}

#else

/// iOS cannot launch a helper process, so there is no local Python server to supervise. This
/// stub keeps `LocalGeneratorClient` compiling (it can still reach a server someone else
/// started, e.g. the Mac's own, from the Simulator with `--local-generator`); the app's iOS
/// default is `OnDeviceGeneratorClient`.
@MainActor
final class GeneratorProcess {
    let isRunning = false
    let recentLog: [String] = []
    var isAvailable: Bool { false }
    func start() {}
    func stop() {}
    func restart() {}
    var hasFailedRepeatedly: Bool { false }
    var lastLogLine: String? { nil }
    var fullLog: String { "" }
}

#endif
