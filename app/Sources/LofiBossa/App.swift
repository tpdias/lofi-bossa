import AVFoundation
import SwiftUI

@main
struct LofiBossaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var state = AppState()

    init() {
        let args = CommandLine.arguments
        if let flag = args.firstIndex(of: "--render"), args.count > flag + 3 {
            // Headless check of the audio path:  LofiBossa --render song.json lofi|bossa out.wav
            exit(Self.renderHeadless(song: args[flag + 1], style: args[flag + 2], output: args[flag + 3]))
        }
    }

    var body: some Scene {
        WindowGroup("Lo-Fi & Bossa") {
            ContentView()
                .environmentObject(state)
                .frame(minWidth: 900, minHeight: 500)
        }
    }

    private static func renderHeadless(song path: String, style name: String, output: String) -> Int32 {
        do {
            let song = try JSONDecoder().decode(Song.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
            let style = Style(rawValue: name) ?? .lofi
            let audio = AudioEngine()
            for kind in TrackKind.allCases {
                let preset = kind.presets.first { $0.name == style.presetNames[kind] } ?? kind.presets[0]
                audio.setInstrument(preset, for: kind)
                audio.setVolume(0.8, for: kind)
            }
            audio.apply(style.effects)
            audio.load(song)
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

/// Run from `swift run` there is no app bundle, so ask for a normal Dock app and focus it.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // `--screenshot out.png` saves a picture of the window and quits (used for the README).
        let args = CommandLine.arguments
        if let flag = args.firstIndex(of: "--screenshot"), args.count > flag + 1 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
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
}
