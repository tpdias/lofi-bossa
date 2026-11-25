import SwiftUI

/// Inspector: Sound tab (three EffectCards) and Versions tab (history list).
struct InspectorView: View {
    @Bindable var model: ProjectViewModel

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $model.inspectorTab) {
                ForEach(InspectorTab.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            .padding(LFBSpace.md)
            Divider()
            switch model.inspectorTab {
            case .sound: SoundTab(model: model)
            case .versions: VersionsTab(model: model)
            }
        }
    }
}

private struct SoundTab: View {
    @Bindable var model: ProjectViewModel

    private var effects: MixEffects { model.displayedSnapshot?.effects ?? model.project.style.defaultEffects }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LFBSpace.md) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Master").font(.lfbHeadline)
                    Text("The whole mix. Each track has its own effects too: use the slider button on its row.")
                        .font(.lfbCaption).foregroundStyle(Color.lfbTextSecondary)
                }
                EffectCard(title: "Warmth", caption: "Low-pass filter", symbol: "thermometer.sun",
                          amount: Binding(get: { effects.warmth }, set: { model.setEffects(MixEffects(warmth: $0, reverb: effects.reverb, vinyl: effects.vinyl)) }))
                EffectCard(title: "Reverb", caption: "Space and depth", symbol: "waveform.path.ecg",
                          amount: Binding(get: { effects.reverb }, set: { model.setEffects(MixEffects(warmth: effects.warmth, reverb: $0, vinyl: effects.vinyl)) }))
                EffectCard(title: "Vinyl", caption: "Hiss and crackle", symbol: "circle.dotted",
                          amount: Binding(get: { effects.vinyl }, set: { model.setEffects(MixEffects(warmth: effects.warmth, reverb: effects.reverb, vinyl: $0)) }))

                HStack {
                    Text(model.effectsAreAtStyleDefault ? "\(model.project.style.title) defaults" : "\(model.project.style.title) defaults, adjusted")
                        .font(.lfbCaption).foregroundStyle(Color.lfbTextSecondary)
                    Spacer()
                    if !model.effectsAreAtStyleDefault {
                        Button("Reset", action: model.resetEffectsToStyleDefault)
                            .buttonStyle(.plain).font(.lfbCaption).foregroundStyle(Color.lfbAccentText)
                    }
                }

                Text("Effects apply to the whole mix, after the four tracks.")
                    .font(.lfbCaption).foregroundStyle(Color.lfbTextTertiary)
            }
            .padding(LFBSpace.md)
        }
    }
}

private struct VersionsTab: View {
    @Bindable var model: ProjectViewModel

    private var groups: [(day: Date, versions: [Version])] {
        let cal = Calendar.current
        let sorted = model.project.versions.sorted { $0.number > $1.number }
        var out: [(Date, [Version])] = []
        for v in sorted {
            let day = cal.startOfDay(for: v.createdAt)
            if out.last?.0 == day { out[out.count - 1].1.append(v) } else { out.append((day, [v])) }
        }
        return out.map { ($0.0, $0.1) }
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .none; return f
    }()
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .none; f.timeStyle = .short; return f
    }()

    var body: some View {
        ScrollView {
            if model.project.versions.isEmpty {
                Text("No versions yet. Generate a take to start the history.")
                    .font(.lfbCaption).foregroundStyle(Color.lfbTextSecondary)
                    .padding(LFBSpace.md)
            } else {
                LazyVStack(alignment: .leading, spacing: LFBSpace.sm) {
                    ForEach(groups, id: \.day) { group in
                        Text(Self.dayFormatter.string(from: group.day))
                            .font(.lfbCaption).foregroundStyle(Color.lfbTextSecondary)
                            .padding(.horizontal, LFBSpace.md).padding(.top, LFBSpace.sm)
                        ForEach(group.versions) { version in
                            VersionRow(version: version, isCurrent: version.id == model.project.currentVersionID,
                                      isListening: version.id == model.listeningVersionID,
                                      onPlay: { model.listen(to: version) },
                                      onToggleKept: { model.toggleKept(version) })
                        }
                    }
                }
                .padding(.bottom, LFBSpace.md)
            }
        }
    }
}

private struct VersionRow: View {
    let version: Version
    let isCurrent: Bool
    let isListening: Bool
    let onPlay: () -> Void
    let onToggleKept: () -> Void

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .none; f.timeStyle = .short; return f
    }()

    var body: some View {
        HStack(spacing: LFBSpace.sm) {
            HStack(spacing: 2) {
                ForEach(version.snapshot.trackIDs) { id in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(version.changedTracks.contains(id) ? id.color : Color.lfbControlHairline)
                        .frame(width: 4, height: 16)
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(version.kind.title).font(.lfbBodyMedium).lineLimit(1)
                HStack(spacing: 4) {
                    Text("Version \(version.number) · \(Self.timeFormatter.string(from: version.createdAt))")
                        .font(.lfbCaption).foregroundStyle(Color.lfbTextSecondary)
                    if isCurrent { Badge(text: "Current", tint: .lfbAccent) }
                    else if isListening { Badge(text: "Listening", tint: .lfbTextSecondary) }
                }
            }
            Spacer()
            Button(action: onToggleKept) {
                Image(systemName: version.isKept ? "star.fill" : "star")
                    .foregroundStyle(version.isKept ? Color.lfbCaution : Color.lfbTextTertiary)
            }
            .buttonStyle(.plain)
            Button(action: onPlay) { Image(systemName: "play.fill") }
                .buttonStyle(.plain)
                .accessibilityIdentifier("version-play-\(version.number)")
                .accessibilityLabel("Listen to version \(version.number)")
        }
        .padding(.horizontal, LFBSpace.md).padding(.vertical, 6)
        .background(isCurrent ? Color.lfbAccentWash : .clear)
    }
}

private struct Badge: View {
    let text: LocalizedStringKey
    let tint: Color
    var body: some View {
        Text(text).font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(tint.opacity(0.18), in: Capsule())
            .foregroundStyle(tint)
    }
}
