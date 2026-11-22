#if os(iOS)
import SwiftUI

/// The right page's three panels (HANDOFF §2.2): Sound, Versions, Notes.
enum DuoPanel: String, CaseIterable, Identifiable {
    case sound = "Sound", versions = "Versions", notes = "Notes"
    var id: String { rawValue }
}

/// Right page of the unfolded Duo (`.d-page.r`): segmented Sound / Versions / Notes, then that
/// panel. The selected panel is not kept here but derived from the project's model
/// (`isPianoRollOpen`, `inspectorTab`), so it carries across folding: a pushed piano roll on the
/// closed Duo becomes the Notes tab when unfolded, and the Notes tab becomes the pushed editor
/// when folded (§2.3).
struct DuoPanelPage: View {
    @Bindable var model: ProjectViewModel

    private var panel: Binding<DuoPanel> {
        Binding(
            get: { model.isPianoRollOpen ? .notes : (model.inspectorTab == .versions ? .versions : .sound) },
            set: { new in
                switch new {
                case .notes:
                    guard !model.isPianoRollOpen, let snapshot = model.displayedSnapshot else { return }
                    let track = model.selectedTrack.flatMap { snapshot.hasTrack($0) ? $0 : nil } ?? snapshot.trackIDs.first ?? .piano
                    model.openEditor(for: track)
                case .sound, .versions:
                    if model.isPianoRollOpen { model.closeEditor() }
                    model.inspectorTab = new == .sound ? .sound : .versions
                }
            })
    }

    var body: some View {
        VStack(spacing: 10) {
            Picker("Panel", selection: panel) {
                ForEach(DuoPanel.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .controlSize(.large)

            switch panel.wrappedValue {
            case .sound: DuoSoundPane(model: model)
            case .versions: DuoVersionsPane(model: model)
            case .notes: DuoNotesPane(model: model)
            }
        }
        .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.lfbSurface, in: RoundedRectangle(cornerRadius: 22))
        .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
    }
}

// MARK: - Sound

/// The three effect cards (`.macro`), "Lo-Fi defaults, adjusted" with Reset, and while a take is
/// being written, a note that the sound stays usable (view "generating").
struct DuoSoundPane: View {
    @Bindable var model: ProjectViewModel

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                DuoEffectCards(model: model, layout: .stacked)
                HStack {
                    Text("\(model.project.style.title) defaults\(model.effectsAreAtStyleDefault ? "" : ", adjusted")")
                        .font(.system(size: 13)).foregroundStyle(Color.lfbTextSecondary)
                    Spacer()
                    Button("Reset", action: model.resetEffectsToStyleDefault)
                        .buttonStyle(DuoPillButtonStyle())
                        .disabled(model.effectsAreAtStyleDefault)
                }
                if model.isGenerating {
                    Text("Keep playing with the sound while the new take is written. Effects carry over to it.")
                        .font(.system(size: 13)).foregroundStyle(Color.lfbTextSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}

/// Warmth, Reverb and Vinyl. `.stacked` is the right page (64 pt, full width, with the
/// description); `.tall` is tabletop (three 112 pt cards side by side).
struct DuoEffectCards: View {
    enum Layout { case stacked, tall }
    @Bindable var model: ProjectViewModel
    let layout: Layout

    private var effects: MixEffects { model.displayedSnapshot?.effects ?? model.project.style.defaultEffects }

    private var items: [(title: String, caption: String, symbol: String, value: Binding<Double>)] {
        let e = effects
        return [
            ("Warmth", "Softens the highs", "sun.max",
             Binding(get: { e.warmth }, set: { model.setEffects(MixEffects(warmth: $0, reverb: e.reverb, vinyl: e.vinyl)) })),
            ("Reverb", "Room around the band", "dot.radiowaves.left.and.right",
             Binding(get: { e.reverb }, set: { model.setEffects(MixEffects(warmth: e.warmth, reverb: $0, vinyl: e.vinyl)) })),
            ("Vinyl", "Hiss and crackle", "record.circle",
             Binding(get: { e.vinyl }, set: { model.setEffects(MixEffects(warmth: e.warmth, reverb: e.reverb, vinyl: $0)) })),
        ]
    }

    var body: some View {
        switch layout {
        case .stacked:
            VStack(spacing: 10) {
                ForEach(items, id: \.title) { item in
                    EffectCard(title: item.title, caption: item.caption, symbol: item.symbol, amount: item.value)
                }
            }
        case .tall:
            HStack(spacing: 8) {
                ForEach(items, id: \.title) { item in
                    DuoTallEffectCard(title: item.title, symbol: item.symbol, amount: item.value)
                }
            }
        }
    }
}

/// Tabletop effect card: the same whole-card slider as `EffectCard`, 112 pt tall with the icon,
/// name and value stacked (`.macro` at height 112, column layout).
struct DuoTallEffectCard: View {
    let title: String
    let symbol: String
    @Binding var amount: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Color.lfbWell
                Rectangle().fill(Color.lfbAccentWash)
                    .frame(width: geo.size.width * amount)
                    .overlay(alignment: .trailing) { Rectangle().fill(Color.lfbAccent).frame(width: 2) }
                VStack(alignment: .leading, spacing: 4) {
                    Image(systemName: symbol).foregroundStyle(Color.lfbTextSecondary)
                    Text(title).font(.system(size: 16, weight: .semibold, design: .rounded))
                    Text("\(Int(amount * 100))").font(.system(size: 17, weight: .semibold, design: .rounded)).monospacedDigit()
                }
                .padding(.horizontal, 12)
            }
            .clipShape(RoundedRectangle(cornerRadius: LFBRadius.card))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                amount = min(max(g.location.x / geo.size.width, 0), 1)
            })
        }
        .frame(height: 112)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue("\(Int(amount * 100))")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: amount = min(amount + 0.05, 1)
            case .decrement: amount = max(amount - 0.05, 0)
            @unknown default: break
            }
        }
    }
}

// MARK: - Versions

/// Listening banner and the version list (`.ver`). Each row has its change bars, badges and a
/// 40 pt listen button that becomes Stop while listening; swipe a row to Keep it.
struct DuoVersionsPane: View {
    @Bindable var model: ProjectViewModel

    private static let time: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .none; f.timeStyle = .short; return f
    }()

    var body: some View {
        VStack(spacing: 8) {
            if model.isListeningToPastVersion, let v = model.listeningVersion {
                DuoListeningBanner(model: model, version: v).padding(.horizontal, -12).padding(.vertical, -6)
            }
            if model.project.versions.isEmpty {
                Text("No versions yet. Generate a take to start the history.")
                    .font(.system(size: 14)).foregroundStyle(Color.lfbTextSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                List {
                    ForEach(model.project.versions.sorted { $0.number > $1.number }) { version in
                        row(version)
                            .listRowInsets(EdgeInsets(top: 1, leading: 0, bottom: 1, trailing: 0))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .swipeActions(edge: .trailing) {
                                Button { model.toggleKept(version) } label: {
                                    Label(version.isKept ? "Unkeep" : "Keep", systemImage: version.isKept ? "star.slash" : "star")
                                }
                                .tint(Color.lfbCaution)
                            }
                    }
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
                    RoundedRectangle(cornerRadius: 1)
                        .fill(version.changedTracks.contains(id) ? id.color : Color.lfbControlHairline)
                        .frame(width: 4, height: 18)
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(version.kind.title).font(.system(size: 15, weight: .medium)).lineLimit(1)
                    if version.isKept { Image(systemName: "star.fill").font(.system(size: 11)).foregroundStyle(Color.lfbGuitarInk) }
                }
                Text("Version \(version.number) · \(Self.time.string(from: version.createdAt))")
                    .font(.system(size: 12)).foregroundStyle(Color.lfbTextTertiary).monospacedDigit()
            }
            Spacer(minLength: 4)
            if isCurrent { badge("Current", tint: .lfbTextSecondary) }
            if isListening { badge("Listening", tint: .lfbAccentText) }
            Button {
                isListening ? model.backToCurrentVersion() : model.listen(to: version)
            } label: {
                Image(systemName: isListening ? "stop.fill" : "play.fill").font(.system(size: 13))
                    .foregroundStyle(Color.lfbAccentText)
                    .frame(width: 40, height: 40)
                    .background(Color.lfbAccentWash, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isListening ? "Stop listening" : "Listen to version \(version.number)")
        }
        .padding(.leading, 8).padding(.trailing, 4).padding(.vertical, 5)
        .background(isListening ? Color.lfbAccentWash : .clear, in: RoundedRectangle(cornerRadius: 8))
    }

    private func badge(_ text: String, tint: Color) -> some View {
        Text(text).font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(tint.opacity(0.14), in: Capsule())
            .foregroundStyle(tint)
    }
}

// MARK: - Notes

/// The piano roll on the right page (view "edit"). The left page keeps every part visible and
/// audible with the edited card outlined.
///
/// SEAM: this hosts the shared `PianoRollView` (pointer-first, with its own Select / Draw, Snap
/// and loudness lane). When the iPhone branch lands its touch piano roll (one-finger scroll,
/// pinch zoom, long-press marquee; HANDOFF §5.5), use that here at 17 pt rows instead.
struct DuoNotesPane: View {
    @Bindable var model: ProjectViewModel

    var body: some View {
        if let track = model.editingTrack, model.displayedSnapshot?.hasTrack(track) == true {
            PianoRollView(model: model, track: track)   // has its own Done, which closes the editor
                .id(track)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.lfbHairline, lineWidth: 1))
        } else {
            Text("Generate a take, then pick a part to edit its notes.")
                .font(.system(size: 14)).foregroundStyle(Color.lfbTextSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}
#endif
