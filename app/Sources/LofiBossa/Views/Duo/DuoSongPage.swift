#if os(iOS)
import SwiftUI

/// Left page of the unfolded Duo (artboard `Duo.dc.html`, view "open"): nav bar, the recipe
/// strip (or a banner while generating), the track cards, and a single-row transport.
struct DuoSongPage: View {
    @Bindable var model: ProjectViewModel
    var onExport: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            DuoNavBar(model: model, onExport: onExport)
            DuoStatusBanner(model: model)
            if !model.isGenerating {
                DuoRecipeStrip(model: model)          // seam: iPhone recipe strip (see DuoPhoneSeam.swift)
            }
            if model.isListeningToPastVersion, let version = model.listeningVersion {
                DuoListeningBanner(model: model, version: version)
            }
            DuoTrackCards(model: model)               // seam: iPhone track cards (see DuoPhoneSeam.swift)
            DuoTransportBar(model: model)
        }
    }
}

// MARK: - Nav bar

/// "‹ Projects", the title with "Lo-Fi · 1:30 · Saved", Undo and More (HANDOFF §5.2, item 1).
struct DuoNavBar: View {
    @Bindable var model: ProjectViewModel
    var onExport: () -> Void
    var showsActions = true
    @Environment(AppSession.self) private var session
    @State private var isRenaming = false
    @State private var draftName = ""

    var body: some View {
        HStack(spacing: 2) {
            Button { session.selection = .allProjects } label: {
                HStack(spacing: 0) {
                    Image(systemName: "chevron.backward").font(.system(size: 20, weight: .semibold))
                    Text("Projects").font(.system(size: 17))
                }
                .padding(.leading, 2).padding(.trailing, 6)
                .frame(height: LFBPhoneSize.minHitTarget)
            }
            .foregroundStyle(Color.lfbAccentText)
            .accessibilityLabel("Projects")

            VStack(spacing: 1) {
                Text(model.project.name).font(.system(size: 16, weight: .semibold, design: .rounded)).lineLimit(1)
                Text(subtitle).font(.system(size: 12)).foregroundStyle(Color.lfbTextTertiary).lineLimit(1)
            }
            .frame(maxWidth: .infinity)

            if showsActions {
                Button(action: model.undo) { Image(systemName: "arrow.uturn.backward") }
                    .buttonStyle(DuoIconButtonStyle())
                    .disabled(!model.canUndo)
                    .accessibilityLabel(model.undoTitle.map { "Undo \($0)" } ?? "Undo")
                moreMenu
            } else {
                Color.clear.frame(width: 88, height: 1)   // keeps the title centred (tabletop)
            }
        }
        .padding(.horizontal, 6)
        .frame(height: LFBPhoneSize.navBar)
        .alert("Rename Project", isPresented: $isRenaming) {
            TextField("Name", text: $draftName)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { model.rename(to: draftName) }
        }
    }

    private var subtitle: String {
        let tail = showsActions ? "Saved" : (model.project.current.map { "Version \($0.number)" } ?? "Not generated yet")
        return "\(model.project.style.title) · \(formatTimecode(model.project.lengthSeconds)) · \(tail)"
    }

    /// More: Export…, Rename, Duplicate, Copy Seed, Generation options › Model, Delete (§5.2).
    private var moreMenu: some View {
        Menu {
            Button(action: onExport) { Label("Export…", systemImage: "square.and.arrow.up") }
                .disabled(model.displayedSnapshot == nil)
            Button { draftName = model.project.name; isRenaming = true } label: { Label("Rename", systemImage: "pencil") }
            Button {
                let copy = session.store.duplicate(model.project)
                session.open(copy)
            } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
            Button(action: model.copySeedToPasteboard) { Label("Copy Seed", systemImage: "number") }
                .disabled(model.displaySeed == nil)
            Menu {
                Picker("Model", selection: Binding(get: { model.activeModel }, set: model.setModel)) {
                    ForEach(NoteModel.allCases) { m in
                        Text(m.title).tag(m)
                    }
                }
                .disabled(!model.hasFinetunedForStyle)
            } label: { Label("Generation Options", systemImage: "slider.horizontal.3") }
            Divider()
            Button(role: .destructive) {
                let project = model.project
                session.selection = .allProjects
                session.store.moveToTrash(project)
            } label: { Label("Delete", systemImage: "trash") }
        } label: {
            Image(systemName: "ellipsis")
        }
        .buttonStyle(DuoIconButtonStyle())
        .accessibilityLabel("More")
    }
}

/// 44 pt round icon button (`.m-ib`).
struct DuoIconButtonStyle: ButtonStyle {
    var solid = false
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 18, weight: .medium))
            .foregroundStyle(Color.lfbAccentText)
            .frame(width: LFBPhoneSize.minHitTarget, height: LFBPhoneSize.minHitTarget)
            .background(solid ? Color.lfbAccentWash : .clear, in: Circle())
            .contentShape(Circle())
            .opacity(isEnabled ? (configuration.isPressed ? 0.6 : 1) : 0.35)
    }
}

// MARK: - Banners

/// Phone banners (HANDOFF §5.6): only when the generator is not ready, while generating, or
/// after an error. Styled as `.ban`: a raised rounded card, not the Mac's full-width bar.
struct DuoStatusBanner: View {
    @Bindable var model: ProjectViewModel
    @State private var showDetails = false

    var body: some View {
        switch model.status {
        case .starting:
            DuoBanner {
                ProgressView().controlSize(.small)
                text("Loading the music model…", "A few seconds after launch.")
            }
        case .offline(let reason):
            DuoBanner {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.lfbCaution)
                text("The generator isn't running.", "Play, mix, edit and export still work.")
                Button("Restart") { Task { try? await model.generator.restart() } }.buttonStyle(DuoPillButtonStyle(primary: true))
                if reason != nil || !model.generator.fullLog.isEmpty {
                    Button("Details") { showDetails = true }.buttonStyle(DuoPillButtonStyle())
                }
            }
            .alert("Generator Details", isPresented: $showDetails) {
                Button("Copy") { Pasteboard.copy(model.generator.fullLog) }
                Button("OK", role: .cancel) {}
            } message: {
                Text(reason ?? (model.generator.fullLog.isEmpty ? "No output yet." : String(model.generator.fullLog.suffix(600))))
            }
        case .ready:
            switch model.phase {
            case .generating(let startedAt, _):
                DuoBanner(progress: true) {
                    ProgressView().controlSize(.small)
                    TimelineView(.periodic(from: startedAt, by: 1)) { timeline in
                        let elapsed = Int(timeline.date.timeIntervalSince(startedAt))
                        text("Writing a new take", "\(elapsed) s so far. Your current take is kept.")
                    }
                    Button("Cancel", action: model.cancelGenerate).buttonStyle(DuoPillButtonStyle())
                }
            case .failed(_, let detail, let scope) where scope == nil:
                DuoBanner {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.lfbFailure)
                    text("That take didn't finish.", "Your song is unchanged.")
                    Button("Try again") { model.dismissError(); model.generate() }.buttonStyle(DuoPillButtonStyle(primary: true))
                    if detail != nil {
                        Button("Details") { showDetails = true }.buttonStyle(DuoPillButtonStyle())
                    }
                }
                .alert("Details", isPresented: $showDetails) {
                    Button("OK", role: .cancel) {}
                } message: { Text(detail ?? "") }
            default:
                EmptyView()
            }
        }
    }

    private func text(_ title: String, _ detail: String) -> some View {
        (Text(title).fontWeight(.semibold) + Text(" ") + Text(detail).foregroundColor(.lfbTextSecondary))
            .font(.system(size: 14))
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// `.ban`: raised card with 10 pt radius, 10 × 12 outer margin.
struct DuoBanner<Content: View>: View {
    var progress = false
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) { content }
            if progress {
                ProgressView().progressViewStyle(.linear).tint(Color.lfbAccent)
            }
        }
        .padding(.leading, 12).padding([.trailing, .vertical], 8)
        .background(Color.lfbRaised, in: RoundedRectangle(cornerRadius: LFBRadius.banner))
        .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
        .padding(.horizontal, 12).padding(.vertical, 6)
    }
}

/// "Listening to version N" with Back to current and Restore (HANDOFF §6.2, view "versions").
struct DuoListeningBanner: View {
    @Bindable var model: ProjectViewModel
    let version: Version

    var body: some View {
        DuoBanner {
            Image(systemName: "headphones").foregroundStyle(Color.lfbAccentText)
            (Text("Listening to version \(version.number)").fontWeight(.semibold) + Text(" ")
             + Text("Same spot in the song.").foregroundColor(.lfbTextSecondary))
                .font(.system(size: 14)).frame(maxWidth: .infinity, alignment: .leading)
            Button("Back to current", action: model.backToCurrentVersion).buttonStyle(DuoPillButtonStyle())
            Button("Restore", action: model.restoreListeningVersion).buttonStyle(DuoPillButtonStyle(primary: true))
        }
    }
}

/// `.btn` on touch: a 36 pt capsule, accent when primary.
struct DuoPillButtonStyle: ButtonStyle {
    var primary = false
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .lineLimit(1)
            .foregroundStyle(primary ? Color.lfbOnAccent : Color.lfbText)
            .padding(.horizontal, 14).frame(minHeight: 36)
            .background(primary ? Color.lfbAccent : Color.lfbControl, in: Capsule())
            .overlay(Capsule().strokeBorder(primary ? .clear : Color.lfbControlHairline, lineWidth: 1))
            .contentShape(Capsule())
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
    }
}

// MARK: - Transport

/// Single-row transport (`.d-tp`): play, time, scrubber with the loop range, loop.
struct DuoTransportBar: View {
    @Bindable var model: ProjectViewModel

    var body: some View {
        HStack(spacing: 8) {
            DuoPlayButton(model: model, size: LFBPhoneSize.playButtonShort)
            (Text(formatTimecode(model.position)) + Text(" / \(formatTimecode(model.duration))")
                .font(.system(size: 12)).foregroundColor(.lfbTextSecondary))
                .font(.system(size: 15, weight: .semibold, design: .rounded)).monospacedDigit()
                .fixedSize()
            DuoScrubber(model: model)
            DuoLoopButton(model: model)
        }
        .padding(.leading, 6).padding(.trailing, 10).padding(.vertical, 6)
        .background(Color.lfbRaised, in: Capsule())
        .shadow(color: .black.opacity(0.14), radius: 10, y: 4)
        .padding(.horizontal, 12).padding(.bottom, 10)
    }
}

struct DuoPlayButton: View {
    @Bindable var model: ProjectViewModel
    var size: CGFloat
    var body: some View {
        Button(action: model.togglePlay) {
            Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: size * 0.4))
                .foregroundStyle(Color.lfbWindow)
                .frame(width: size, height: size)
                .background(Color.lfbText, in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(model.displayedSnapshot == nil)
        .accessibilityLabel(model.isPlaying ? "Pause" : "Play")
    }
}

struct DuoLoopButton: View {
    @Bindable var model: ProjectViewModel
    var body: some View {
        Button {
            // With no range yet, loop the 20 s around the playhead so the button always does something.
            if model.loopRange == nil {
                let start = max(min(model.position, model.duration - 20), 0)
                model.setLoopRange(start...min(start + 20, model.duration))
            } else {
                model.toggleLoop()
            }
        } label: {
            Image(systemName: "repeat").font(.system(size: 18, weight: .medium))
                .foregroundStyle(model.isLoopEnabled ? Color.lfbAccentText : Color.lfbTextSecondary)
                .frame(width: 44, height: 44)
                .background(model.isLoopEnabled ? Color.lfbAccentWash : .clear, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Loop the selected range")
        .accessibilityAddTraits(model.isLoopEnabled ? .isSelected : [])
    }
}

/// Scrubber (`.m-scrub`): drag to seek; long press then drag to set the loop range (§2.4).
struct DuoScrubber: View {
    @Bindable var model: ProjectViewModel
    @State private var loopStart: Double?

    var body: some View {
        GeometryReader { geo in
            let w = max(geo.size.width, 1)
            let d = max(model.duration, 1)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.lfbControlHairline).frame(height: 4)
                if let r = model.loopRange {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.lfbAccentWash)
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.lfbAccent, lineWidth: 1.5))
                        .frame(width: max(CGFloat((r.upperBound - r.lowerBound) / d) * w, 4), height: 18)
                        .offset(x: CGFloat(r.lowerBound / d) * w)
                        .opacity(model.isLoopEnabled ? 1 : 0.45)
                }
                Capsule().fill(Color.lfbText).frame(width: CGFloat(model.position / d) * w, height: 4)
                Circle().fill(Color.lfbText)
                    .overlay(Circle().stroke(Color.lfbRaised, lineWidth: 2))
                    .frame(width: 16, height: 16)
                    .offset(x: CGFloat(model.position / d) * w - 8)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                LongPressGesture(minimumDuration: 0.35)
                    .sequenced(before: DragGesture(minimumDistance: 0))
                    .onChanged { value in
                        guard case .second(true, let drag?) = value else { return }
                        let t = min(max(Double(drag.location.x / w) * d, 0), d)
                        let start = loopStart ?? min(max(Double(drag.startLocation.x / w) * d, 0), d)
                        loopStart = start
                        if abs(t - start) > 0.25 { model.setLoopRange(min(start, t)...max(start, t)) }
                    }
                    .onEnded { _ in loopStart = nil }
                    .exclusively(before: DragGesture(minimumDistance: 0).onChanged { g in
                        model.seek(to: min(max(Double(g.location.x / w) * d, 0), d))
                    })
            )
        }
        .frame(height: 28)
        .accessibilityElement()
        .accessibilityLabel("Playhead")
        .accessibilityValue("\(formatTimecode(model.position)) of \(formatTimecode(model.duration))")
        .accessibilityAdjustableAction { dir in
            model.nudgePlayhead(by: dir == .increment ? 5 : -5)
        }
    }
}

/// A lane's overlays shared by the cards and the tabletop lanes: loop range, playhead, and the
/// sweep while this track (or the whole song) is being written.
struct DuoLaneOverlay: View {
    @Bindable var model: ProjectViewModel
    let track: TrackID

    var body: some View {
        GeometryReader { geo in
            let d = max(model.duration, 1)
            ZStack(alignment: .topLeading) {
                if let r = model.loopRange, model.isLoopEnabled {
                    Rectangle().fill(Color.lfbAccentWash)
                        .frame(width: CGFloat((r.upperBound - r.lowerBound) / d) * geo.size.width)
                        .offset(x: CGFloat(r.lowerBound / d) * geo.size.width)
                }
                if model.isGenerating || model.rewritingTrack == track {
                    SweepView(color: track.color)
                }
                Rectangle().fill(Color.lfbText).frame(width: 1.5)
                    .offset(x: CGFloat(model.position / d) * geo.size.width)
            }
        }
        .allowsHitTesting(false)
    }
}
#endif
