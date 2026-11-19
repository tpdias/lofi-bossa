import SwiftUI

/// The stage: recipe bar, banner, ruler, four track rows (or compact rows + piano roll),
/// transport. See design artboards "Project · loaded song" and "Project · empty".
struct ProjectStageView: View {
    @Bindable var model: ProjectViewModel
    @Binding var showInspector: Bool
    @State private var showExportSheet = false
    @State private var windowWidth: CGFloat = 1100

    private var snapshot: SongSnapshot? { model.displayedSnapshot }

    var body: some View {
        VStack(spacing: 0) {
            RecipeBar(model: model, isCompact: windowWidth < 1100)
            Divider()
            banner
            if let snapshot {
                if model.isListeningToPastVersion, let v = model.listeningVersion {
                    ListeningBanner(version: v, onBack: model.backToCurrentVersion, onRestore: model.restoreListeningVersion)
                }
                RulerAndTracks(model: model, snapshot: snapshot)
            } else {
                EmptyProjectView(model: model)
            }
            Divider()
            TransportBar(model: model, onExport: { showExportSheet = true })
        }
        .background(GeometryReader { geo in
            Color.clear.onAppear { windowWidth = geo.size.width }
                .onChange(of: geo.size.width) { windowWidth = $0 }
        })
        .background(Color.lfbWindow)
        .sheet(isPresented: $showExportSheet) { ExportSheetView(model: model) }
        .focusedSceneValue(\.projectModel, model)   // lets the menu bar act on this project
        .toolbar {
            ToolbarItem(placement: .principal) { ProjectTitle(model: model) }
            ToolbarItemGroup(placement: .primaryAction) {
                // ⌘Z / ⇧⌘Z live in the Edit menu (AppCommands), which can also name what it undoes.
                Button(action: model.undo) { Image(systemName: "arrow.uturn.backward") }
                    .disabled(!model.canUndo).help(model.undoTitle.map { "Undo \($0) (⌘Z)" } ?? "Undo (⌘Z)")
                Button(action: model.redo) { Image(systemName: "arrow.uturn.forward") }
                    .disabled(!model.canRedo).help(model.redoTitle.map { "Redo \($0) (⇧⌘Z)" } ?? "Redo (⇧⌘Z)")
                Button { showExportSheet = true } label: { Label("Export", systemImage: "square.and.arrow.up") }
                    .disabled(snapshot == nil)
                Button { showInspector.toggle() } label: { Image(systemName: "sidebar.trailing") }
                    .help("Show or hide the inspector (⌥⌘I)")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .lfbExport)) { _ in
            if snapshot != nil { showExportSheet = true }
        }
    }

    @ViewBuilder private var banner: some View {
        switch model.status {
        case .starting where snapshot == nil: EmptyView()   // the empty-project card already explains this
        case .starting: StartingBanner()
        case .offline(let reason):
            OfflineBanner(reason: reason, onRestart: { Task { try? await model.generator.restart() } },
                         onShowLog: { showLog() })
        case .ready:
            switch model.phase {
            case .generating(let startedAt, let seed):
                GeneratingBanner(style: model.project.style, length: model.project.lengthSeconds,
                                 seed: seed, startedAt: startedAt, onCancel: model.cancelGenerate)
            case .failed(let message, let detail, let trackScope) where trackScope == nil:
                GenerationErrorBanner(message: message, detail: detail, onRetry: { model.dismissError(); model.generate() })
            default: EmptyView()
            }
        }
    }

    private func showLog() {
        let panel = NSAlert()
        panel.messageText = "Generator Log"
        panel.informativeText = model.generator.fullLog.isEmpty ? "No output yet." : model.generator.fullLog
        panel.addButton(withTitle: "Copy")
        panel.addButton(withTitle: "OK")
        if panel.runModal() == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(model.generator.fullLog, forType: .string)
        }
    }
}

private struct ProjectTitle: View {
    @Bindable var model: ProjectViewModel
    @State private var isRenaming = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if isRenaming {
                TextField("Name", text: $draft, onCommit: { model.rename(to: draft); isRenaming = false })
                    .textFieldStyle(.plain).font(.lfbTitle).multilineTextAlignment(.center)
                    .focused($focused).frame(width: 220)
            } else {
                Text(model.project.name).font(.lfbTitle)
                    .onTapGesture { draft = model.project.name; isRenaming = true; focused = true }
            }
            Text(subtitle).font(.lfbCaption).foregroundStyle(Color.lfbTextSecondary)
                .lineLimit(1).minimumScaleFactor(0.85)
                .accessibilityIdentifier("project-subtitle")
        }
        // The toolbar draws a capsule around this; without padding and a natural width the
        // subtitle ran under its rounded ends ("o-Fi · 0:46 · ... Saved" cut at both sides).
        .padding(.horizontal, 14)
        .fixedSize(horizontal: true, vertical: false)
    }

    private var subtitle: String {
        let versionPart = model.project.current.map { "Version \($0.number)" } ?? "Not generated yet"
        let saveState: String
        switch model.project.id {
        default: saveState = "Saved"   // ProjectStore's saveState is global; "Saved" reads fine per-project in practice
        }
        return "\(model.project.style.title) · \(formatTimecode(model.project.lengthSeconds)) · \(versionPart) · \(saveState)"
    }
}

private struct ListeningBanner: View {
    let version: Version
    let onBack: () -> Void
    let onRestore: () -> Void
    var body: some View {
        BannerView(tint: .lfbAccent) {
            Image(systemName: "waveform").foregroundStyle(Color.lfbAccent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Listening to version \(version.number).").font(.lfbBodyMedium)
                Text(version.kind.title).font(.lfbCaption).foregroundStyle(Color.lfbTextSecondary)
            }
            Spacer()
            Button("Back to Current", action: onBack).buttonStyle(.plain).font(.lfbCaption).foregroundStyle(Color.lfbAccentText)
            Button("Restore This Version", action: onRestore).buttonStyle(.borderedProminent).controlSize(.small)
        }
    }
}

// MARK: - Recipe bar

private struct RecipeBar: View {
    @Bindable var model: ProjectViewModel
    let isCompact: Bool

    var body: some View {
        HStack(spacing: LFBSpace.md) {
            Picker("Style", selection: Binding(get: { model.project.style }, set: { model.setStyle($0) })) {
                ForEach(MusicStyle.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()

            HStack(spacing: LFBSpace.sm) {
                Text("Length").foregroundStyle(Color.lfbTextSecondary).fixedSize()
                Slider(value: Binding(get: { model.project.lengthSeconds }, set: { model.setLength($0) }), in: 15...180, step: 15)
                    .frame(width: 140)
                Text(formatTimecode(model.project.lengthSeconds)).monospacedDigit().frame(width: 36, alignment: .leading)
            }

            SeedField(model: model)

            if !isCompact {
                ModelPopup(model: model)
            }

            Spacer()

            Button {
                model.generate()
            } label: {
                HStack(spacing: 6) {
                    if model.isGenerating { ProgressView().controlSize(.small) } else { Image(systemName: "sparkles") }
                    Text(model.project.hasGenerated ? (model.isGenerating ? "Generating…" : "Generate New Take")
                         : (model.isGenerating ? "Generating…" : "Generate"))
                }
                .frame(minWidth: 130)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(model.isGeneratorBusy || isWaitingForGenerator)
            .accessibilityIdentifier("generate")
        }
        .padding(.horizontal, LFBSpace.lg)
        .frame(height: LFBSize.recipeBarHeight)
    }

    private var isWaitingForGenerator: Bool {
        if case .ready = model.status { return false }
        return true
    }
}

private struct SeedField: View {
    @Bindable var model: ProjectViewModel
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 4) {
            Button {
                if model.isDiceOn, let current = model.displaySeed { model.pinSeed(current) }
                else { model.clearPinnedSeed() }
            } label: {
                Image(systemName: "dice").foregroundStyle(model.isDiceOn ? Color.lfbAccent : Color.lfbTextSecondary)
            }
            .buttonStyle(.plain).help("Random seed every time")

            TextField("Random", text: Binding(
                get: { focused ? text : (model.displaySeed.map(String.init) ?? "") },
                set: { text = $0 }
            ), onCommit: {
                if let v = UInt32(text) { model.pinSeed(v) }
                focused = false
            })
            .textFieldStyle(.plain).monospacedDigit().frame(width: 72)
            .focused($focused)
            .onChange(of: focused) { if $0 { text = model.displaySeed.map(String.init) ?? "" } }

            Button { model.copySeedToPasteboard() } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.plain).disabled(model.displaySeed == nil).help("Copy Seed")
        }
        .padding(.horizontal, 8).frame(height: LFBSize.controlHeight)
        .background(Color.lfbWell, in: RoundedRectangle(cornerRadius: LFBRadius.button))
    }
}

private struct ModelPopup: View {
    @Bindable var model: ProjectViewModel
    var body: some View {
        Picker("Model", selection: Binding(get: { model.project.model }, set: { model.setModel($0) })) {
            ForEach(NoteModel.allCases) { choice in
                if choice == .fineTuned && !model.hasFinetunedForStyle {
                    Text("Not available for \(model.project.style.title) yet").tag(choice).disabled(true)
                } else {
                    Text(choice.title).tag(choice)
                }
            }
        }
        .pickerStyle(.menu).fixedSize()
        .help(model.hasFinetunedForStyle
              ? "Which weights write the notes (a testing control)"
              : "\(model.project.style.title) has no fine-tuned model yet, so the pretrained one is used")
    }
}

// MARK: - Empty project

private struct EmptyProjectView: View {
    @Bindable var model: ProjectViewModel
    var body: some View {
        VStack(spacing: 0) {
            ForEach(TrackID.allCases) { id in
                HStack(spacing: 0) {
                    HStack(spacing: 8) {
                        TrackGlyph(id: id)
                        Text(id.title).font(.lfbHeadline)
                        Spacer()
                    }
                    .padding(.horizontal, LFBSpace.md)
                    .frame(width: LFBSize.trackHeaderWidth, alignment: .leading)
                    Divider()
                    ZStack {
                        HatchedLane(color: id.color)
                        if model.isGenerating { SweepView(color: id.color) }
                    }
                }
                .frame(minHeight: LFBSize.trackRowMinHeight)
                .overlay(alignment: .bottom) { Divider() }
            }
        }
        .overlay {
            // While the whole-song banner above already explains what is happening, this card
            // would be a second, confusing "Generate" prompt, so it only shows when idle.
            if !model.isGenerating {
                VStack(spacing: LFBSpace.sm) {
                    Text("Nothing written yet").font(.lfbTitle)
                    Text("Press Generate to write piano, guitar, bass and drums.")
                        .font(.lfbBody).foregroundStyle(Color.lfbTextSecondary)
                    Button { model.generate() } label: { Label("Generate", systemImage: "sparkles") }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                        .disabled(model.isGeneratorBusy)
                }
                .padding(LFBSpace.xl)
                .background(Color.lfbRaised, in: RoundedRectangle(cornerRadius: LFBRadius.card))
                .shadow(color: .black.opacity(0.1), radius: 8, y: 2)
            }
        }
    }
}

private struct HatchedLane: View {
    let color: Color
    var body: some View {
        Canvas { ctx, size in
            let step: CGFloat = 10
            var x: CGFloat = -size.height
            while x < size.width {
                var path = Path()
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x + size.height, y: 0))
                ctx.stroke(path, with: .color(color.opacity(0.12)), lineWidth: 1)
                x += step
            }
        }
        .background(Color.lfbSurface)
    }
}

// MARK: - Ruler, playhead, loop range, track rows

private struct RulerAndTracks: View {
    @Bindable var model: ProjectViewModel
    let snapshot: SongSnapshot
    @State private var dragStart: Double?
    @FocusState private var stageFocused: Bool

    private var duration: Double { max(snapshot.lengthSeconds, 1) }
    private var laneX: CGFloat { LFBSize.trackHeaderWidth + 1 }

    var body: some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                ruler
                Divider()
                if model.isPianoRollOpen {
                    VStack(spacing: 0) {
                        ForEach(TrackID.allCases) { id in compactRow(id) }
                    }
                    Divider()
                    if let track = model.editingTrack {
                        PianoRollView(model: model, track: track)
                    }
                } else {
                    VStack(spacing: 0) {
                        ForEach(TrackID.allCases) { id in fullRow(id) }
                    }
                }
            }
            overlay
                // While the roll is open the playhead there belongs to the roll's own (zoomed)
                // time axis, so the stage's overlay covers only the ruler and the compact rows.
                .frame(height: model.isPianoRollOpen
                       ? LFBSize.rulerHeight + 1 + 4 * LFBSize.trackRowCompactHeight : nil,
                       alignment: .top)
        }
        // Section shortcuts. Handled here, not as Edit-menu key equivalents, because Cut/Copy/Paste
        // there belong to the text fields (seed, rename) and must keep working in them.
        .focusable()
        .focused($stageFocused)
        .focusEffectDisabled()
        .onKeyPress(phases: .down, action: handleKey)
        .onChange(of: model.sectionSelection) { _, selection in
            if selection != nil { stageFocused = true }
        }
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        guard model.canEditSections else { return .ignored }
        let command = press.modifiers.contains(.command)
        if model.sectionSelection != nil {
            switch press.key {
            case .escape: model.clearSectionSelection(); return .handled
            case .delete, .deleteForward: model.deleteSection(); return .handled
            default: break
            }
        }
        guard command else { return .ignored }
        switch press.characters.lowercased() {
        case "x" where model.sectionSelection != nil: model.cutSection(); return .handled
        case "c" where model.sectionSelection != nil: model.copySection(); return .handled
        case "d" where model.sectionSelection != nil: model.duplicateSection(); return .handled
        case "v" where model.canPasteSection: model.pasteSection(); return .handled
        default: return .ignored
        }
    }

    private func fullRow(_ id: TrackID) -> some View {
        TrackRowView(
            track: trackBinding(id), duration: duration,
            isSelected: model.selectedTrack == id,
            isDimmedBySolo: model.isDimmedBySolo(id),
            isRewriting: model.rewritingTrack == id,
            rewritingRange: model.rewritingTrack == id ? model.rewritingRange : nil,
            isGeneratorBusy: model.isGeneratorBusy,
            onSeek: { model.seek(to: $0) },
            onSelect: { model.openEditor(for: id) },
            onRewrite: { model.rewrite(id) },
            onCancelRewrite: model.cancelRewrite,
            onResetEffects: { model.resetTrackEffects(for: id) },
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

    private func compactRow(_ id: TrackID) -> some View {
        TrackRowView(
            track: trackBinding(id), duration: duration,
            isSelected: model.editingTrack == id,
            isRewriting: model.rewritingTrack == id,
            isGeneratorBusy: model.isGeneratorBusy,
            compact: true,
            onSeek: { model.seek(to: $0) },
            onSelect: { model.openEditor(for: id) }
        )
    }

    private func trackBinding(_ id: TrackID) -> Binding<Track> {
        Binding(
            get: { model.displayedSnapshot?.track(id) ?? Track(id: id, instrument: id.defaultInstrument) },
            set: { newValue in
                if newValue.isMuted != model.displayedSnapshot?.track(id).isMuted { model.setMuted(newValue.isMuted, for: id) }
                if newValue.isSoloed != model.displayedSnapshot?.track(id).isSoloed { model.setSoloed(newValue.isSoloed, for: id) }
                if newValue.volume != model.displayedSnapshot?.track(id).volume { model.setVolume(newValue.volume, for: id) }
                if newValue.instrument != model.displayedSnapshot?.track(id).instrument { model.setInstrument(newValue.instrument, for: id) }
                if newValue.effects != model.displayedSnapshot?.track(id).effects { model.setTrackEffects(newValue.effects, for: id) }
            }
        )
    }

    private var ruler: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: laneX)
            GeometryReader { geo in
                Canvas { ctx, size in
                    let step = labelStep
                    var t = 0.0
                    while t <= duration {
                        let x = CGFloat(t / duration) * size.width
                        var tick = Path()
                        tick.move(to: CGPoint(x: x, y: size.height - 6))
                        tick.addLine(to: CGPoint(x: x, y: size.height))
                        ctx.stroke(tick, with: .color(.lfbTextTertiary))
                        ctx.draw(Text(formatTimecode(t)).font(.lfbCaption).foregroundStyle(.secondary),
                                 at: CGPoint(x: x + 3, y: size.height - 14), anchor: .leading)
                        t += step
                    }
                }
                .contentShape(Rectangle())
                .gesture(rangeDrag(width: geo.size.width))
            }
        }
        .frame(height: LFBSize.rulerHeight)
        .background(Color.lfbSurface)
    }

    private var labelStep: Double {
        duration <= 30 ? 5 : (duration <= 90 ? 15 : 30)
    }

    private func rangeDrag(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { g in
                if dragStart == nil { dragStart = Double(g.startLocation.x / width) * duration }
                let a = dragStart ?? 0
                let b = Double(g.location.x / width) * duration
                model.setLoopRange(min(a, b)...max(a, b, min(a,b) + 0.5))
            }
            .onEnded { _ in dragStart = nil }
            .exclusively(before: SpatialTapGesture().onEnded { tap in
                model.seek(to: Double(tap.location.x / width) * duration)
            })
    }

    private var overlay: some View {
        GeometryReader { geo in
            let laneW = max(geo.size.width - laneX, 1)
            ZStack(alignment: .topLeading) {
                if model.isLoopEnabled, let range = model.loopRange {
                    Color.lfbAccentWash
                        .frame(width: CGFloat((range.upperBound - range.lowerBound) / duration) * laneW)
                        .offset(x: laneX + CGFloat(range.lowerBound / duration) * laneW)
                }
                Rectangle().fill(Color.lfbText.opacity(0.7)).frame(width: 1.5)
                    .offset(x: laneX + CGFloat(min(model.position / duration, 1)) * laneW - 0.75)
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Transport

private struct TransportBar: View {
    @Bindable var model: ProjectViewModel
    let onExport: () -> Void

    var body: some View {
        HStack(spacing: LFBSpace.lg) {
            GeneratorStatusPill(status: model.status)

            Spacer()

            HStack(spacing: LFBSpace.md) {
                Button { model.seek(to: 0) } label: { Image(systemName: "backward.end.fill") }
                    .buttonStyle(.plain).disabled(model.displayedSnapshot == nil)
                    .help("Go to start (⌥⌘←)")
                Button(action: model.togglePlay) {
                    Image(systemName: model.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: LFBSize.playButton))
                        .foregroundStyle(Color.lfbAccent)
                }
                .buttonStyle(.plain).disabled(model.displayedSnapshot == nil)
                .keyboardShortcut(.space, modifiers: [])
                .accessibilityIdentifier("play").accessibilityLabel(model.isPlaying ? "Pause" : "Play")
                .help(model.isPlaying ? "Pause (Space)" : "Play (Space)")
                Button { model.toggleLoop() } label: { Image(systemName: "repeat") }
                    .buttonStyle(.plain)
                    .foregroundStyle(model.isLoopEnabled ? Color.lfbAccent : Color.lfbTextSecondary)
                    .disabled(model.loopRange == nil)
                    .help("Loop the selection (⌘L)")
                Text("\(formatTimecode(model.position)) / \(formatTimecode(model.duration))")
                    .font(.lfbTimecode).frame(width: 110)
            }

            Spacer()

            HStack(spacing: LFBSpace.sm) {
                if let range = model.loopRange {
                    HStack(spacing: 4) {
                        Text("Loop · \(formatTimecode(range.lowerBound)) – \(formatTimecode(range.upperBound))")
                            .font(.lfbCaption)
                        Button { model.clearLoop() } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).font(.caption)
                    }
                    .padding(.horizontal, 10).frame(height: 24)
                    .background(Color.lfbWell, in: Capsule())
                }
            }
        }
        .padding(.horizontal, LFBSpace.lg)
        .frame(height: LFBSize.transportHeight)
        .background(Color.lfbSurface)
    }
}
