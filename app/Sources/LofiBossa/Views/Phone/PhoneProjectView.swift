import SwiftUI

#if os(iOS)
/// The sheets the project screen can show (HANDOFF §5.4). One at a time.
enum PhoneSheet: Identifiable, Hashable {
    case track(TrackID), sound, versions, export, log
    var id: String {
        switch self {
        case .track(let t): "track-\(t.rawValue)"
        case .sound: "sound"
        case .versions: "versions"
        case .export: "export"
        case .log: "log"
        }
    }
}

/// The iPhone project screen (HANDOFF §5.2, artboard "iPhone · project"): nav bar with Undo and
/// More, the recipe strip (or the banner that replaces it), the ruler, the track cards and the
/// floating transport. Sound, Versions, Track and Export are sheets; Edit notes pushes the roll.
struct PhoneProjectView: View {
    @Bindable var model: ProjectViewModel
    @Binding var exportOnOpen: Bool
    @Environment(ProjectStore.self) private var store
    @Environment(AppSession.self) private var session
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    @State private var sheet: PhoneSheet?
    @AppStorage("lfb.hapticBeat") private var hapticBeat = false
    @State private var renaming = false
    @State private var draftName = ""
    @State private var height: CGFloat = LFBDevice.iphone.height

    /// Below 760 pt (the Duo's outer display) the short variant applies (`.m-short`).
    private var isShort: Bool { height < LFBPhoneSize.shortVariantBelowHeight }
    private var snapshot: SongSnapshot? { model.displayedSnapshot }
    private var trackIDs: [TrackID] { snapshot?.trackIDs ?? TrackID.core }

    var body: some View {
        VStack(spacing: 0) {
            topArea
            if model.isListeningToPastVersion, let version = model.listeningVersion, sheet != .versions {
                PhoneListeningBanner(model: model, version: version).padding(.bottom, LFBSpace.md)
            }
            PhoneRuler(duration: model.duration)
                .padding(.horizontal, 28)
                .frame(height: 18)
            cards
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            PhoneTransport(model: model, isShort: isShort,
                           onSound: { sheet = .sound }, onVersions: { sheet = .versions })
                .padding(.horizontal, 10)
                .padding(.bottom, isShort ? 4 : 0)
        }
        .background(Color.lfbWindow)
        // The whole screen's height (the short variant is about the display, not the content area).
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height + $0.safeAreaInsets.top + $0.safeAreaInsets.bottom }) {
            height = $0
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .toolbarBackground(Color.lfbWindow, for: .navigationBar)
        .sheet(item: $sheet) { sheetContent($0) }
        .navigationDestination(isPresented: rollIsOpen) {
            if let track = model.editingTrack {
                PhonePianoRollView(model: model, track: track)
            }
        }
        .alert("Rename Project", isPresented: $renaming) {
            TextField("Name", text: $draftName)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { model.rename(to: draftName) }
        }
        .onAppear {
            if exportOnOpen { exportOnOpen = false; sheet = .export }
            if CommandLine.arguments.contains("--phone-sheet"), let i = CommandLine.arguments.firstIndex(of: "--phone-sheet"),
               CommandLine.arguments.count > i + 1 {
                // `--phone-sheet sound|versions|export|track` opens a sheet, for screenshot checks.
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    switch CommandLine.arguments[i + 1] {
                    case "sound": sheet = .sound
                    case "versions": sheet = .versions
                    case "export": sheet = .export
                    case "track": sheet = .track(.piano)
                    default: break
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .lfbExport)) { _ in
            if model.project.hasGenerated { sheet = .export }
        }
    }

    // MARK: Top: banner or recipe strip

    @ViewBuilder private var topArea: some View {
        switch model.status {
        case .starting:
            PhoneBanner(kind: .neutral, spinner: true, title: "Loading the music model…",
                        text: "A few seconds after launch.")
            PhoneRecipeStrip(model: model)
        case .offline:
            PhoneBanner(kind: .warning, icon: "exclamationmark.triangle.fill",
                        title: "The generator isn't running.", text: "Play, mix, edit and export still work.",
                        secondary: ("Details", { sheet = .log }),
                        primary: ("Restart", { Task { try? await model.generator.restart() } }))
            PhoneRecipeStrip(model: model)
        case .ready:
            switch model.phase {
            case .generating(let startedAt, _):
                PhoneGeneratingBanner(startedAt: startedAt, onCancel: model.cancelGenerate)
            case .failed(let message, let detail, let scope) where scope == nil:
                PhoneBanner(kind: .error, icon: "exclamationmark.triangle.fill", title: message,
                            text: "Your song is unchanged.",
                            secondary: detail == nil ? nil : ("Details", { sheet = .log }),
                            primary: ("Try again", { model.dismissError(); model.generate() }))
                PhoneRecipeStrip(model: model)
            default:
                PhoneRecipeStrip(model: model)
            }
        }
    }

    // MARK: Cards

    @ViewBuilder private var cards: some View {
        let list = VStack(spacing: isShort ? 6 : 8) {
            ForEach(trackIDs) { id in
                PhoneTrackCard(model: model, id: id, isShort: isShort,
                               isSelected: sheet == .track(id),
                               onOpenTrack: { sheet = .track(id) })
                    .frame(minHeight: isShort ? 84 : 96)
            }
        }
        .padding(.horizontal, LFBSpace.lg)
        .padding(.top, 4)
        .padding(.bottom, 10)

        if trackIDs.count > 4 {
            ScrollView { list }.scrollIndicators(.hidden)
        } else {
            list.frame(maxHeight: .infinity, alignment: .top)
        }
    }

    // MARK: Nav bar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            VStack(spacing: 0) {
                Text(model.project.name).font(.system(size: 16, weight: .semibold, design: .rounded)).lineLimit(1)
                Text(subtitle).font(.system(size: 12)).foregroundStyle(Color.lfbTextTertiary).lineLimit(1)
                    .accessibilityIdentifier("project-subtitle")
            }
            .onTapGesture { draftName = model.project.name; renaming = true }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button(action: model.undo) { Image(systemName: "arrow.uturn.backward") }
                .disabled(!model.canUndo || model.isGenerating)
                .accessibilityLabel(model.undoTitle.map { "Undo \($0)" } ?? "Undo")
                .accessibilityIdentifier("undo")
            moreMenu
        }
    }

    private var subtitle: String {
        guard model.project.hasGenerated else { return "\(model.project.style.title) · not generated yet" }
        let save: String
        switch store.saveState {
        case .saved: save = "Saved"
        case .saving: save = "Saving…"
        case .failed: save = "Not saved"
        }
        return "\(model.project.style.title) · \(formatTimecode(model.project.lengthSeconds)) · \(save)"
    }

    private var moreMenu: some View {
        Menu {
            Button("Export…", systemImage: "square.and.arrow.up") { sheet = .export }
                .disabled(!model.project.hasGenerated || model.isGenerating)
            Button("Redo", systemImage: "arrow.uturn.forward", action: model.redo)
                .disabled(!model.canRedo || model.isGenerating)
            Divider()
            Button("Rename", systemImage: "pencil") { draftName = model.project.name; renaming = true }
            Button("Duplicate", systemImage: "plus.square.on.square") { session.open(store.duplicate(model.project)) }
            Button("Copy Seed", systemImage: "doc.on.doc", action: model.copySeedToPasteboard)
                .disabled(model.displaySeed == nil)
            if model.canChangeTracks && !model.addableTracks.isEmpty {
                Menu("Add Track", systemImage: "plus") {
                    ForEach(model.addableTracks) { id in Button(id.title) { model.addTrack(id) } }
                }
            }
            Menu("Generation Options", systemImage: "cpu") {
                Picker("Model", selection: Binding(get: { model.project.model }, set: { model.setModel($0) })) {
                    ForEach(NoteModel.allCases) { choice in
                        if choice == .fineTuned && !model.hasFinetunedForStyle {
                            Text("Fine-tuned (not available for \(model.project.style.title) yet)").tag(choice)
                        } else {
                            Text(choice.title).tag(choice)
                        }
                    }
                }
            }
            if HapticSupport.isAvailable {
                Toggle("Haptic Beat", systemImage: "hand.tap", isOn: $hapticBeat)
            }
            Divider()
            Button("Delete", systemImage: "trash", role: .destructive) {
                let project = model.project
                model.pause()
                session.selection = .allProjects
                store.moveToTrash(project)
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .accessibilityLabel("More: export, rename, generation options")
        .accessibilityIdentifier("more")
    }

    // MARK: Sheets and the roll

    @ViewBuilder private func sheetContent(_ which: PhoneSheet) -> some View {
        Group {
            switch which {
            case .track(let id):
                PhoneTrackSheet(model: model, id: id, onEditNotes: {
                    sheet = nil
                    Task { try? await Task.sleep(for: .milliseconds(350)); model.openEditor(for: id) }
                })
                .presentationDetents([.medium, .large])
            case .sound:
                PhoneSoundSheet(model: model).presentationDetents([.medium])
            case .versions:
                PhoneVersionsSheet(model: model).presentationDetents([.medium, .large])
            case .export:
                PhoneExportSheet(model: model).presentationDetents([.medium])
            case .log:
                PhoneLogSheet(model: model).presentationDetents([.medium, .large])
            }
        }
        .presentationDragIndicator(.visible)
        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        .presentationCornerRadius(LFBPhoneSize.sheetRadius)
        .presentationBackground(Color.lfbRaised)
    }

    private var rollIsOpen: Binding<Bool> {
        Binding(get: { model.isPianoRollOpen },
                set: { if !$0 && model.isPianoRollOpen { model.closeEditor() } })
    }
}

// MARK: - Recipe strip

/// Capsule chips (HANDOFF §5.2): Style menu, Length, Seed, song settings (key, busyness, note
/// length), Extend, then the primary New take / Generate button. The chips scroll sideways when
/// they don't fit; the primary button stays put.
struct PhoneRecipeStrip: View {
    @Bindable var model: ProjectViewModel
    @State private var showLength = false
    @State private var showSeed = false
    @State private var showSettings = false

    private var isWaiting: Bool { if case .ready = model.status { false } else { true } }

    var body: some View {
        HStack(spacing: LFBSpace.sm) {
            ScrollView(.horizontal) {
                HStack(spacing: LFBSpace.sm) {
                    Menu {
                        Picker("Style", selection: Binding(get: { model.project.style }, set: { model.setStyle($0) })) {
                            ForEach(MusicStyle.allCases) { Text($0.title).tag($0) }
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Text(model.project.style.title)
                            Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color.lfbTextTertiary)
                        }
                    }
                    .buttonStyle(PhoneChipStyle())
                    .accessibilityLabel("Style, \(model.project.style.title)")

                    Button { showLength = true } label: { Text(formatTimecode(model.project.lengthSeconds)).monospacedDigit() }
                        .buttonStyle(PhoneChipStyle())
                        .accessibilityLabel("Length, \(formatTimecode(model.project.lengthSeconds))")
                        .popover(isPresented: $showLength) { lengthPopover }

                    Button { showSeed = true } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "dice")
                            Text(model.displaySeed.map(String.init) ?? "Random").monospacedDigit()
                        }
                    }
                    .buttonStyle(PhoneChipStyle(isOn: model.isDiceOn))
                    .accessibilityLabel("Seed, \(model.displaySeed.map(String.init) ?? "random")\(model.isDiceOn ? ", new every take" : "")")
                    .accessibilityIdentifier("seed-chip")
                    .popover(isPresented: $showSeed) { PhoneSeedPopover(model: model) }

                    Button { showSettings = true } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "tuningfork")
                            Text(model.musicSummary)
                        }
                    }
                    .buttonStyle(PhoneChipStyle())
                    .accessibilityLabel("Key, busyness and note length")
                    .accessibilityIdentifier("songSettings")
                    .popover(isPresented: $showSettings) { PhoneSongSettings(model: model) }

                    if model.project.hasGenerated {
                        Button { model.extend() } label: { Label("Extend", systemImage: "arrow.right.to.line") }
                            .buttonStyle(PhoneChipStyle())
                            .disabled(!model.canExtend || isWaiting)
                            .opacity(!model.canExtend || isWaiting ? 0.45 : 1)
                            .accessibilityHint("Continues the song for \(Int(ProjectViewModel.extendStep)) more seconds")
                            .accessibilityIdentifier("extend")
                    }
                }
                .padding(.vertical, 4)
                .padding(.horizontal, LFBSpace.lg)
            }
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
            .mask(LinearGradient(stops: [.init(color: .black, location: 0.94), .init(color: .clear, location: 1)],
                                 startPoint: .leading, endPoint: .trailing))

            Button { model.generate() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                    Text(model.status == .starting ? "Waiting…" : (model.project.hasGenerated ? "New take" : "Generate"))
                }
            }
            .buttonStyle(PhoneGenerateStyle())
            .disabled(model.isGeneratorBusy || isWaiting || !model.canGenerate)
            .accessibilityHint(model.lockedTracks.isEmpty ? "Writes a new take of every track"
                               : "Writes a new take around the locked tracks")
            .accessibilityIdentifier("generate")
            .padding(.trailing, LFBSpace.lg)
        }
        .padding(.top, 4)
        .padding(.bottom, LFBSpace.md)
    }

    private var lengthPopover: some View {
        VStack(alignment: .leading, spacing: LFBSpace.sm) {
            HStack {
                Text("Length").font(.lfbHeadline)
                Spacer()
                Text(formatTimecode(model.project.lengthSeconds)).font(.system(size: 17, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
            Slider(value: Binding(get: { model.project.lengthSeconds }, set: { model.setLength($0) }), in: 15...180, step: 15)
                .accessibilityLabel("Length")
            Text("For the next take. Extend makes the current song longer.")
                .font(.system(size: 12)).foregroundStyle(Color.lfbTextSecondary)
        }
        .padding(LFBSpace.lg)
        .frame(width: 280)
        .presentationCompactAdaptation(.popover)
    }
}

/// Seed popover: the dice toggle, the number and Copy (same rules as the Mac seed field).
struct PhoneSeedPopover: View {
    @Bindable var model: ProjectViewModel
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: LFBSpace.md) {
            Toggle(isOn: Binding(
                get: { model.isDiceOn },
                set: { on in
                    if on { model.clearPinnedSeed() } else if let s = model.displaySeed ?? UInt32(text) { model.pinSeed(s) }
                    else { model.pinSeed(UInt32.random(in: 0...99999)) }
                    text = model.displaySeed.map(String.init) ?? ""
                })) {
                Label("New seed every take", systemImage: "dice")
            }
            HStack(spacing: LFBSpace.sm) {
                TextField("Random", text: $text)
                    .keyboardType(.numberPad)
                    .monospacedDigit()
                    .focused($focused)
                    .padding(.horizontal, 12).frame(height: 40)
                    .background(Color.lfbWell, in: RoundedRectangle(cornerRadius: 10))
                    .onSubmit(commit)
                    .onChange(of: focused) { _, f in if !f { commit() } }
                Button { model.copySeedToPasteboard() } label: { Label("Copy", systemImage: "doc.on.doc") }
                    .buttonStyle(PhoneChipStyle())
                    .disabled(model.displaySeed == nil)
            }
            Text("The same seed, style, length and model write the same song. Typing a number keeps it.")
                .font(.system(size: 12)).foregroundStyle(Color.lfbTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(LFBSpace.lg)
        .frame(width: 300)
        .onAppear { text = model.displaySeed.map(String.init) ?? "" }
        .presentationCompactAdaptation(.popover)
    }

    private func commit() {
        if let v = UInt32(text.trimmingCharacters(in: .whitespaces)), v != model.project.pinnedSeed { model.pinSeed(v) }
    }
}

/// Key, strict key, busyness and note length for the next take or rewrite.
struct PhoneSongSettings: View {
    @Bindable var model: ProjectViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: LFBSpace.md) {
            HStack {
                Text("Key").font(.lfbBodyMedium)
                Spacer()
                Picker("Key", selection: Binding(get: { model.project.key ?? "Auto" },
                                                 set: { model.setKey($0 == "Auto" ? nil : $0) })) {
                    Text(model.project.key == nil && model.displayedKey != nil ? "Auto (\(model.displayedKey!))" : "Auto").tag("Auto")
                    ForEach(MusicKey.names, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.menu)
            }
            Toggle("Strict key", isOn: Binding(get: { model.project.isStrictKey }, set: { model.setStrictKey($0) }))
                .font(.lfbBodyMedium)
            Divider()
            slider("Busyness", low: "Sparse", high: "Busy",
                   value: Binding(get: { model.project.songBusyness }, set: { model.setBusyness($0) }), id: "busyness")
            slider("Note length", low: "Short", high: "Long",
                   value: Binding(get: { model.project.songNoteLength }, set: { model.setNoteLength($0) }), id: "noteLength")
            Divider()
            MusicSettingsSection(model: model)
            Text("Applies to the next take or rewrite. Your own edits are never limited. Each track can override these in its sheet.")
                .font(.system(size: 12)).foregroundStyle(Color.lfbTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(LFBSpace.lg)
        .frame(width: 310)
        .presentationCompactAdaptation(.popover)
    }

    private func slider(_ title: String, low: String, high: String, value: Binding<Double>, id: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.lfbBodyMedium)
            HStack(spacing: LFBSpace.sm) {
                Text(low).font(.lfbCaption).foregroundStyle(Color.lfbTextTertiary)
                Slider(value: value, in: 0...1).accessibilityLabel(title).accessibilityIdentifier(id)
                Text(high).font(.lfbCaption).foregroundStyle(Color.lfbTextTertiary)
            }
        }
    }
}

// MARK: - Banners

/// The rounded banner (`.m-root .ban`): neutral, warning or error, with up to two buttons.
struct PhoneBanner: View {
    enum Kind { case neutral, warning, error, ok }
    let kind: Kind
    var spinner = false
    var icon: String? = nil
    let title: String
    let text: String
    var secondary: (String, () -> Void)? = nil
    var primary: (String, () -> Void)? = nil
    var showsProgress = false

    private var tint: Color {
        switch kind {
        case .neutral: .lfbTextSecondary
        case .warning: .lfbCaution
        case .error: .lfbFailure
        case .ok: .lfbReady
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                if spinner { ProgressView().controlSize(.small) }
                if let icon { Image(systemName: icon).foregroundStyle(tint) }
                (Text(title).fontWeight(.semibold) + Text(" ") + Text(text).foregroundStyle(Color.lfbTextSecondary))
                    .font(.system(size: 14))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                if secondary == nil, let primary {   // one button fits on the text's line
                    Button(primary.0, action: primary.1).buttonStyle(PhoneChipStyle())
                }
            }
            if secondary != nil {
                HStack(spacing: 8) {
                    Spacer()
                    if let secondary {
                        Button(secondary.0, action: secondary.1).buttonStyle(PhoneChipStyle())
                    }
                    if let primary {
                        Button(primary.0, action: primary.1).buttonStyle(PhoneGenerateStyle())
                    }
                }
            }
            if showsProgress { PhoneIndeterminateBar() }
        }
        .padding(EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 10))
        .background(Color.lfbRaised, in: RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
        .padding(.horizontal, LFBSpace.lg)
        .padding(.bottom, LFBSpace.md)
        .accessibilityElement(children: .contain)
    }
}

/// Replaces the strip while a whole take is being written (HANDOFF §5.6).
struct PhoneGeneratingBanner: View {
    let startedAt: Date
    let onCancel: () -> Void
    var body: some View {
        TimelineView(.periodic(from: startedAt, by: 1)) { timeline in
            let elapsed = max(Int(timeline.date.timeIntervalSince(startedAt)), 0)
            PhoneBanner(kind: .neutral, spinner: true, title: "Writing a new take",
                        text: "\(elapsed) s so far, usually under a minute. Your current take is kept.",
                        primary: ("Cancel", onCancel), showsProgress: true)
        }
        .accessibilityIdentifier("generating-banner")
    }
}

/// A short accent bar that slides back and forth (no invented percentage); static under Reduce Motion.
struct PhoneIndeterminateBar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.lfbHairline)
                if reduceMotion {
                    Capsule().fill(Color.lfbAccent).frame(width: geo.size.width * 0.3)
                } else {
                    TimelineView(.animation) { t in
                        let phase = t.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
                        let x = (sin(phase * 2 * .pi - .pi / 2) + 1) / 2
                        Capsule().fill(Color.lfbAccent).frame(width: geo.size.width * 0.3)
                            .offset(x: geo.size.width * 0.7 * x)
                    }
                }
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }
}

/// "Listening to version N" with Back to current and Restore, on the project screen and in the
/// Versions sheet.
struct PhoneListeningBanner: View {
    @Bindable var model: ProjectViewModel
    let version: Version
    var body: some View {
        PhoneBanner(kind: .neutral, icon: "headphones", title: "Listening to version \(version.number).",
                    text: "Same spot in the song, so you can compare by ear.",
                    secondary: ("Back to current", model.backToCurrentVersion),
                    primary: ("Restore", model.restoreListeningVersion))
    }
}

// MARK: - Ruler

/// Time labels above the cards, aligned with the lanes (0:00 at the left edge, others centred).
struct PhoneRuler: View {
    let duration: Double
    var body: some View {
        GeometryReader { geo in
            let step = phoneLabelStep(for: duration)
            let count = Int(duration / step)
            ForEach(0...max(count, 0), id: \.self) { i in
                let t = Double(i) * step
                if t < duration - step * 0.3 || i == 0 {
                    Text(formatTimecode(t)).font(.system(size: 11)).monospacedDigit()
                        .foregroundStyle(Color.lfbTextTertiary)
                        .fixedSize()
                        .position(x: i == 0 ? 12 : CGFloat(t / max(duration, 1)) * geo.size.width,
                                  y: geo.size.height / 2)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// Binds a track's mix fields to the view model's setters (the same split the Mac stage uses).
@MainActor func phoneTrackBinding(_ model: ProjectViewModel, _ id: TrackID) -> Binding<Track> {
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
        })
}
#endif
