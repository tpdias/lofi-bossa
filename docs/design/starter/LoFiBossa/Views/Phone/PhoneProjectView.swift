import SwiftUI

#if os(iOS)
/// iPhone and the iPhone Duo outer display (compact width). See the "iPhone · …" and "Duo closed" artboards.
///
/// Navigation bar: Projects back button, title + "Style · length · Saved", Undo, More menu
///   (Export…, Rename, Duplicate, Copy Seed, Generation options → Model).
/// Recipe strip: Style menu chip, Length chip (popover slider), Seed chip (popover: dice toggle,
///   typed seed, copy), New take. While generating, a banner replaces the strip.
/// Four TrackCards fill the remaining height; with less than ~760 pt of height they shrink (Duo closed).
/// Floating transport: scrubber with loop range, Sound · back · play · loop · Versions.
struct PhoneProjectView: View {
    @Bindable var session: ProjectSession

    var body: some View {
        VStack(spacing: 0) {
            RecipeStrip(session: session)
            VStack(spacing: 8) {
                ForEach($session.song.tracks) { $track in
                    TrackCard(track: $track,
                              duration: session.duration,
                              playhead: session.playhead,
                              loop: session.loop,
                              isRewriting: session.rewritingTrack() == track.id,
                              isSelected: session.selectedTrack == track.id,
                              onOpenTrack: { session.sheet = .track(track.id) },
                              onEditNotes: { session.openNotes(track.id) },
                              onSeek: { session.playhead = $0 })
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
        }
        .background(Color.lfbWindow)
        .safeAreaInset(edge: .bottom) { PhoneTransport(session: session) }
        .navigationTitle(session.project.name)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $session.isEditingNotes) {
            PianoRollView(session: session)        // pushed; also rotates to landscape for more room
        }
        .sheet(item: $session.sheet) { sheet in
            Group {
                switch sheet {
                case .sound: SoundPanel(effects: $session.song.effects).padding()
                case .versions: VersionsPanel(session: session)
                case .export: Text("Export")       // format, range, Export → ShareLink / fileExporter
                case .track(let id): Text("\(id.title) track")   // instrument list, volume, M/S, Edit notes, Rewrite
                }
            }
            .presentationDetents(detents(for: sheet))
            .presentationBackgroundInteraction(.enabled(upThrough: .medium))   // keep playing and scrubbing
        }
    }

    private func detents(for sheet: CompactSheet) -> Set<PresentationDetent> {
        switch sheet {
        case .sound, .export: [.medium]
        case .versions: [.medium, .large]
        case .track: [.medium, .large]
        }
    }
}

struct RecipeStrip: View {
    @Bindable var session: ProjectSession
    var body: some View {
        HStack(spacing: 8) {
            Menu(session.project.style.title) {
                Picker("Style", selection: $session.project.style) {
                    ForEach(MusicStyle.allCases) { Text($0.title).tag($0) }
                }
            }
            Button(Duration.seconds(session.project.lengthSeconds).formatted(.time(pattern: .minuteSecond))) {}
            Button(session.project.pinnedSeed.map(String.init) ?? "Random", systemImage: "dice") {}
            Spacer()
            Button("New take", systemImage: "sparkles") {}
                .buttonStyle(.borderedProminent)
                .disabled(session.generator != .ready || session.phase != .idle)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

struct PhoneTransport: View {
    @Bindable var session: ProjectSession
    var body: some View {
        VStack(spacing: 2) {
            Slider(value: $session.playhead, in: 0...max(session.duration, 1))   // replace with the custom scrubber + loop range
            HStack {
                Button { session.sheet = .sound } label: { Label("Sound", systemImage: "slider.horizontal.3") }
                Spacer()
                Button { session.playhead = 0 } label: { Image(systemName: "backward.end") }
                    .accessibilityLabel("Back to start")
                Button { session.isPlaying.toggle() } label: {
                    Image(systemName: session.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: LFBSize.playButtonPhone, height: LFBSize.playButtonPhone)
                        .background(Color.lfbText, in: Circle())
                        .foregroundStyle(Color.lfbWindow)
                }
                .accessibilityLabel(session.isPlaying ? "Pause" : "Play")
                Button { session.isLooping.toggle() } label: { Image(systemName: "repeat") }
                    .accessibilityLabel("Loop")
                Spacer()
                Button { session.sheet = .versions } label: { Label("Versions", systemImage: "clock.arrow.circlepath") }
            }
            .labelStyle(.verticalCompact)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color.lfbRaised, in: RoundedRectangle(cornerRadius: 26))
        .padding(.horizontal, 10)
    }
}

private struct VerticalCompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(spacing: 1) { configuration.icon.font(.system(size: 20)); configuration.title.font(.system(size: 11, weight: .medium)) }
            .frame(width: 64, height: 48)
    }
}
private extension LabelStyle where Self == VerticalCompactLabelStyle {
    static var verticalCompact: VerticalCompactLabelStyle { .init() }
}
#endif
