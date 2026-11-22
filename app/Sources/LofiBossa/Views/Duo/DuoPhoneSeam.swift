#if os(iOS)
import SwiftUI

// MARK: - SEAM: iPhone components
//
// The Duo's left page uses the iPhone's recipe strip and track cards (HANDOFF §6.2). Those are
// being written in `Views/Phone/` on another branch (claude/iphone-layout-…). Until that
// merges, these two minimal Duo-local views stand in for them. After it merges, swap the
// bodies of `DuoRecipeStrip` and `DuoTrackCards` for the iPhone views (keeping the Duo-only
// behaviour noted on each) and delete the rest of this file. Nothing else in Views/Duo
// depends on what is inside them.

/// Stand-in for the iPhone recipe strip (`.m-strip`, §5.2 item 2): Style menu, Length, Seed
/// (dice tinted when on), and New take / Generate.
struct DuoRecipeStrip: View {
    @Bindable var model: ProjectViewModel
    @State private var showSeed = false
    @State private var seedDraft = ""

    private static let lengths: [Double] = [15, 30, 45, 60, 75, 90, 120, 150, 180]

    var body: some View {
        HStack(spacing: 8) {
            Menu {
                Picker("Style", selection: Binding(get: { model.project.style }, set: model.setStyle)) {
                    ForEach(MusicStyle.allCases) { Text($0.title).tag($0) }
                }
            } label: {
                chip { Text(model.project.style.title); Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.lfbTextTertiary) }
            }
            .accessibilityLabel("Style, \(model.project.style.title)")

            Menu {
                Picker("Length", selection: Binding(get: { model.project.lengthSeconds }, set: model.setLength)) {
                    ForEach(Self.lengths, id: \.self) { Text(formatTimecode($0)).tag($0) }
                }
            } label: {
                chip { Text(formatTimecode(model.project.lengthSeconds)).monospacedDigit() }
            }
            .accessibilityLabel("Length, \(formatTimecode(model.project.lengthSeconds))")

            Button { seedDraft = model.displaySeed.map(String.init) ?? ""; showSeed = true } label: {
                chip(tinted: model.isDiceOn) {
                    Image(systemName: "dice").font(.system(size: 13))
                    Text(model.displaySeed.map(String.init) ?? "Random").monospacedDigit()
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(model.isDiceOn ? "Seed, random" : "Seed \(model.displaySeed.map(String.init) ?? "")")
            .popover(isPresented: $showSeed) { seedPopover.presentationCompactAdaptation(.popover) }

            Spacer(minLength: 0)

            Button(action: model.generate) {
                Label(model.status == .starting ? "Waiting…" : (model.displayedSnapshot == nil ? "Generate" : "New take"),
                      systemImage: "sparkles")
                    .font(.system(size: 14, weight: .semibold))
                    .padding(.horizontal, 14).frame(height: LFBPhoneSize.chipHeight)
                    .foregroundStyle(model.canGenerate ? Color.lfbOnAccent : Color.lfbTextTertiary)
                    .background(model.canGenerate ? Color.lfbAccent : Color.lfbWell, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!model.canGenerate)
        }
        .lineLimit(1)
        .padding(.horizontal, 16).padding(.top, 2).padding(.bottom, 8)
    }

    private func chip<C: View>(tinted: Bool = false, @ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 5) { content() }
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(tinted ? Color.lfbAccentText : Color.lfbText)
            .padding(.horizontal, 12).frame(height: LFBPhoneSize.chipHeight)
            .background(tinted ? Color.lfbAccentWash : Color.lfbControl, in: Capsule())
            .shadow(color: .black.opacity(tinted ? 0 : 0.08), radius: 1.5, y: 1)
            .fixedSize()
    }

    private var seedPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("New seed on every take", isOn: Binding(
                get: { model.isDiceOn },
                set: { on in
                    if on { model.clearPinnedSeed() }
                    else if let s = model.displaySeed { model.pinSeed(s) }
                }))
            HStack {
                TextField("Seed", text: $seedDraft).keyboardType(.numberPad).textFieldStyle(.roundedBorder)
                    .onSubmit { if let s = UInt32(seedDraft) { model.pinSeed(s) } }
                Button("Use") { if let s = UInt32(seedDraft) { model.pinSeed(s) } }.disabled(UInt32(seedDraft) == nil)
                Button("Copy", action: model.copySeedToPasteboard).disabled(model.displaySeed == nil)
            }
        }
        .padding(16).frame(width: 300)
    }
}

/// Stand-in for the iPhone track cards (`.m-card`, short variant, §5.3). Duo-only behaviour to
/// keep when swapping: "Edit notes" opens the right page's Notes tab (`model.openEditor`)
/// instead of pushing an editor, and the card being edited is outlined in its track colour.
struct DuoTrackCards: View {
    @Bindable var model: ProjectViewModel

    var body: some View {
        let ids = model.displayedSnapshot?.trackIDs ?? TrackID.core
        GeometryReader { geo in
            // Four cards share the height; with added tracks (up to seven) they scroll.
            let spacing: CGFloat = 8
            let fit = (geo.size.height - spacing * CGFloat(ids.count - 1)) / CGFloat(max(ids.count, 1))
            let height = max(fit, 84)
            ScrollView {
                VStack(spacing: spacing) {
                    ForEach(ids) { id in
                        DuoTrackCard(model: model, id: id).frame(height: height)
                    }
                }
            }
            .scrollDisabled(fit >= 84)
        }
        .padding(.horizontal, 16).padding(.bottom, 10)
    }
}

struct DuoTrackCard: View {
    @Bindable var model: ProjectViewModel
    let id: TrackID

    private var track: Track? { model.displayedSnapshot?.track(id) }
    private var isEditing: Bool { model.isPianoRollOpen && model.editingTrack == id }
    private var isMuted: Bool { track?.isMuted ?? false }
    private var isSoloed: Bool { track?.isSoloed ?? false }
    private var isRewriting: Bool { model.rewritingTrack == id }

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                TrackGlyph(id: id, size: 30).opacity(isMuted ? 0.5 : 1)
                instrumentMenu
                Spacer(minLength: 0)
                key(isRewriting ? "stop.fill" : "arrow.triangle.2.circlepath", on: false, label: isRewriting ? "Stop" : "Rewrite \(id.title)") {
                    isRewriting ? model.cancelRewrite() : model.rewrite(id)
                }
                .disabled(!isRewriting && (model.isGeneratorBusy || model.status != .ready || track == nil))
                key(text: "M", on: isMuted, fill: .lfbText, ink: .lfbWindow, label: "Mute \(id.title)") {
                    model.setMuted(!isMuted, for: id)
                }
                key(text: "S", on: isSoloed, fill: .lfbAccent, ink: .lfbOnAccent, label: "Solo \(id.title)") {
                    model.setSoloed(!isSoloed, for: id)
                }
            }
            .frame(height: 36)
            .disabled(track == nil)

            ZStack {
                RoundedRectangle(cornerRadius: LFBPhoneSize.laneRadius).fill(Color.lfbWell)
                if let track, !track.notes.isEmpty {
                    NoteLaneView(notes: track.notes, duration: model.duration,
                                 color: model.isAudible(id) ? id.color : Color.lfbTextTertiary.opacity(0.45),
                                 onSeek: model.seek(to:))
                        .opacity(isRewriting ? 0.2 : 1)
                } else if track != nil, !model.isGeneratorBusy {
                    EmptyLane(trackName: id.title.lowercased()) { model.rewrite(id) }
                }
                DuoLaneOverlay(model: model, track: id)
                if isRewriting {
                    RewritePill(text: "Rewriting the \(id.title.lowercased())…", action: model.cancelRewrite)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: LFBPhoneSize.laneRadius))
        }
        .padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 8)
        .background(Color.lfbSurface, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(isEditing ? id.color : .clear, lineWidth: 2.5))
        .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
        .contextMenu {
            Button { model.openEditor(for: id) } label: { Label("Edit Notes", systemImage: "pianokeys") }
            Button { model.rewrite(id) } label: { Label("Rewrite", systemImage: "arrow.triangle.2.circlepath") }
                .disabled(model.isGeneratorBusy || model.status != .ready)
        }
        .accessibilityAction(named: "Mute") { model.setMuted(!isMuted, for: id) }
        .accessibilityAction(named: "Solo") { model.setSoloed(!isSoloed, for: id) }
        .accessibilityAction(named: "Rewrite") { model.rewrite(id) }
        .accessibilityAction(named: "Edit notes") { model.openEditor(for: id) }
    }

    /// Tap the name: instrument, volume and Edit notes (the iPhone's track sheet, as a menu here).
    private var instrumentMenu: some View {
        Menu {
            Picker("Instrument", selection: Binding(get: { track?.instrument ?? id.defaultInstrument },
                                                    set: { model.setInstrument($0, for: id) })) {
                ForEach(id.instruments, id: \.name) { Text($0.name).tag($0.name) }
            }
            Button { model.openEditor(for: id) } label: { Label("Edit Notes", systemImage: "pianokeys") }
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                Text(id.title).font(.system(size: 15, weight: .semibold, design: .rounded)).foregroundStyle(Color.lfbText)
                Text(track?.instrument ?? id.defaultInstrument).font(.system(size: 12)).foregroundStyle(Color.lfbTextSecondary)
            }
            .lineLimit(1)
            .opacity(isMuted ? 0.5 : 1)
            .frame(minHeight: LFBPhoneSize.minHitTarget)
        }
        .accessibilityLabel("\(id.title) track options")
    }

    private func key(_ symbol: String? = nil, text: String? = nil, on: Bool, fill: Color = .lfbControl, ink: Color = .lfbTextSecondary,
                     label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if let symbol { Image(systemName: symbol).font(.system(size: 15, weight: .semibold)) }
                else { Text(text ?? "").font(.system(size: 14, weight: .bold)) }
            }
            .foregroundStyle(on ? ink : Color.lfbTextSecondary)
            .frame(width: 36, height: 32)
            .background(on ? fill : Color.lfbControl, in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(on ? .clear : Color.lfbControlHairline, lineWidth: 1))
            .frame(width: 40, height: LFBPhoneSize.minHitTarget)   // padded hit area
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}
#endif
