#if os(iOS)
import SwiftUI

/// Recipe bar, touch-sized (60 pt, 36 pt controls): Style, Length, Busyness, Key, Seed, Model
/// (wide windows only), Extend, Generate. One row when it fits, otherwise two (portrait).
struct PadRecipeBar: View {
    @Bindable var model: ProjectViewModel
    let showsModel: Bool
    @State private var showSongSettings = false

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: LFBSpace.md) {
                styleControl
                lengthControl
                busynessControl
                songSettingsControl
                PadSeedField(model: model)
                if showsModel { PadModelMenu(model: model) }
                Spacer(minLength: 0)
                extendButton
                generateButton
            }
            .padding(.horizontal, LFBSpace.lg)
            .frame(height: 60)

            VStack(spacing: LFBSpace.sm) {
                HStack(spacing: LFBSpace.md) {
                    styleControl
                    lengthControl
                    busynessControl
                    Spacer(minLength: 0)
                }
                HStack(spacing: LFBSpace.md) {
                    songSettingsControl
                    PadSeedField(model: model)
                    if showsModel { PadModelMenu(model: model) }
                    Spacer(minLength: 0)
                    extendButton
                    generateButton
                }
            }
            .padding(.horizontal, LFBSpace.lg)
            .padding(.vertical, 10)
        }
        .background(Color.lfbWindow)
    }

    private var styleControl: some View {
        Picker("Style", selection: Binding(get: { model.project.style }, set: { model.setStyle($0) })) {
            ForEach(MusicStyle.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented).labelsHidden().fixedSize()
    }

    private var lengthControl: some View {
        HStack(spacing: LFBSpace.sm) {
            Text("Length").foregroundStyle(Color.lfbTextSecondary).fixedSize()
            Slider(value: Binding(get: { model.project.lengthSeconds }, set: { model.setLength($0) }), in: 15...180, step: 15)
                .frame(width: 120)
                .accessibilityValue(formatTimecode(model.project.lengthSeconds))
            Text(formatTimecode(model.project.lengthSeconds)).monospacedDigit().frame(width: 40, alignment: .leading)
        }
        .font(.system(size: 15))
    }

    private var busynessControl: some View {
        HStack(spacing: LFBSpace.sm) {
            Text("Busyness").foregroundStyle(Color.lfbTextSecondary).fixedSize()
            Slider(value: Binding(get: { model.project.songBusyness }, set: { model.setBusyness($0) }), in: 0...1)
                .frame(width: 100)
                .accessibilityIdentifier("busyness")
        }
        .font(.system(size: 15))
    }

    private var songSettingsControl: some View {
        Button { showSongSettings.toggle() } label: {
            Label(model.musicSummary, systemImage: "tuningfork").lineLimit(1)
        }
        .buttonStyle(.bordered).fixedSize()
        .popover(isPresented: $showSongSettings, arrowEdge: .bottom) { PadSongSettings(model: model) }
        .accessibilityLabel("Key and note length")
        .accessibilityIdentifier("songSettings")
    }

    private var extendButton: some View {
        Button { model.extend() } label: { Label("Extend", systemImage: "arrow.right.to.line") }
            .buttonStyle(.bordered).fixedSize()
            .disabled(!model.canExtend || isWaitingForGenerator)
            .accessibilityHint("Continue the song for \(Int(ProjectViewModel.extendStep)) more seconds, every track at once")
            .accessibilityIdentifier("extend")
    }

    private var generateButton: some View {
        Button(action: model.generate) {
            HStack(spacing: 6) {
                if model.isGenerating || isStarting { ProgressView().controlSize(.small).tint(Color.lfbOnAccent) }
                else { Image(systemName: "sparkles") }
                Text(generateTitle)
            }
            .frame(minWidth: 150)
        }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.return, modifiers: .command)
        .disabled(model.isGeneratorBusy || isWaitingForGenerator || !model.canGenerate)
        .accessibilityHint(model.lockedTracks.isEmpty ? "Write a new take of every track"
                           : "Write a new take around the locked tracks")
        .accessibilityIdentifier("generate")
    }

    private var generateTitle: String {
        if model.isGenerating { return "Generating…" }
        if isStarting { return "Waiting for generator…" }
        return model.project.hasGenerated ? "Generate New Take" : "Generate"
    }

    private var isStarting: Bool { if case .starting = model.status { true } else { false } }
    private var isWaitingForGenerator: Bool { if case .ready = model.status { false } else { true } }
}

/// Key and note length for the next take or rewrite (the Mac's popover, touch-sized).
private struct PadSongSettings: View {
    @Bindable var model: ProjectViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: LFBSpace.md) {
            Text("Key, tempo & feel").font(.lfbTitle)
            HStack {
                Text("Key")
                Spacer()
                if model.project.key == nil, let detected = model.displayedKey {
                    Text(detected).foregroundStyle(Color.lfbTextSecondary)
                }
                Picker("Key", selection: Binding(get: { model.project.key ?? "Auto" },
                                                 set: { model.setKey($0 == "Auto" ? nil : $0) })) {
                    Text("Auto").tag("Auto")
                    ForEach(MusicKey.names, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
            }
            Toggle("Strict (forbid out-of-key notes)",
                   isOn: Binding(get: { model.project.isStrictKey }, set: { model.setStrictKey($0) }))
            Divider()
            VStack(alignment: .leading, spacing: LFBSpace.xs) {
                Text("Note length")
                HStack(spacing: LFBSpace.sm) {
                    Text("Short").font(.lfbCaption).foregroundStyle(Color.lfbTextTertiary)
                    Slider(value: Binding(get: { model.project.songNoteLength }, set: { model.setNoteLength($0) }), in: 0...1)
                        .accessibilityIdentifier("noteLength")
                    Text("Long").font(.lfbCaption).foregroundStyle(Color.lfbTextTertiary)
                }
                Text("How long new notes are by default; override per track in its effects.")
                    .font(.footnote).foregroundStyle(Color.lfbTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            MusicSettingsSection(model: model)
        }
        .padding(LFBSpace.lg)
        .frame(width: 320)
    }
}

/// Dice toggle, seed number and Copy (36 pt high, 32 pt buttons).
private struct PadSeedField: View {
    @Bindable var model: ProjectViewModel
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 2) {
            Button {
                if model.isDiceOn, let current = model.displaySeed { model.pinSeed(current) }
                else { model.clearPinnedSeed() }
            } label: {
                Image(systemName: "dice")
                    .foregroundStyle(model.isDiceOn ? Color.lfbAccent : Color.lfbTextSecondary)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Random seed every time")
            .accessibilityValue(model.isDiceOn ? "On" : "Off")

            TextField("Random", text: Binding(
                get: { focused ? text : (model.displaySeed.map(String.init) ?? "") },
                set: { text = $0 }
            ))
            .keyboardType(.numberPad)
            .font(.system(size: 15)).monospacedDigit()
            .frame(width: 96)
            .focused($focused)
            .onSubmit(commit)
            .onChange(of: focused) { _, isFocused in
                if isFocused { text = model.displaySeed.map(String.init) ?? "" } else { commit() }
            }
            .accessibilityLabel("Seed")

            Button { model.copySeedToPasteboard() } label: {
                Image(systemName: "doc.on.doc").frame(width: 32, height: 32).contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(Color.lfbTextSecondary)
            .disabled(model.displaySeed == nil)
            .accessibilityLabel("Copy Seed")
        }
        .padding(.horizontal, 2)
        .frame(height: LFBTouchSize.controlHeight)
        .background(Color.lfbWell, in: RoundedRectangle(cornerRadius: 10))
    }

    private func commit() {
        if let v = UInt32(text), v != model.displaySeed || model.isDiceOn { model.pinSeed(v) }
    }
}

/// Pretrained / Fine-tuned, a testing control; hidden on narrow windows.
private struct PadModelMenu: View {
    @Bindable var model: ProjectViewModel

    var body: some View {
        Menu {
            Picker("Model", selection: Binding(get: { model.project.model }, set: { model.setModel($0) })) {
                ForEach(NoteModel.allCases) { choice in
                    if choice == .fineTuned && !model.hasFinetunedForStyle {
                        Text("Not available for \(model.project.style.title) yet").tag(choice)
                    } else {
                        Text(choice.title).tag(choice)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(model.activeModel.title)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 11, weight: .semibold))
            }
        }
        .buttonStyle(.bordered).fixedSize()
        .accessibilityLabel("Model")
    }
}
#endif
