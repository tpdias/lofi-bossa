import SwiftUI

/// Picks the sound under the song (rain, forest, wind, ocean, or a noise color) and how loud it
/// is. Shared by the New Project flow and the master Sound controls on every layout. The level
/// card appears once a sound is chosen.
struct BackgroundSoundPicker: View {
    @Binding var background: BackgroundSound
    /// Narrow columns (the Mac inspector, the Duo's side page) get smaller tiles.
    var minimumTileWidth: CGFloat = LFBSize.isTouch ? 92 : 76

    @Environment(\.lfbTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: LFBSpace.sm) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: minimumTileWidth), spacing: LFBSpace.sm)],
                      spacing: LFBSpace.sm) {
                ForEach(Ambience.allCases) { tile($0) }
            }
            if background.ambience != .none {
                EffectCard(title: LocalizedStringKey(background.ambience.title),
                           caption: LocalizedStringKey(background.ambience.caption),
                           symbol: background.ambience.symbol,
                           amount: $background.level)
                    .accessibilityIdentifier("background-level")
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.snappy, value: background.ambience)
    }

    private func tile(_ ambience: Ambience) -> some View {
        let isOn = background.ambience == ambience
        return Button {
            background.ambience = ambience
            if ambience != .none && background.level <= 0 { background.level = 0.5 }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: ambience.symbol)
                    .font(.system(size: LFBSize.isTouch ? 20 : 16, weight: .medium))
                    .frame(height: LFBSize.isTouch ? 24 : 20)
                Text(ambience.title)
                    .font(.lfbCaption)
                    .lineLimit(2).multilineTextAlignment(.center)
                    .minimumScaleFactor(0.85)
            }
            .foregroundStyle(isOn ? theme.accent : Color.lfbTextSecondary)
            .frame(maxWidth: .infinity, minHeight: LFBSize.isTouch ? 64 : 54)
            .padding(.horizontal, 4)
            .background(isOn ? theme.wash : Color.lfbWell, in: RoundedRectangle(cornerRadius: LFBRadius.card))
            .overlay(RoundedRectangle(cornerRadius: LFBRadius.card)
                .strokeBorder(isOn ? theme.accent : Color.clear, lineWidth: 1.5))
            .contentShape(RoundedRectangle(cornerRadius: LFBRadius.card))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(ambience.title)
        .accessibilityHint(ambience.caption)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityIdentifier("background-\(ambience.rawValue)")
    }
}

/// The master Sound panel's background section: a heading, the picker, and a line on when it
/// plays. Binds to the open project (its current take, or the project before the first take).
struct BackgroundSoundSection: View {
    let model: ProjectViewModel
    var minimumTileWidth: CGFloat = LFBSize.isTouch ? 92 : 76

    var body: some View {
        VStack(alignment: .leading, spacing: LFBSpace.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Background").font(.lfbHeadline)
                Text("A bed of sound under the song. It plays with the song and goes into the exported mix.")
                    .font(.lfbCaption).foregroundStyle(Color.lfbTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            BackgroundSoundPicker(background: Binding(
                get: { model.currentEffects.background },
                set: { model.setBackground($0) }), minimumTileWidth: minimumTileWidth)
        }
    }
}
