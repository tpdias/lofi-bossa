#if os(iOS)
import SwiftUI

// MARK: - Ruler, playhead, loop range, track rows, piano roll

/// The lanes on iPad: ruler (tap to seek, drag to set the loop range), the track rows sharing the
/// height (112 pt minimum; more than four tracks scroll), one overlay for the loop range and the
/// playhead, and the piano roll as a bottom split pane with the rows collapsed to 52 pt strips.
struct PadTracksView: View {
    @Bindable var model: ProjectViewModel
    let snapshot: SongSnapshot
    @State private var dragStart: Double?
    @FocusState private var stageFocused: Bool

    private var duration: Double { max(snapshot.lengthSeconds, 1) }
    private var laneX: CGFloat { LFBTouchSize.trackHeaderWidth + 1 }
    private static let rulerHeight: CGFloat = 28
    /// The stage's timeline zoom (pinch, two-finger drag, ⌘+ / ⌘− / ⌘0 on a keyboard).
    private var window: TimelineWindow { model.timeline }

    var body: some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                ruler
                    .timelineZoomGestures(model: model, laneX: laneX)
                Divider()
                if model.isPianoRollOpen {
                    VStack(spacing: 0) {
                        ForEach(snapshot.trackIDs) { id in row(id, compact: true) }
                    }
                    .timelineZoomGestures(model: model, laneX: laneX)
                    Divider()
                    if let track = model.editingTrack {
                        PianoRollView(model: model, track: track)
                    }
                } else {
                    Group {
                        if snapshot.tracks.count > 4 {
                            ScrollView(.vertical) { trackRows }
                        } else {
                            trackRows
                        }
                    }
                    .timelineZoomGestures(model: model, laneX: laneX)
                }
            }
            overlay
                .frame(height: model.isPianoRollOpen
                       ? Self.rulerHeight + 1 + CGFloat(snapshot.tracks.count) * PadTrackRow.compactHeight : nil,
                       alignment: .top)
        }
        // Section shortcuts with a hardware keyboard (the Mac handles them the same way).
        .focusable()
        .focused($stageFocused)
        .focusEffectDisabled()
        .onKeyPress(phases: .down, action: handleKey)
        .onChange(of: model.sectionSelection) { _, selection in
            if selection != nil { stageFocused = true }
        }
        .onAppear { model.applyLaunchStageZoom() }
    }

    private var trackRows: some View {
        VStack(spacing: 0) {
            ForEach(snapshot.trackIDs) { id in row(id, compact: false) }
            if model.canChangeTracks && !model.addableTracks.isEmpty {
                Menu {
                    ForEach(model.addableTracks) { id in Button(id.title) { model.addTrack(id) } }
                } label: {
                    Label("Add Track", systemImage: "plus")
                        .font(.system(size: 15, weight: .medium))
                        .padding(.horizontal, 14)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .accessibilityIdentifier("add-track")
            }
        }
    }

    private func row(_ id: TrackID, compact: Bool) -> some View {
        PadTrackRow(
            track: trackBinding(id), duration: duration, window: window,
            grid: model.displayedSnapshot?.beatGrid,
            isSelected: compact ? model.editingTrack == id : model.selectedTrack == id,
            isDimmedBySolo: model.isDimmedBySolo(id),
            isRewriting: model.rewritingTrack == id,
            rewritingRange: model.rewritingTrack == id ? model.rewritingRange : nil,
            isGeneratorBusy: model.isGeneratorBusy,
            compact: compact,
            songBusyness: model.project.songBusyness,
            songNoteLength: model.project.songNoteLength,
            onSeek: { model.clearSectionSelection(); model.seek(to: $0) },
            onSelect: { model.openEditor(for: id) },
            onRewrite: { model.rewrite(id) },
            onCancelRewrite: model.cancelRewrite,
            onResetEffects: { model.resetTrackEffects(for: id) },
            onRemove: TrackID.optional.contains(id) && model.canChangeTracks ? { model.removeTrack(id) } : nil,
            sectionSelection: model.sectionSelection?.track == id ? model.sectionSelection?.range : nil,
            sectionsEnabled: model.canEditSections,
            canPasteSection: model.canPasteSection,
            onSelectSection: { model.selectSection(track: id, from: $0, to: $1) },
            onMoveSection: { model.moveSection(by: $0) },
            onSectionAction: { action in
                switch action {
                case .cut: model.cutSection()
                case .copy: model.copySection()
                case .paste: model.pasteSection(onto: id)
                case .delete: model.deleteSection()
                case .duplicate: model.duplicateSection()
                case .useAsLoop: model.useSectionAsLoop()
                case .rewrite: model.rewriteSection()
                case .clear: model.clearSectionSelection()
                }
            }
        )
    }

    private func trackBinding(_ id: TrackID) -> Binding<Track> {
        Binding(
            get: { model.displayedSnapshot?.track(id) ?? Track(id: id, instrument: id.defaultInstrument) },
            set: { new in
                let old = model.displayedSnapshot?.track(id)
                if new.isMuted != old?.isMuted { model.setMuted(new.isMuted, for: id) }
                if new.isSoloed != old?.isSoloed { model.setSoloed(new.isSoloed, for: id) }
                if new.volume != old?.volume { model.setVolume(new.volume, for: id) }
                if new.instrument != old?.instrument { model.setInstrument(new.instrument, for: id) }
                if new.effects != old?.effects { model.setTrackEffects(new.effects, for: id) }
                if new.busyness != old?.busyness { model.setTrackBusyness(new.busyness, for: id) }
                if new.noteLength != old?.noteLength { model.setTrackNoteLength(new.noteLength, for: id) }
                if new.isLocked != old?.isLocked { model.setLocked(new.isLocked, for: id) }
            }
        )
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        guard model.canEditSections else { return .ignored }
        if model.sectionSelection != nil {
            switch press.key {
            case .escape: model.clearSectionSelection(); return .handled
            case .delete, .deleteForward: model.deleteSection(); return .handled
            default: break
            }
        }
        guard press.modifiers.contains(.command) else { return .ignored }
        switch press.characters.lowercased() {
        case "x" where model.sectionSelection != nil: model.cutSection(); return .handled
        case "c" where model.sectionSelection != nil: model.copySection(); return .handled
        case "d" where model.sectionSelection != nil: model.duplicateSection(); return .handled
        case "v" where model.canPasteSection: model.pasteSection(); return .handled
        default: return .ignored
        }
    }

    // MARK: Ruler

    private var ruler: some View {
        HStack(spacing: 0) {
            Color.lfbWindow.frame(width: laneX)
            GeometryReader { geo in
                Canvas { ctx, size in
                    TimelineRuler.drawTicks(&ctx, size: size, duration: duration, window: window, style: TimelineRuler.pad,
                                            grid: model.displayedSnapshot?.beatGrid)
                }
                .contentShape(Rectangle())
                .gesture(rangeDrag(width: geo.size.width))
            }
        }
        .frame(height: Self.rulerHeight)
        .background(Color.lfbSurface)
        .accessibilityElement()
        .accessibilityLabel("Timeline")
        .accessibilityValue("\(formatTimecode(model.position)) of \(formatTimecode(duration))")
        .accessibilityAdjustableAction { direction in
            model.nudgePlayhead(by: direction == .increment ? 5 : -5)
        }
    }

    private func time(atX x: CGFloat, width: CGFloat) -> Double {
        min(max(window.time(atX: x, width: width, duration: duration), 0), duration)
    }

    private func rangeDrag(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { g in
                if dragStart == nil { dragStart = time(atX: g.startLocation.x, width: width) }
                let a = dragStart ?? 0
                let b = time(atX: g.location.x, width: width)
                model.setLoopRange(min(a, b)...max(a, b, min(a, b) + 0.5))
            }
            .onEnded { _ in dragStart = nil }
            .exclusively(before: SpatialTapGesture().onEnded { tap in
                model.tapRuler(at: time(atX: tap.location.x, width: width))
            })
    }

    private var overlay: some View {
        GeometryReader { geo in
            let laneW = max(geo.size.width - laneX, 1)
            ZStack(alignment: .topLeading) {
                if model.isLoopEnabled, let range = model.loopRange {
                    Color.lfbAccentWash
                        .frame(width: max(window.width(of: range.upperBound - range.lowerBound, width: laneW, duration: duration), 0))
                        .overlay(alignment: .topLeading) {
                            Text("Loop · \(Int((range.upperBound - range.lowerBound).rounded())) s")
                                .font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.lfbAccentText)
                                .padding(.horizontal, 6).padding(.top, Self.rulerHeight + 4)
                                .fixedSize()
                        }
                        .offset(x: window.x(for: range.lowerBound, width: laneW, duration: duration))
                }
                Rectangle().fill(Color.lfbText.opacity(0.7)).frame(width: 2)
                    .offset(x: window.x(for: min(model.position, duration), width: laneW, duration: duration) - 1)
            }
            .frame(width: laneW + 1, alignment: .topLeading)
            .clipped()   // zoomed in, the loop range and playhead slide off past the lanes' edges
            .offset(x: laneX)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Empty project

struct PadEmptyProjectView: View {
    @Bindable var model: ProjectViewModel

    var body: some View {
        VStack(spacing: 0) {
            Color.lfbSurface.frame(height: 28)
            Divider()
            ForEach(TrackID.core) { id in
                HStack(spacing: 0) {
                    HStack(spacing: 8) {
                        TrackGlyph(id: id, size: 32)
                        Text(id.title).font(.system(size: 16, weight: .semibold, design: .rounded))
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .frame(width: LFBTouchSize.trackHeaderWidth, alignment: .leading)
                    Divider()
                    ZStack {
                        PadHatchedLane(color: id.color)
                        if model.isGenerating { SweepView(color: id.color) }
                    }
                    .clipped()
                }
                .frame(minHeight: LFBTouchSize.trackRowMinHeight)
                .overlay(alignment: .bottom) { Divider() }
            }
        }
        .overlay {
            if !model.isGenerating {
                VStack(spacing: LFBSpace.md) {
                    Text("Nothing written yet").font(.lfbTitle)
                    Text("Pick a style and a length above, then generate. A four-part song usually takes under a minute.")
                        .font(.system(size: 15)).foregroundStyle(Color.lfbTextSecondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 340)
                    Button { model.generate() } label: {
                        Label("Generate", systemImage: "sparkles").frame(minWidth: 160, minHeight: 32)
                    }
                    .buttonStyle(LFBPrimaryButtonStyle()).controlSize(.large)
                    .disabled(model.isGeneratorBusy || !isReady)
                }
                .padding(LFBSpace.xl)
                .background(Color.lfbRaised, in: RoundedRectangle(cornerRadius: LFBRadius.card))
                .shadow(color: .black.opacity(0.1), radius: 8, y: 2)
            }
        }
    }

    private var isReady: Bool { if case .ready = model.status { true } else { false } }
}

struct PadHatchedLane: View {
    let color: Color
    var body: some View {
        Canvas { ctx, size in
            var x: CGFloat = -size.height
            while x < size.width {
                var path = Path()
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x + size.height, y: 0))
                ctx.stroke(path, with: .color(color.opacity(0.12)), lineWidth: 1)
                x += 10
            }
        }
        .background(Color.lfbSurface)
    }
}

// MARK: - Transport

/// 76 pt transport: generator status at the leading edge; back to start, 52 pt play, loop and
/// the time in the centre; the loop range chip at the trailing edge. Space plays and pauses.
struct PadTransportBar: View {
    @Bindable var model: ProjectViewModel

    var body: some View {
        HStack(spacing: LFBSpace.lg) {
            GeneratorStatusPill(status: model.status)
                .padding(.horizontal, 12).frame(height: 32)
                .background(Color.lfbWell, in: Capsule())
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: LFBSpace.lg) {
                Button { model.seek(to: 0) } label: {
                    Image(systemName: "backward.end.fill").font(.system(size: 18)).frame(width: 44, height: 44)
                }
                .buttonStyle(.plain).foregroundStyle(Color.lfbText)
                .disabled(model.displayedSnapshot == nil)
                .accessibilityLabel("Go to start")
                Button(action: model.togglePlay) {
                    Image(systemName: model.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: LFBTouchSize.playButton))
                        .foregroundStyle(Color.lfbAccent)
                }
                .buttonStyle(.plain)
                .disabled(model.displayedSnapshot == nil)
                .keyboardShortcut(.space, modifiers: [])
                .accessibilityIdentifier("play")
                .accessibilityLabel(model.isPlaying ? "Pause" : "Play")
                Button { model.toggleLoop() } label: {
                    Image(systemName: "repeat").font(.system(size: 18)).frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .foregroundStyle(model.isLoopEnabled ? Color.lfbAccent : Color.lfbTextSecondary)
                .disabled(model.loopRange == nil)
                .accessibilityLabel("Loop")
                .accessibilityValue(model.isLoopEnabled ? "On" : "Off")
                Text("\(formatTimecode(model.position)) / \(formatTimecode(model.duration))")
                    .font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit()
                    .fixedSize()
            }

            HStack {
                if let range = model.loopRange {
                    HStack(spacing: 6) {
                        Text("Loop · \(formatTimecode(range.lowerBound)) – \(formatTimecode(range.upperBound))")
                            .font(.system(size: 13, weight: .medium))
                        Button { model.clearLoop() } label: {
                            Image(systemName: "xmark.circle.fill").frame(width: 32, height: 32)
                        }
                        .buttonStyle(.plain).foregroundStyle(Color.lfbTextSecondary)
                        .accessibilityLabel("Clear loop")
                    }
                    .padding(.leading, 12).padding(.trailing, 2).frame(height: 32)
                    .background(Color.lfbWell, in: Capsule())
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, LFBSpace.lg)
        .frame(height: LFBTouchSize.transportHeight)
        .background(Color.lfbSurface)
    }
}
#endif
