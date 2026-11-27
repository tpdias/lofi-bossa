import SwiftUI

#if os(iOS)
// The iPhone sheets (HANDOFF §5.4): Track, Sound, Versions, Export, and the generator log.
// Each one is presented by PhoneProjectView with a grabber and background interaction up to the
// medium detent, so playing and scrubbing keep working while the sheet is up.

// MARK: - Track

/// Instrument list, volume, Mute / Solo / Lock, the track's own effects and generation settings,
/// Edit notes and Rewrite (artboard "iPhone · track sheet").
struct PhoneTrackSheet: View {
    @Bindable var model: ProjectViewModel
    let id: TrackID
    var onEditNotes: () -> Void
    @Environment(\.dismiss) private var dismiss

    private var track: Track { model.displayedSnapshot?.track(id) ?? Track(id: id, instrument: id.defaultInstrument) }
    private var binding: Binding<Track> { phoneTrackBinding(model, id) }
    private var hasSong: Bool { model.displayedSnapshot != nil }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: LFBSpace.md) {
                    PhoneSheetHeader(title: LocalizedStringKey(id.title), leading: AnyView(TrackGlyph(id: id, size: 34)))
                    PhoneList {
                        ForEach(id.instruments, id: \.name) { option in
                            Button { binding.wrappedValue.instrument = option.name } label: {
                                HStack {
                                    Text(localizedName(option.name)).foregroundStyle(Color.lfbText)
                                    Spacer()
                                    if option.name == track.instrument {
                                        Image(systemName: "checkmark").foregroundStyle(Color.lfbAccentText)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(option.name == track.instrument ? .isSelected : [])
                        }
                    }
                    PhoneList {
                        HStack(spacing: 12) {
                            Image(systemName: "speaker.wave.2").foregroundStyle(Color.lfbTextSecondary)
                            Slider(value: binding.volume, in: 0...1).tint(id.color).accessibilityLabel("Volume")
                            Text("\(Int(track.volume * 100))").monospacedDigit().foregroundStyle(Color.lfbTextTertiary)
                                .frame(width: 30, alignment: .trailing)
                        }
                        HStack(spacing: 8) {
                            Button("Mute") { binding.wrappedValue.isMuted.toggle() }
                                .buttonStyle(PhoneKeyStyle(isOn: track.isMuted, size: CGSize(width: 96, height: 36)))
                                .frame(maxWidth: .infinity)
                            Button("Solo") { binding.wrappedValue.isSoloed.toggle() }
                                .buttonStyle(PhoneKeyStyle(isOn: track.isSoloed, onFill: .lfbAccent, onText: .lfbOnAccent,
                                                           size: CGSize(width: 96, height: 36)))
                                .frame(maxWidth: .infinity)
                            Button { binding.wrappedValue.isLocked.toggle() } label: {
                                Label("Lock", systemImage: track.isLocked ? "lock.fill" : "lock.open")
                            }
                            .buttonStyle(PhoneKeyStyle(isOn: track.isLocked, onFill: id.color, onText: .lfbWindow,
                                                       size: CGSize(width: 96, height: 36)))
                            .frame(maxWidth: .infinity)
                            .accessibilityHint("A locked track stays as it is on the next take; the others are written around it")
                        }
                    }
                    PhoneList {
                        NavigationLink {
                            PhoneTrackEffectsPage(model: model, id: id)
                        } label: {
                            row("slider.horizontal.3", "Effects and generation",
                                detail: track.effects.isNeutral && track.busyness == nil && track.noteLength == nil ? nil : "Adjusted",
                                chevron: true)
                        }
                        .buttonStyle(.plain)
                    }
                    PhoneList {
                        Button(action: onEditNotes) { row("pencil", "Edit notes", chevron: true) }
                            .buttonStyle(.plain).disabled(!hasSong)
                            .accessibilityIdentifier("edit-notes")
                        Button {
                            if model.rewritingTrack == id { model.cancelRewrite() } else { model.rewrite(id); dismiss() }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: model.rewritingTrack == id ? "stop.fill" : "arrow.triangle.2.circlepath")
                                    .foregroundStyle(Color.lfbTextSecondary).frame(width: 22)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(model.rewritingTrack == id ? L("Stop rewriting") : L("Rewrite this part"))
                                    Text("Fits it to the other parts · about 5 s").font(.system(size: 14))
                                        .foregroundStyle(Color.lfbTextTertiary)
                                }
                                Spacer()
                            }
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(model.rewritingTrack != id && (model.isGeneratorBusy || !hasSong || model.status != .ready))
                        if !id.isCore && model.canChangeTracks {
                            Button(role: .destructive) { model.removeTrack(id); dismiss() } label: {
                                row("trash", "Remove \(id.title)", tint: .lfbFailure)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .font(.system(size: 16))
                .padding(.horizontal, LFBSpace.lg)
                .padding(.bottom, LFBSpace.xl)
            }
            .background(Color.lfbRaised)
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    private func row(_ symbol: String, _ title: LocalizedStringKey, detail: LocalizedStringKey? = nil, chevron: Bool = false,
                     tint: Color = .lfbText) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).foregroundStyle(tint == .lfbText ? Color.lfbTextSecondary : tint).frame(width: 22)
            Text(title).foregroundStyle(tint)
            Spacer()
            if let detail { Text(detail).foregroundStyle(Color.lfbTextTertiary).font(.system(size: 14)) }
            if chevron { Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.lfbTextTertiary) }
        }
        .contentShape(Rectangle())
    }
}

/// The track's own effects (warmth, grit, echo, reverb, pan) and its busyness and note length,
/// the touch counterpart of the Mac's per-track effects popover.
struct PhoneTrackEffectsPage: View {
    @Bindable var model: ProjectViewModel
    let id: TrackID
    private var track: Binding<Track> { phoneTrackBinding(model, id) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LFBSpace.md) {
                HStack {
                    Spacer()
                    Button("Reset") { model.resetTrackEffects(for: id) }.buttonStyle(PhoneChipStyle())
                }
                card("Warmth", "Softens the highs", "thermometer.sun", track.effects.warmth)
                card("Grit", "Crunchy, worn-tape texture", "circle.grid.cross", track.effects.grit)
                card("Echo", "Repeats that fade away", "dot.radiowaves.left.and.right", track.effects.echo)
                card("Reverb", "Space around this part", "waveform.path.ecg", track.effects.reverb)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Pan").font(.lfbBodyMedium)
                    HStack {
                        Text("L").foregroundStyle(Color.lfbTextTertiary)
                        Slider(value: track.effects.pan, in: -1...1).tint(id.color).accessibilityLabel("Pan")
                        Text("R").foregroundStyle(Color.lfbTextTertiary)
                    }
                }
                Divider()
                override("Busyness", low: "Sparse", high: "Busy", value: track.busyness, song: model.project.songBusyness)
                override("Note length", low: "Short", high: "Long", value: track.noteLength, song: model.project.songNoteLength)
                Text("Busyness and note length apply to this track's next rewrite or take.")
                    .font(.system(size: 13)).foregroundStyle(Color.lfbTextTertiary)
            }
            .padding(.horizontal, LFBSpace.lg)
            .padding(.bottom, LFBSpace.xl)
        }
        .background(Color.lfbRaised)
        .navigationTitle("\(id.title) effects")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func card(_ title: LocalizedStringKey, _ caption: LocalizedStringKey, _ symbol: String, _ amount: Binding<Double>) -> some View {
        EffectCard(title: title, caption: caption, symbol: symbol, amount: amount)
            .frame(height: LFBTouchSize.effectCardHeight)
    }

    private func override(_ title: LocalizedStringKey, low: LocalizedStringKey, high: LocalizedStringKey, value: Binding<Double?>, song: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: Binding(get: { value.wrappedValue == nil }, set: { value.wrappedValue = $0 ? nil : song })) {
                Text(title).font(.lfbBodyMedium)
                Text("Same as song").font(.system(size: 12)).foregroundStyle(Color.lfbTextTertiary)
            }
            HStack {
                Text(low).font(.lfbCaption).foregroundStyle(Color.lfbTextTertiary)
                Slider(value: Binding(get: { value.wrappedValue ?? song }, set: { value.wrappedValue = $0 }), in: 0...1)
                    .tint(id.color).accessibilityLabel(title)
                Text(high).font(.lfbCaption).foregroundStyle(Color.lfbTextTertiary)
            }
        }
    }
}

// MARK: - Sound

/// The three master effect cards (76 pt, the whole card is the slider), Reset, and the
/// background sound.
struct PhoneSoundSheet: View {
    @Bindable var model: ProjectViewModel
    private var effects: MixEffects { model.currentEffects }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LFBSpace.md) {
                PhoneSheetHeader(title: "Sound") {
                    Button("Reset", action: model.resetEffectsToStyleDefault)
                        .buttonStyle(PhoneChipStyle())
                        .disabled(model.effectsAreAtStyleDefault)
                }
                card("Warmth", "Softens the highs", "sun.max", \.warmth)
                card("Reverb", "Room around the band", "dot.radiowaves.left.and.right", \.reverb)
                card("Vinyl", "Hiss and crackle", "record.circle", \.vinyl)
                Text(model.effectsAreAtStyleDefault ? "Drag anywhere on a card. \(model.project.style.title) defaults. Reset returns to them." : "Drag anywhere on a card. \(model.project.style.title) defaults, adjusted. Reset returns to them.")
                    .font(.system(size: 13)).foregroundStyle(Color.lfbTextTertiary)
                    .padding(.horizontal, 4)
                BackgroundSoundSection(model: model, minimumTileWidth: 76)
                    .padding(.top, LFBSpace.sm)
            }
            .padding(.horizontal, LFBSpace.lg)
            .padding(.bottom, LFBSpace.xl)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private func card(_ title: LocalizedStringKey, _ caption: LocalizedStringKey, _ symbol: String, _ key: WritableKeyPath<MixEffects, Double>) -> some View {
        EffectCard(title: title, caption: caption, symbol: symbol, amount: Binding(
            get: { effects[keyPath: key] },
            set: { var e = effects; e[keyPath: key] = $0; model.setEffects(e) }))
            .frame(height: LFBTouchSize.effectCardHeight)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .disabled(model.displayedSnapshot == nil)   // the background works before the first take
    }
}

// MARK: - Versions

/// The listening banner and the version list. Each row: change bars, title, "Version N · time",
/// badges and a 40 pt listen button that becomes Stop while listening. Swipe a row to Keep it.
struct PhoneVersionsSheet: View {
    @Bindable var model: ProjectViewModel

    private var versions: [Version] { model.project.versions.sorted { $0.number > $1.number } }
    private var todayCount: Int { versions.filter { Calendar.current.isDateInToday($0.createdAt) }.count }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .none; f.timeStyle = .short; return f
    }()
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .none; f.doesRelativeDateFormatting = true; return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            PhoneSheetHeader(title: "Versions") {
                if todayCount > 0 {
                    Text("\(todayCount) today").font(.system(size: 13)).foregroundStyle(Color.lfbTextSecondary)
                }
            }
            .padding(.horizontal, LFBSpace.lg)
            if let version = model.listeningVersion {
                PhoneListeningBanner(model: model, version: version)
                    .padding(.horizontal, -LFBSpace.lg + LFBSpace.lg)
            }
            if versions.isEmpty {
                ContentUnavailableView("No versions yet", systemImage: "clock.arrow.circlepath",
                                       description: Text("Generate a take to start the history."))
                Spacer()
            } else {
                List {
                    ForEach(versions) { version in
                        row(version)
                            .listRowBackground(version.id == model.listeningVersionID ? Color.lfbHairline : Color.clear)
                            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 12))
                            .listRowSeparator(.hidden)
                            .swipeActions(edge: .trailing) {
                                Button { model.toggleKept(version) } label: {
                                    Label(version.isKept ? L("Unkeep") : L("Keep"), systemImage: version.isKept ? "star.slash" : "star")
                                }
                                .tint(Color.lfbGuitar)
                            }
                    }
                    Text("Swipe a version for Keep. Restoring adds a new version on top.")
                        .font(.system(size: 13)).foregroundStyle(Color.lfbTextTertiary)
                        .listRowBackground(Color.clear).listRowSeparator(.hidden)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
    }

    private func row(_ version: Version) -> some View {
        let isCurrent = version.id == model.project.currentVersionID
        let isListening = version.id == model.listeningVersionID
        return HStack(spacing: 10) {
            HStack(spacing: 2) {
                ForEach(version.snapshot.trackIDs) { id in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(version.changedTracks.contains(id) ? id.color : Color.lfbControlHairline)
                        .frame(width: 4, height: 22)
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(version.kind.title).font(.system(size: 15, weight: .medium)).lineLimit(1)
                Text("Version \(version.number) · \(Self.dayLabel(version.createdAt))")
                    .font(.system(size: 12)).foregroundStyle(Color.lfbTextTertiary).monospacedDigit()
            }
            Spacer(minLength: 4)
            if version.isKept {
                Image(systemName: "star.fill").font(.system(size: 12)).foregroundStyle(Color.lfbGuitarInk)
                    .accessibilityLabel("Kept")
            }
            if isCurrent { badge("Current", accent: false) }
            if isListening { badge("Listening", accent: true) }
            Button {
                if isListening { model.backToCurrentVersion() } else { model.listen(to: version) }
            } label: {
                Image(systemName: isListening ? "stop.fill" : "play.fill").font(.system(size: 13))
                    .frame(width: 40, height: 40)
                    .background(Color.lfbWell, in: Circle())
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.lfbText)
            .accessibilityLabel(isListening ? L("Stop listening") : L("Listen to version \(version.number)"))
            .accessibilityIdentifier("version-play-\(version.number)")
        }
        .accessibilityElement(children: .contain)
    }

    private static func dayLabel(_ date: Date) -> String {
        Calendar.current.isDateInToday(date) ? timeFormatter.string(from: date)
            : "\(dayFormatter.string(from: date)) \(timeFormatter.string(from: date))"
    }

    private func badge(_ text: LocalizedStringKey, accent: Bool) -> some View {
        Text(text).font(.system(size: 10.5, weight: .semibold))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(accent ? Color.lfbAccentWash : Color.lfbHairline, in: Capsule())
            .foregroundStyle(accent ? Color.lfbAccentText : Color.lfbTextSecondary)
    }
}

// MARK: - Export

/// Format and range, then a determinate render, then Share… and Save to Files (HANDOFF §5.4, §8).
struct PhoneExportSheet: View {
    @Bindable var model: ProjectViewModel
    @State private var format: ProjectViewModel.ExportFormat = .m4a
    @State private var range: ProjectViewModel.ExportRange = .whole
    @State private var exportedHere = false
    @State private var savingToFiles = false
    @State private var showVideo = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                PhoneSheetHeader(title: "Export")
                Picker("Format", selection: $format) {
                    ForEach([ProjectViewModel.ExportFormat.wav, .m4a, .midi, .stems]) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Range", selection: $range) {
                    Text("Whole song · \(formatTimecode(model.duration))").tag(ProjectViewModel.ExportRange.whole)
                    Text(model.loopRange.map { L("Loop · \(formatTimecode($0.upperBound - $0.lowerBound))") } ?? L("Loop"))
                        .tag(ProjectViewModel.ExportRange.loop)
                }
                .pickerStyle(.segmented)
                .disabled(model.loopRange == nil)
                Text(format.note).font(.system(size: 13)).foregroundStyle(Color.lfbTextTertiary).padding(.horizontal, 4)
                ExportOptionsSection(model: model, format: format)
                Button("Video soundtrack…") { showVideo = true }

                if model.isExporting {
                    VStack(alignment: .leading, spacing: 8) {
                        PhoneIndeterminateBar()
                        Text("Rendering audio…").font(.system(size: 13)).foregroundStyle(Color.lfbTextSecondary)
                    }
                } else if exportedHere, let result = model.exportResult {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.lfbReady)
                        (Text("Exported").fontWeight(.semibold) + Text(verbatim: " ")
                         + Text(verbatim: "\(result.url.lastPathComponent) · \(ByteCountFormatter.string(fromByteCount: result.bytes, countStyle: .file))")
                            .foregroundStyle(Color.lfbTextSecondary))
                            .font(.system(size: 14))
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.lfbSurface, in: RoundedRectangle(cornerRadius: 16))
                    ShareLink(item: result.url) { Label("Share…", systemImage: "square.and.arrow.up") }
                        .buttonStyle(PhoneBigButtonStyle())
                    Button("Save to Files") { savingToFiles = true }
                        .buttonStyle(PhoneBigButtonStyle(secondary: true))
                        .fileMover(isPresented: $savingToFiles, file: result.url) { _ in }
                } else {
                    Button("Export") {
                        guard let url = model.chooseExportDestination(format: format) else { return }
                        exportedHere = true
                        Task { await model.export(format: format, range: range, to: url) }
                    }
                    .buttonStyle(PhoneBigButtonStyle())
                    .disabled(!model.canExport(range: range) || model.project.currentSnapshot == nil)
                    .accessibilityIdentifier("export-go")
                }
            }
            .padding(.horizontal, LFBSpace.lg)
            .padding(.bottom, LFBSpace.xl)
        }
        .scrollBounceBehavior(.basedOnSize)
        .onChange(of: format) { exportedHere = false }
        .onChange(of: range) { exportedHere = false }
        .sheet(isPresented: $showVideo) { VideoSoundtrackSheet(model: model) }
    }
}

// MARK: - Generator log ("Details")

struct PhoneLogSheet: View {
    @Bindable var model: ProjectViewModel

    private var text: String {
        var parts: [String] = []
        if case .failed(let message, let detail, _) = model.phase {
            parts.append(message)
            if let detail { parts.append(detail) }
        }
        if case .offline(let reason?) = model.status { parts.append(reason) }
        let log = model.generator.fullLog
        if !log.isEmpty { parts.append(log) }
        return parts.isEmpty ? L("No output yet.") : parts.joined(separator: "\n\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LFBSpace.md) {
            PhoneSheetHeader(title: "Details") {
                Button("Copy") { Pasteboard.copy(text) }.buttonStyle(PhoneChipStyle())
            }
            ScrollView {
                Text(text).font(.system(size: 13, design: .monospaced)).foregroundStyle(Color.lfbTextSecondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if case .offline = model.status {
                Button("Restart") { Task { try? await model.generator.restart() } }
                    .buttonStyle(PhoneBigButtonStyle())
            }
        }
        .padding(.horizontal, LFBSpace.lg)
        .padding(.bottom, LFBSpace.lg)
    }
}
#endif
