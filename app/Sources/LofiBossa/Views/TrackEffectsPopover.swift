import SwiftUI

/// Per-track effects, opened from the FX button on a track row. The same EffectCard used for
/// the master effects in the inspector, so "drag the card" feels the same at both levels.
struct TrackEffectsPopover: View {
    let track: TrackID
    @Binding var effects: TrackEffects
    var onReset: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: LFBSpace.md) {
            HStack(spacing: LFBSpace.sm) {
                TrackGlyph(id: track, size: 22)
                Text("\(track.title) effects").font(.lfbHeadline)
                Spacer()
                Button("Reset", action: onReset)
                    .buttonStyle(.plain).font(.lfbCaption).foregroundStyle(Color.lfbAccentText)
            }
            EffectCard(title: "Warmth", caption: "Softens the highs", symbol: "thermometer.sun", amount: $effects.warmth)
            EffectCard(title: "Grit", caption: "Crunchy, worn-tape texture", symbol: "circle.grid.cross", amount: $effects.grit)
            EffectCard(title: "Echo", caption: "Repeats that fade away", symbol: "dot.radiowaves.left.and.right", amount: $effects.echo)
            EffectCard(title: "Reverb", caption: "Space around this part", symbol: "waveform.path.ecg", amount: $effects.reverb)

            VStack(alignment: .leading, spacing: LFBSpace.xs) {
                HStack {
                    Text("Pan").font(.lfbBodyMedium)
                    Spacer()
                    Text(panLabel).font(.lfbCaption).foregroundStyle(Color.lfbTextSecondary)
                }
                HStack(spacing: LFBSpace.sm) {
                    Text("L").font(.lfbCaption).foregroundStyle(Color.lfbTextTertiary)
                    Slider(value: $effects.pan, in: -1...1).tint(track.color)
                    Text("R").font(.lfbCaption).foregroundStyle(Color.lfbTextTertiary)
                }
            }
        }
        .padding(LFBSpace.md)
        .frame(width: 280)
    }

    private var panLabel: String {
        let percent = Int((abs(effects.pan) * 100).rounded())
        if percent == 0 { return "Center" }
        return effects.pan < 0 ? "Left \(percent)" : "Right \(percent)"
    }
}
