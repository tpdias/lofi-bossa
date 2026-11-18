import AVFoundation
import SwiftUI

@main
enum Main {
    static func main() {
        let args = CommandLine.arguments
        if let flag = args.firstIndex(of: "--render"), args.count > flag + 3 {
            // Headless check of the audio path:  LofiBossa --render song.json lofi|bossa out.wav
            // `song.json` is the generator's wire format ({"seed","seconds","tracks": {...}}),
            // the same shape saved under processed/check/ earlier in this project.
            exit(DevTools.render(wireSongPath: args[flag + 1], style: args[flag + 2], output: args[flag + 3]))
        }
        if let flag = args.firstIndex(of: "--render-fx-popover"), args.count > flag + 1 {
            // Draws the per-track effects popover to a PNG (popovers are separate windows, so
            // --screenshot can't capture them).
            MainActor.assumeIsolated { DevTools.renderEffectsPopover(to: args[flag + 1]) }
            exit(0)
        }
        LoFiBossaApp.main()
    }
}

struct LoFiBossaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var store = ProjectStore()

    var body: some Scene {
        WindowGroup("Lo-Fi & Bossa") {
            RootView()
                .environment(store)
                .frame(minWidth: LFBSize.minWindow.width, minHeight: LFBSize.minWindow.height)
                .task {
                    store.load()
                    delegate.store = store   // so Cmd-Q can flush any edit still waiting to autosave
                }
        }
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Project") { NotificationCenter.default.post(name: .lfbNewProject, object: nil) }
                    .keyboardShortcut("n")
            }
            CommandMenu("Song") {
                Button("Generate New Take") { NotificationCenter.default.post(name: .lfbGenerate, object: nil) }
                    .keyboardShortcut(.return, modifiers: .command)
                Button("Copy Seed") { NotificationCenter.default.post(name: .lfbCopySeed, object: nil) }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                Button("Loop Selection") { NotificationCenter.default.post(name: .lfbToggleLoop, object: nil) }
                    .keyboardShortcut("l", modifiers: .command)
                Divider()
                Button("Export…") { NotificationCenter.default.post(name: .lfbExport, object: nil) }
                    .keyboardShortcut("e", modifiers: .command)
            }
        }
    }
}

extension Notification.Name {
    static let lfbNewProject = Notification.Name("lfbNewProject")
    static let lfbGenerate = Notification.Name("lfbGenerate")
    static let lfbCopySeed = Notification.Name("lfbCopySeed")
    static let lfbToggleLoop = Notification.Name("lfbToggleLoop")
    static let lfbExport = Notification.Name("lfbExport")
}

/// Run from `swift run` there is no app bundle, so ask for a normal Dock app and focus it.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var store: ProjectStore?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        let args = CommandLine.arguments

        // `--window WIDTHxHEIGHT` sets an exact frame, bypassing AppKit's restored-frame
        // state from a previous run (useful for deterministic --screenshot checks at, say,
        // the design's minimum width; a real user's window just keeps whatever size they left it).
        if let flag = args.firstIndex(of: "--window"), args.count > flag + 1 {
            let parts = args[flag + 1].split(separator: "x").compactMap { Double($0) }
            if parts.count == 2, let window = NSApp.windows.first(where: { $0.isVisible }) {
                window.setFrame(NSRect(x: window.frame.minX, y: window.frame.minY, width: parts[0], height: parts[1]), display: true)
            }
        }

        // `--hit-sweep` hit-tests the window point by point after it settles and prints each
        // point first, so if SwiftUI's hit testing crashes the last line says where.
        if args.contains("--hit-sweep") {
            let delay = Double(args.firstIndex(of: "--hit-sweep").flatMap { args.count > $0 + 1 ? args[$0 + 1] : nil } ?? "") ?? 25
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard let view = NSApp.windows.first(where: { $0.isVisible })?.contentView else { return }
                let b = view.bounds
                print("HITSWEEP start \(b.size)"); fflush(stdout)
                for y in stride(from: 3.0, to: b.height, by: 7) {
                    for x in stride(from: 3.0, to: b.width, by: 7) {
                        print("HITSWEEP \(Int(x)),\(Int(y))"); fflush(stdout)
                        _ = view.hitTest(NSPoint(x: x, y: y))
                    }
                }
                print("HITSWEEP done, no crash"); fflush(stdout)
            }
        }

        // `--screenshot out.png` saves a picture of the window and quits (used for the README
        // and for this build's own QA, since this session has no way to click inside the app).
        if let flag = args.firstIndex(of: "--screenshot"), args.count > flag + 1 {
            let delay = args.count > flag + 2 ? (Double(args[flag + 2]) ?? 2) : 2
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                Self.saveWindowImage(to: URL(fileURLWithPath: args[flag + 1]))
                NSApp.terminate(nil)
            }
        }
    }

    private static func saveWindowImage(to url: URL) {
        guard let window = NSApp.windows.first(where: { $0.isVisible }),
              let view = window.contentView?.superview ?? window.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            print("screenshot: no visible window (\(NSApp.windows.count) windows)")
            return
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        do {
            try bitmap.representation(using: .png, properties: [:])?.write(to: url)
        } catch {
            print("screenshot: \(error.localizedDescription)")
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        store?.flushPendingSaves()
    }
}

/// Command-line checks that don't need a window: audio rendering and (via --screenshot above)
/// a picture of a real running window.
enum DevTools {
    /// Drives every section operation through the real view model and prints what happened
    /// (`--demo --sections`), since the gestures themselves can't be clicked from a script.
    @MainActor static func runSectionDemo(_ m: ProjectViewModel) async {
        func notes(_ t: TrackID, _ lo: Double, _ hi: Double) -> Int {
            NoteEditing.notes(m.displayedSnapshot?.track(t).notes ?? [], in: lo...hi).count
        }
        func say(_ s: String) { print("SECTIONS \(s)"); fflush(stdout) }
        // `--stress`: forty section edits in a row (each one reloads the song into the audio
        // engine), the pattern that used to freeze or crash the app after the first one.
        if CommandLine.arguments.contains("--stress") {
            for i in 0..<40 {
                m.selectSection(track: TrackID.allCases[i % 4], from: Double(i % 8), to: Double(i % 8) + 3)
                if i % 2 == 0 { m.copySection(); m.seek(to: Double((i * 3) % 14)); m.pasteSection() } else { m.duplicateSection() }
                if i % 10 == 9 { say("stress \(i + 1) edits, versions \(m.project.versions.count)") }
                try? await Task.sleep(for: .milliseconds(100))
            }
            m.undo(); m.undo(); m.redo()
            say("stress done, versions \(m.project.versions.count), current v\(m.project.current?.number ?? -1)")
            return
        }
        let len = m.duration
        say("song \(len)s, versions \(m.project.versions.count), guitar notes \(m.displayedSnapshot?.track(.guitar).notes.count ?? 0)")

        m.selectSection(track: .guitar, from: 2.1, to: 5.9)        // snaps to 2.0...6.0
        say("selected \(String(describing: m.sectionSelection?.range))  (expect 2.0...6.0)")
        let inside = notes(.guitar, 2, 6)
        m.copySection()
        say("copied: clipboard has \(m.clipboard?.notes.count ?? -1) notes (expect \(inside)), length \(m.clipboard?.length ?? -1)")

        m.seek(to: 10)
        m.pasteSection()
        say("pasted at 10: guitar notes in 10...14 = \(notes(.guitar, 10, 14)) (expect \(inside)); selection \(String(describing: m.sectionSelection?.range))")

        m.selectSection(track: .drums, from: 0, to: 4)
        let drumsBefore = notes(.drums, 0, 4)
        m.cutSection()
        say("cut drums 0-4: \(drumsBefore) -> \(notes(.drums, 0, 4)) notes (expect 0); clipboard \(m.clipboard?.notes.count ?? -1)")

        m.seek(to: 12)
        m.pasteSection()          // clipboard source is drums, selection is drums
        say("pasted drums at 12: notes in 12...16 = \(notes(.drums, 12, 16)) (expect \(drumsBefore))")

        m.selectSection(track: .bass, from: 4, to: 8)
        let bassBefore = notes(.bass, 4, 8)
        m.duplicateSection()
        say("duplicated bass 4-8: notes in 8...12 = \(notes(.bass, 8, 12)) (>= \(bassBefore)), original still \(notes(.bass, 4, 8)) (expect \(bassBefore))")

        m.selectSection(track: .piano, from: 4, to: 8)
        let pianoBefore = notes(.piano, 4, 8)
        m.moveSection(by: 6)
        say("moved piano 4-8 by +6: old place \(notes(.piano, 4, 8)) (expect 0), new place 10...14 = \(notes(.piano, 10, 14)) (>= \(pianoBefore)); selection \(String(describing: m.sectionSelection?.range))")

        m.selectSection(track: .guitar, from: 0, to: 2)
        m.deleteSection()
        say("deleted guitar 0-2: \(notes(.guitar, 0, 2)) notes (expect 0)")

        say("versions now: " + m.project.versions.map { "v\($0.number) \($0.kind.title)" }.joined(separator: " | "))
        let before = m.project.versions.count
        m.undo()
        say("undo -> current version \(m.project.current?.number ?? -1) of \(before); guitar 0-2 notes back = \(notes(.guitar, 0, 2))")
        m.redo()
        say("redo -> guitar 0-2 notes = \(notes(.guitar, 0, 2)) (expect 0)")

        // rewrite just a section with the model (needs the generator)
        func key(_ n: Note) -> String { "\(n.pitch)@\(Int((n.start * 1000).rounded()))" }   // the server rounds to ms
        func outside(_ t: TrackID, _ lo: Double, _ hi: Double) -> [Note] {
            (m.displayedSnapshot?.track(t).notes ?? []).filter { $0.start < lo || $0.start >= hi }
        }
        let guitarOutside = outside(.guitar, 4, 8), othersBefore = [TrackID.piano, .bass, .drums].map { m.displayedSnapshot?.track($0).notes ?? [] }
        let insideBefore = NoteEditing.notes(m.displayedSnapshot?.track(.guitar).notes ?? [], in: 4...8).map { key($0) }
        let versionsBefore = m.project.versions.count
        m.selectSection(track: .guitar, from: 4, to: 8)
        m.rewriteSection()
        say("rewrite section started: rewriting \(String(describing: m.rewritingTrack)) range \(String(describing: m.rewritingRange))")
        while m.isGeneratorBusy { try? await Task.sleep(for: .milliseconds(300)) }
        let insideAfter = NoteEditing.notes(m.displayedSnapshot?.track(.guitar).notes ?? [], in: 4...8).map { key($0) }
        let sameOutside = outside(.guitar, 4, 8).map { key($0) } == guitarOutside.map { key($0) }
        let othersSame = [TrackID.piano, .bass, .drums].map { m.displayedSnapshot?.track($0).notes ?? [] } == othersBefore
        say("rewrote guitar 4-8: versions \(versionsBefore) -> \(m.project.versions.count), last '\(m.project.versions.last?.kind.title ?? "?")', inside \(insideBefore.count) -> \(insideAfter.count) notes, changed=\(insideBefore != insideAfter), guitar outside unchanged=\(sameOutside), other tracks unchanged=\(othersSame), selection kept=\(String(describing: m.sectionSelection?.range)), phase idle=\(m.rewritingTrack == nil)")

        // guards
        m.selectSection(track: .guitar, from: 3, to: 3.1)
        say("too-small selection ignored: \(m.sectionSelection == nil)")
        m.generate(); m.cutSection()
        say("cut while generating blocked: versions \(m.project.versions.count) (unchanged by the cut)")
        m.cancelGenerate()
        while m.isGeneratorBusy { try? await Task.sleep(for: .milliseconds(200)) }
        m.dismissError()
        say("after cancel: phase idle, versions \(m.project.versions.count)")
        m.selectSection(track: .guitar, from: 6, to: 12)    // leave a selection for the screenshot
        say("final selection \(String(describing: m.sectionSelection?.range)), canEdit \(m.canEditSections)")
    }

    @MainActor static func renderEffectsPopover(to path: String) {
        struct Preview: View {
            @State var effects = TrackEffects(warmth: 0.35, grit: 0.6, echo: 0, reverb: 0.2, pan: -0.4)
            var body: some View {
                TrackEffectsPopover(track: .guitar, effects: $effects, onReset: {})
                    .background(Color.lfbRaised)
                    .environment(\.colorScheme, .dark)
            }
        }
        let renderer = ImageRenderer(content: Preview())
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
            print("could not render the popover"); return
        }
        try? png.write(to: URL(fileURLWithPath: path))
    }

    static func render(wireSongPath: String, style name: String, output: String) -> Int32 {
        do {
            let wire = try JSONDecoder().decode(WireSong.self, from: Data(contentsOf: URL(fileURLWithPath: wireSongPath)))
            let style = MusicStyle(rawValue: name) ?? .lofi
            var snapshot = wire.snapshot(style: style, instruments: style.defaultInstruments)
            // `--fx piano.warmth=1,drums.grit=0.8` replaces the style's per-track effects with
            // exactly these (everything else neutral); `--fx none` renders every track unprocessed.
            if let flag = CommandLine.arguments.firstIndex(of: "--fx"), CommandLine.arguments.count > flag + 1 {
                for i in snapshot.tracks.indices { snapshot.tracks[i].effects = TrackEffects() }
                for item in CommandLine.arguments[flag + 1].split(separator: ",") {
                    let parts = item.split(separator: "=")
                    let key = parts.first?.split(separator: ".").map(String.init) ?? []
                    guard parts.count == 2, key.count == 2, let value = Double(parts[1]),
                          let id = TrackID(rawValue: key[0]),
                          let i = snapshot.tracks.firstIndex(where: { $0.id == id }) else { continue }
                    switch key[1] {
                    case "warmth": snapshot.tracks[i].effects.warmth = value
                    case "grit": snapshot.tracks[i].effects.grit = value
                    case "echo": snapshot.tracks[i].effects.echo = value
                    case "reverb": snapshot.tracks[i].effects.reverb = value
                    case "pan": snapshot.tracks[i].effects.pan = value
                    default: break
                    }
                }
            }
            let audio = AudioEngine()
            for id in TrackID.allCases {
                audio.setInstrument(id.program(for: snapshot.track(id).instrument), for: id)
                audio.setVolume(0.8, for: id)
                audio.apply(snapshot.track(id).effects, for: id)
            }
            audio.apply(style.defaultEffects)
            audio.load(snapshot)
            let url = URL(fileURLWithPath: output)
            try audio.export(to: url, format: output.hasSuffix(".m4a") ? .m4a : .wav)

            let file = try AVAudioFile(forReading: url)
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
            try file.read(into: buffer)
            let samples = UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
            let peak = samples.map(abs).max() ?? 0
            let rms = (samples.reduce(0) { $0 + $1 * $1 } / Float(max(samples.count, 1))).squareRoot()
            print(String(format: "rendered %.1fs, peak %.3f, rms %.4f", Double(file.length) / file.fileFormat.sampleRate, peak, rms))
            return peak > 0.01 ? 0 : 2
        } catch {
            print("render failed: \(error)")
            return 1
        }
    }
}
