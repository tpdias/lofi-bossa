import SwiftUI

/// Making a new project, in two steps, on every layout:
/// 1. **Style**: Lo-Fi or Bossa Nova as two illustrated cards, or a scene preset that fills in
///    everything at once.
/// 2. **Your song**: name and length, the feel (busyness, note length, groove, dynamics), key and
///    tempo, the background sound, and the seed.
///
/// Shown as a sheet from `AdaptiveRootView` (New Project, ⌘N, the + buttons) and inline as the
/// first-launch screen when the library is empty (`welcome`), where there is nothing to cancel.
/// The accent follows the chosen style, as it does in the project.
struct NewProjectFlow: View {
    var welcome = false
    var onCancel: (() -> Void)? = nil

    @Environment(AppSession.self) private var session
    @State private var draft = ProjectDraft()
    @State private var step = Step.style

    enum Step { case style, song }

    private var status: GeneratorStatus { session.generator.currentStatus }

    var body: some View {
        GeometryReader { geo in
            let wide = geo.size.width >= 680
            VStack(spacing: 0) {
                header(wide: wide)
                ScrollView {
                    Group {
                        switch step {
                        case .style:
                            StyleStep(draft: $draft, welcome: welcome, wide: wide) { go(.song) }
                                .transition(.asymmetric(insertion: .move(edge: .leading), removal: .move(edge: .leading))
                                    .combined(with: .opacity))
                        case .song:
                            SongStep(draft: $draft, wide: wide)
                                .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .trailing))
                                    .combined(with: .opacity))
                        }
                    }
                    .padding(.horizontal, wide ? LFBSpace.xl : LFBSpace.lg)
                    .padding(.bottom, LFBSpace.xl)
                    .frame(maxWidth: 920)
                    .frame(maxWidth: .infinity)
                }
                .scrollBounceBehavior(.basedOnSize)
                Divider()
                footer(wide: wide)
            }
        }
        .background(Color.lfbWindow)
        .environment(\.lfbTheme, LFBTheme(draft.style))
        .tint(LFBTheme(draft.style).accent)
        #if os(macOS)
        // A sheet takes its minimum size (the GeometryReader has no ideal one): wide enough for
        // the two-column layout.
        .frame(minWidth: welcome ? nil : 760, minHeight: welcome ? nil : 640)
        #endif
    }

    private func go(_ next: Step) {
        withAnimation(.snappy(duration: 0.3)) { step = next }
    }

    // MARK: Header and footer

    private func header(wide: Bool) -> some View {
        HStack(spacing: LFBSpace.md) {
            if welcome && step == .style {
                SaudadeMark(size: 28)
                SaudadeWordmark(size: 20)
            } else {
                Text(step == .style ? "New Project" : "Your song")
                    .font(.lfbTitle)
                    .accessibilityAddTraits(.isHeader)
            }
            Spacer()
            StepDots(current: step == .style ? 0 : 1)
            if let onCancel {
                Button("Cancel", action: onCancel)
                    .buttonStyle(.plain).font(.lfbBodyMedium).foregroundStyle(Color.lfbTextSecondary)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("new-project-cancel")
            }
        }
        .padding(.horizontal, wide ? LFBSpace.xl : LFBSpace.lg)
        .padding(.vertical, LFBSpace.md)
    }

    private func footer(wide: Bool) -> some View {
        HStack(spacing: LFBSpace.sm) {
            if step == .song {
                Button { go(.style) } label: { Label("Back", systemImage: "chevron.left") }
                    .buttonStyle(LFBChipStyle(capsule: true))
                    .accessibilityIdentifier("new-project-back")
            }
            if wide || step == .style {
                GeneratorStatusPill(status: status)
                    .frame(maxWidth: .infinity)
            } else {
                Spacer(minLength: 0)
            }
            switch step {
            case .style:
                Button { go(.song) } label: { Label("Next", systemImage: "chevron.right").labelStyle(TrailingIconLabelStyle()) }
                    .buttonStyle(LFBPrimaryButtonStyle(capsule: true))
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("new-project-next")
            case .song:
                Button("Create Empty") { session.createProject(from: draft, generate: false) }
                    .buttonStyle(LFBChipStyle(capsule: true))
                    .accessibilityHint("Makes the project without writing any music yet")
                    .accessibilityIdentifier("new-project-create")
                Button { session.createProject(from: draft, generate: true) } label: {
                    Label("Generate", systemImage: "sparkles")
                }
                .buttonStyle(LFBPrimaryButtonStyle(capsule: true))
                .disabled(!isReady)
                .keyboardShortcut(.defaultAction)
                .accessibilityHint("Makes the project and writes its first take")
                .accessibilityInputLabels(["Generate", "Make music"])
                .accessibilityIdentifier("new-project-generate")
            }
        }
        .padding(.horizontal, wide ? LFBSpace.xl : LFBSpace.lg)
        .padding(.vertical, LFBSpace.md)
        .background(Color.lfbSurface.ignoresSafeArea(edges: .bottom))
    }

    private var isReady: Bool {
        if case .ready = status { return true }
        return false
    }
}

private struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) { configuration.title; configuration.icon }
    }
}

private struct StepDots: View {
    let current: Int
    @Environment(\.lfbTheme) private var theme
    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<2) { i in
                Capsule().fill(i == current ? theme.accent : Color.lfbControlHairline)
                    .frame(width: i == current ? 18 : 7, height: 7)
            }
        }
        .animation(.snappy, value: current)
        .accessibilityElement()
        .accessibilityLabel(L("Step \(current + 1) of 2"))
    }
}

// MARK: - Step 1: style

private struct StyleStep: View {
    @Binding var draft: ProjectDraft
    let welcome: Bool
    let wide: Bool
    let next: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: LFBSpace.xl) {
            VStack(alignment: .leading, spacing: LFBSpace.xs) {
                Text(welcome ? "Make your first track" : "What are we making?")
                    .font(.system(size: wide ? 30 : 26, weight: .bold, design: .rounded))
                    .accessibilityAddTraits(.isHeader)
                Text("Pick a style. The model writes piano, guitar, bass and drums in it, and you can mix, rework and export the song.")
                    .font(.lfbBody).foregroundStyle(Color.lfbTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, LFBSpace.sm)

            let layout = wide ? AnyLayout(HStackLayout(spacing: LFBSpace.lg)) : AnyLayout(VStackLayout(spacing: LFBSpace.md))
            layout {
                ForEach(MusicStyle.allCases) { style in
                    StyleCard(style: style, isSelected: draft.style == style, tall: wide) {
                        withAnimation(.snappy) { draft.style = style }
                    }
                    .simultaneousGesture(TapGesture(count: 2).onEnded { draft.style = style; next() })
                }
            }

            VStack(alignment: .leading, spacing: LFBSpace.sm) {
                Text("Or start from a scene").font(.lfbHeadline)
                Text("A mood in one tap: style, tempo, key, feel and background sound, all set for you.")
                    .font(.lfbCaption).foregroundStyle(Color.lfbTextSecondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: LFBSpace.sm) {
                        ForEach(ScenePreset.all) { preset in
                            SceneCard(preset: preset) {
                                draft.apply(preset)
                                next()
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }
}

private struct StyleCard: View {
    let style: MusicStyle
    let isSelected: Bool
    let tall: Bool
    let action: () -> Void

    private var theme: LFBTheme { LFBTheme(style) }

    private var blurb: String {
        style == .lofi
            ? L("Electric piano, soft guitar, round bass and a dusty kit, with tape warmth and a little vinyl.")
            : L("Nylon guitar, grand piano, upright bass and light percussion, with an open, airy room.")
    }

    private var tags: [String] {
        style == .lofi ? [L("Slow and hazy"), L("Swung beats"), L("Jazzy chords")]
                       : [L("Sunny"), L("Syncopated"), L("Brazilian swing")]
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                StyleArt(style: style)
                    .frame(height: tall ? 170 : 120)
                    .overlay(alignment: .topTrailing) {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(isSelected ? Color.white : Color.white.opacity(0.7))
                            .shadow(color: .black.opacity(0.3), radius: 3)
                            .padding(LFBSpace.md)
                    }
                VStack(alignment: .leading, spacing: 6) {
                    Text(style.title).font(.system(size: 20, weight: .bold, design: .rounded))
                    Text(blurb).font(.lfbBody).foregroundStyle(Color.lfbTextSecondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        ForEach(tags, id: \.self) { tag in
                            Text(tag).font(.lfbCaption)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(theme.wash, in: Capsule())
                                .foregroundStyle(theme.accent)
                        }
                    }
                    .padding(.top, 2)
                }
                .padding(LFBSpace.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color.lfbSurface)
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18)
                .strokeBorder(isSelected ? theme.accent : Color.lfbControlHairline, lineWidth: isSelected ? 3 : 1))
            .shadow(color: .black.opacity(isSelected ? 0.14 : 0.06), radius: isSelected ? 12 : 4, y: isSelected ? 6 : 2)
            .scaleEffect(isSelected ? 1 : 0.985)
            .contentShape(RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(style.title)
        .accessibilityHint(blurb)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("style-\(style.rawValue)")
    }
}

/// A small painting for each style: a dusk window for Lo-Fi, a sunny shore for Bossa Nova,
/// with the four tracks' colors as bars along the bottom.
private struct StyleArt: View {
    let style: MusicStyle

    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            let rect = CGRect(origin: .zero, size: size)
            switch style {
            case .lofi:
                ctx.fill(Path(rect), with: .linearGradient(
                    Gradient(colors: [Color(hex: "#241640"), Color(hex: "#5B3A9E"), Color(hex: "#E08A5A")]),
                    startPoint: .zero, endPoint: CGPoint(x: 0, y: h)))
                // stars
                for i in 0..<14 {
                    let x = CGFloat((i * 73) % 100) / 100 * w
                    let y = CGFloat((i * 37) % 45) / 100 * h
                    ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 2, height: 2)), with: .color(.white.opacity(0.7)))
                }
                // a low, striped sun
                let r = min(w, h) * 0.34
                let sun = CGRect(x: w * 0.62 - r, y: h * 0.78 - r, width: 2 * r, height: 2 * r)
                var stripes = ctx
                stripes.clip(to: Path(ellipseIn: sun))
                stripes.fill(Path(sun), with: .linearGradient(
                    Gradient(colors: [Color(hex: "#FFD27A"), Color(hex: "#F0784A")]),
                    startPoint: CGPoint(x: 0, y: sun.minY), endPoint: CGPoint(x: 0, y: sun.maxY)))
                for k in 0..<5 {
                    let y = sun.midY + CGFloat(k) * r * 0.2
                    stripes.fill(Path(CGRect(x: sun.minX, y: y, width: sun.width, height: r * 0.06 + CGFloat(k) * 1.5)),
                                 with: .color(Color(hex: "#5B3A9E").opacity(0.85)))
                }
                // rain on the window
                for i in 0..<18 {
                    let x = CGFloat((i * 53) % 100) / 100 * w
                    let y = CGFloat((i * 29) % 70) / 100 * h
                    var p = Path(); p.move(to: CGPoint(x: x, y: y)); p.addLine(to: CGPoint(x: x - 3, y: y + 10))
                    ctx.stroke(p, with: .color(.white.opacity(0.25)), lineWidth: 1)
                }
            case .bossa:
                ctx.fill(Path(rect), with: .linearGradient(
                    Gradient(colors: [Color(hex: "#7FD3CC"), Color(hex: "#F6E3B4")]),
                    startPoint: .zero, endPoint: CGPoint(x: 0, y: h * 0.7)))
                let r = min(w, h) * 0.2
                ctx.fill(Path(ellipseIn: CGRect(x: w * 0.25 - r, y: h * 0.2, width: 2 * r, height: 2 * r)),
                         with: .color(Color(hex: "#FFC94D")))
                // the sea, in three waves
                for k in 0..<3 {
                    let top = h * (0.55 + CGFloat(k) * 0.1)
                    var p = Path()
                    p.move(to: CGPoint(x: 0, y: top))
                    stride(from: 0, through: w, by: 4).forEach { x in
                        p.addLine(to: CGPoint(x: x, y: top + sin(x / w * .pi * 4 + CGFloat(k)) * 4))
                    }
                    p.addLine(to: CGPoint(x: w, y: h)); p.addLine(to: CGPoint(x: 0, y: h)); p.closeSubpath()
                    ctx.fill(p, with: .color([Color(hex: "#2FA39B"), Color(hex: "#0B7A78"), Color(hex: "#085F5D")][k]))
                }
            }
            // the four tracks, as note bars
            let bars: [(TrackID, CGFloat)] = [(.piano, 0.5), (.guitar, 0.75), (.bass, 0.35), (.drums, 0.6)]
            let barW: CGFloat = 8, gap: CGFloat = 5
            for (i, (id, height)) in bars.enumerated() {
                let bh = h * 0.28 * height
                let x = LFBSpace.lg + CGFloat(i) * (barW + gap)
                ctx.fill(Path(roundedRect: CGRect(x: x, y: h - LFBSpace.md - bh, width: barW, height: bh), cornerRadius: 3),
                         with: .color(id.color))
            }
        }
        .accessibilityHidden(true)
    }
}

private struct SceneCard: View {
    let preset: ScenePreset
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: preset.symbol).foregroundStyle(LFBTheme(preset.style).accent)
                        .frame(width: 20)
                    Text(LocalizedStringKey(preset.name)).font(.lfbHeadline)
                }
                Text(LocalizedStringKey(preset.blurb)).font(.lfbCaption).foregroundStyle(Color.lfbTextSecondary)
                    .lineLimit(2).multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Text("\(preset.style.title) · \(Int(preset.tempo)) BPM")
                    .font(.lfbCaption).foregroundStyle(Color.lfbTextTertiary)
            }
            .padding(LFBSpace.md)
            .frame(width: 190, height: 112, alignment: .topLeading)
            .background(Color.lfbSurface, in: RoundedRectangle(cornerRadius: LFBRadius.card))
            .overlay(RoundedRectangle(cornerRadius: LFBRadius.card).strokeBorder(Color.lfbControlHairline))
            .contentShape(RoundedRectangle(cornerRadius: LFBRadius.card))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Fills in every setting for this mood")
        .accessibilityIdentifier("scene-\(preset.id)")
    }
}

// MARK: - Step 2: the song's settings

private struct SongStep: View {
    @Binding var draft: ProjectDraft
    let wide: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: LFBSpace.lg) {
            HStack(spacing: LFBSpace.sm) {
                StyleBadge(style: draft.style)
                Text("Everything here can be changed later in the project.")
                    .font(.lfbCaption).foregroundStyle(Color.lfbTextSecondary)
            }
            .padding(.top, LFBSpace.sm)
            if wide {
                HStack(alignment: .top, spacing: LFBSpace.lg) {
                    VStack(spacing: LFBSpace.lg) { song; keyAndTempo; seed }
                    VStack(spacing: LFBSpace.lg) { feel; background }
                }
            } else {
                VStack(spacing: LFBSpace.lg) { song; feel; keyAndTempo; background; seed }
            }
        }
    }

    private var song: some View {
        SetupCard(title: "Song", symbol: "music.note") {
            TextField("Untitled", text: $draft.name, prompt: Text("Name (optional)"))
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Name")
                .accessibilityIdentifier("new-project-name")
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Length").font(.lfbBodyMedium)
                    Spacer()
                    Text(formatTimecode(draft.length)).font(.lfbBodyMedium).monospacedDigit()
                }
                Slider(value: $draft.length, in: ProjectDraft.lengthRange, step: 15)
                    .accessibilityLabel("Length").accessibilityValue(formatTimecode(draft.length))
                    .accessibilityIdentifier("new-project-length")
                Text("Shorter songs are written faster.").font(.lfbCaption).foregroundStyle(Color.lfbTextTertiary)
            }
        }
    }

    private var feel: some View {
        SetupCard(title: "Feel", symbol: "slider.horizontal.3") {
            SetupSlider(title: "Busyness", low: "Sparse", high: "Busy", id: "busyness", value: $draft.busyness)
            SetupSlider(title: "Note length", low: "Short", high: "Long", id: "noteLength", value: $draft.noteLength)
            SetupSlider(title: "Groove", low: "Loose", high: "Tight", id: "groove", value: $draft.groove)
            SetupSlider(title: "Dynamics", low: "Flat", high: "Expressive", id: "dynamics", value: $draft.dynamics)
        }
    }

    private var keyAndTempo: some View {
        SetupCard(title: "Key and tempo", symbol: "metronome") {
            HStack {
                Text("Key").font(.lfbBodyMedium)
                Spacer()
                Picker("Key", selection: $draft.key) {
                    Text("Auto").tag(String?.none)
                    Divider()
                    ForEach(MusicKey.names, id: \.self) { Text(MusicKey.display($0)).tag(Optional($0)) }
                }
                .pickerStyle(.menu).labelsHidden().fixedSize()
                .accessibilityIdentifier("new-project-key")
            }
            if draft.key != nil {
                Toggle("Only notes in the key", isOn: $draft.strictKey)
                    .checkboxToggleStyle().font(.lfbBody)
            } else {
                Text("Auto: the model picks one, and it's detected from what it writes.")
                    .font(.lfbCaption).foregroundStyle(Color.lfbTextTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HStack {
                Text("Tempo").font(.lfbBodyMedium)
                Spacer()
                Toggle("Auto", isOn: Binding(get: { draft.tempo == nil }, set: { draft.tempo = $0 ? nil : 84 }))
                    .checkboxToggleStyle().font(.lfbCaption)
                    .accessibilityIdentifier("new-project-tempo-auto")
            }
            if let bpm = draft.tempo {
                HStack(spacing: LFBSpace.sm) {
                    Slider(value: Binding(get: { bpm }, set: { draft.tempo = $0.rounded() }), in: Project.tempoRange, step: 1)
                        .accessibilityLabel("Tempo").accessibilityValue("\(Int(bpm)) beats per minute")
                    Text("\(Int(bpm)) BPM").font(.lfbBodyMedium).monospacedDigit().frame(minWidth: 64, alignment: .trailing)
                }
            } else {
                Text("Detected from the song").font(.lfbCaption).foregroundStyle(Color.lfbTextTertiary)
            }
        }
    }

    private var background: some View {
        SetupCard(title: "Background", symbol: "cloud.rain") {
            Text("A bed of sound under the music while it plays.")
                .font(.lfbCaption).foregroundStyle(Color.lfbTextSecondary)
            BackgroundSoundPicker(background: $draft.background)
        }
    }

    private var seed: some View {
        SetupCard(title: "Seed", symbol: "dice") {
            Picker("Seed", selection: Binding(
                get: { draft.seed == nil },
                set: { draft.seed = $0 ? nil : (draft.seed ?? UInt32.random(in: 1...999_999)) })) {
                Text("New each time").tag(true)
                Text("Fixed").tag(false)
            }
            .pickerStyle(.segmented).labelsHidden()
            .accessibilityIdentifier("new-project-seed-mode")
            if let seed = draft.seed {
                HStack(spacing: LFBSpace.sm) {
                    TextField("Seed", value: Binding(get: { seed }, set: { draft.seed = $0 }),
                              format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder).monospacedDigit()
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif
                        .accessibilityIdentifier("new-project-seed")
                    Button { draft.seed = UInt32.random(in: 1...999_999) } label: { Image(systemName: "dice") }
                        .buttonStyle(LFBChipStyle(capsule: true))
                        .accessibilityLabel("Roll a new seed")
                }
                Text("The same seed and settings write the same song, so a take can be made again.")
                    .font(.lfbCaption).foregroundStyle(Color.lfbTextTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Every Generate rolls a new seed. Each take shows its seed, so a favorite can be pinned later.")
                    .font(.lfbCaption).foregroundStyle(Color.lfbTextTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct StyleBadge: View {
    let style: MusicStyle
    var body: some View {
        let theme = LFBTheme(style)
        Label(style.title, systemImage: style == .lofi ? "moon.stars" : "sun.max")
            .font(.lfbBodyMedium)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(theme.wash, in: Capsule())
            .foregroundStyle(theme.accent)
    }
}

private struct SetupCard<Content: View>: View {
    let title: LocalizedStringKey
    let symbol: String
    @ViewBuilder var content: Content
    @Environment(\.lfbTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: LFBSpace.md) {
            Label { Text(title).font(.lfbHeadline) } icon: {
                Image(systemName: symbol).foregroundStyle(theme.accent)
            }
            .accessibilityAddTraits(.isHeader)
            content
        }
        .padding(LFBSpace.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.lfbSurface, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.lfbHairline))
    }
}

private struct SetupSlider: View {
    let title: LocalizedStringKey
    let low: LocalizedStringKey
    let high: LocalizedStringKey
    let id: String
    @Binding var value: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.lfbBodyMedium)
            HStack(spacing: LFBSpace.sm) {
                Text(low).font(.lfbCaption).foregroundStyle(Color.lfbTextTertiary)
                Slider(value: $value, in: 0...1)
                    .accessibilityLabel(title)
                    .accessibilityValue("\(Int(value * 100)) percent, \(low) to \(high)")
                    .accessibilityIdentifier("new-project-\(id)")
                Text(high).font(.lfbCaption).foregroundStyle(Color.lfbTextTertiary)
            }
        }
    }
}
