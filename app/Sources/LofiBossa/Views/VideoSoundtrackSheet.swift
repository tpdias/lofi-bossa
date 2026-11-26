import SwiftUI
import AVKit
import UniformTypeIdentifiers

/// "Video soundtrack": pick a video from Files, match the song's length to it, preview the music
/// against the picture, and export the video with the music mixed in. Works offline.
struct VideoSoundtrackSheet: View {
    @Bindable var model: ProjectViewModel
    @Environment(\.dismiss) private var dismiss

    private enum Stage: Equatable { case idle, working, done(URL), failed(String) }

    @State private var picking = false
    @State private var videoURL: URL?
    @State private var info: VideoSoundtrack.Info?
    @State private var player: AVPlayer?
    @State private var options = VideoSoundtrack.Options()
    @State private var stage: Stage = .idle
    @State private var previewing = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LFBSpace.lg) {
                HStack {
                    Text("Video soundtrack").font(.lfbTitle)
                    Spacer()
                    Button("Close") { stopPreview(); dismiss() }
                }
                if let info, let player {
                    VideoPlayer(player: player)
                        .frame(minHeight: 180, maxHeight: 260)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    Text("\(videoURL?.lastPathComponent ?? "Video") · \(formatTimecode(info.duration))"
                         + (info.hasAudio ? "" : " · no sound"))
                        .font(.lfbCaption).foregroundStyle(Color.lfbTextSecondary)
                    controls(info)
                } else {
                    Text("Choose a video from Files. The song is written to its length, and the music is mixed into a copy of it. Your original is not changed.")
                        .font(.lfbBody).foregroundStyle(Color.lfbTextSecondary)
                }
                Button(videoURL == nil ? "Choose video…" : "Choose another video…") { picking = true }
                    .accessibilityIdentifier("video-choose")
                footer
            }
            .padding(LFBSpace.xl)
        }
        #if os(macOS)
        .frame(width: 520, height: 600)
        #endif
        .fileImporter(isPresented: $picking, allowedContentTypes: [.movie, .mpeg4Movie, .quickTimeMovie]) { result in
            if case .success(let url) = result { Task { await load(url) } }
        }
        .onDisappear { stopPreview() }
    }

    @ViewBuilder private func controls(_ info: VideoSoundtrack.Info) -> some View {
        let target = VideoSoundtrack.songLength(forVideo: info.duration)
        VStack(alignment: .leading, spacing: LFBSpace.sm) {
            HStack {
                Button(previewing ? "Pause preview" : "Play with music") { togglePreview() }
                    .disabled(model.project.currentSnapshot == nil)
                Button("Restart") { restartPreview() }
            }
            Text("The preview plays the song at its mixer levels next to the video's own sound.")
                .font(.lfbCaption).foregroundStyle(Color.lfbTextSecondary)

            Divider()
            Button("Make the next song \(formatTimecode(target)) long") { model.setLength(target) }
                .disabled(abs(model.project.lengthSeconds - target) < 0.5)
            Text(lengthNote(info))
                .font(.lfbCaption).foregroundStyle(Color.lfbTextSecondary)

            Divider()
            HStack {
                Text("Music level")
                Slider(value: Binding(get: { Double(options.musicVolume) }, set: { options.musicVolume = Float($0) }), in: 0...1)
            }
            Toggle("Lower the music under the video's own sound", isOn: $options.duckUnderOriginal)
                .disabled(!info.hasAudio)
            Picker("Fade out at the end", selection: $options.fadeOut) {
                ForEach([0.0, 1, 2, 4], id: \.self) { Text($0 == 0 ? "None" : "\(Int($0)) s").tag($0) }
            }
        }
    }

    private func lengthNote(_ info: VideoSoundtrack.Info) -> String {
        let song = model.duration
        if song < info.duration - 0.5 {
            return "The current song is \(formatTimecode(song)), shorter than the video, so it repeats. Generate a new song for a fit."
        } else if song > info.duration + 0.5 {
            return "The current song is \(formatTimecode(song)); it is cut at the end of the video."
        }
        return "The current song is the same length as the video."
    }

    @ViewBuilder private var footer: some View {
        switch stage {
        case .idle:
            Button("Export video") { Task { await export() } }
                .buttonStyle(.borderedProminent)
                .disabled(videoURL == nil || model.project.currentSnapshot == nil)
                .accessibilityIdentifier("video-export")
        case .working:
            HStack { ProgressView(); Text("Mixing the music into the video…") }
        case .done(let url):
            VStack(alignment: .leading, spacing: LFBSpace.sm) {
                Label("Exported \(url.lastPathComponent)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Color.lfbReady)
                #if os(macOS)
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                #else
                ShareLink("Share…", item: url)
                #endif
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: LFBSpace.sm) {
                Text("Export failed. \(message)").foregroundStyle(Color.lfbFailure)
                Button("Try again") { stage = .idle }
            }
        }
    }

    // MARK: Actions

    private func load(_ url: URL) async {
        stopPreview()
        if videoURL != url { videoURL?.stopAccessingSecurityScopedResource() }
        _ = url.startAccessingSecurityScopedResource()
        do {
            let loaded = try await VideoSoundtrack.info(for: url)
            videoURL = url
            info = loaded
            player = AVPlayer(url: url)
            stage = .idle
        } catch {
            stage = .failed(error.localizedDescription)
        }
    }

    private func togglePreview() {
        guard let player else { return }
        if previewing { stopPreview(); return }
        model.seek(to: min(player.currentTime().seconds, model.duration))
        model.play()
        player.play()
        previewing = true
    }

    private func restartPreview() {
        player?.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        model.seek(to: 0)
    }

    private func stopPreview() {
        guard previewing else { return }
        player?.pause()
        model.pause()
        previewing = false
    }

    private func export() async {
        guard let videoURL else { return }
        stopPreview()
        guard let destination = chooseDestination(for: videoURL) else { return }
        stage = .working
        let music = FileManager.default.temporaryDirectory.appendingPathComponent("music-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: music) }
        do {
            try model.renderMusicForVideo(to: music)
            try await VideoSoundtrack.export(video: videoURL, music: music, to: destination, options: options)
            stage = .done(destination)
        } catch {
            stage = .failed(error.localizedDescription)
        }
    }

    private func chooseDestination(for video: URL) -> URL? {
        let base = video.deletingPathExtension().lastPathComponent + " with music"
        #if os(macOS)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = base
        return panel.runModal() == .OK ? panel.url : nil
        #else
        return FileManager.default.temporaryDirectory.appendingPathComponent(base).appendingPathExtension("mp4")
        #endif
    }
}
