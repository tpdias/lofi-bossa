import SwiftUI

/// Per-track effects, opened from the FX button on a track row. The same EffectCard used for
/// the master effects in the inspector, so "drag the card" feels the same at both levels.
struct TrackEffectsPopover: View {
    let track: TrackID
    @Binding var effects: TrackEffects
    /// This track's own busyness; nil follows the song's.
    @Binding var busyness: Double?
    /// This track's own note length; nil follows the song's.
    @Binding var noteLength: Double?
    var songBusyness: Double = Project.defaultBusyness
    var songNoteLength: Double = Project.defaultNoteLength
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

            Divider()
            VStack(alignment: .leading, spacing: LFBSpace.xs) {
                HStack {
                    Text("Busyness").font(.lfbBodyMedium)
                    Spacer()
                    Toggle("Same as song", isOn: Binding(
                        get: { busyness == nil },
                        set: { busyness = $0 ? nil : songBusyness }))
                        .checkboxToggleStyle().font(.lfbCaption)
                }
                HStack(spacing: LFBSpace.sm) {
                    Text("Sparse").font(.lfbCaption).foregroundStyle(Color.lfbTextTertiary)
                    Slider(value: Binding(get: { busyness ?? songBusyness }, set: { busyness = $0 }), in: 0...1)
                        .tint(track.color)
                    Text("Busy").font(.lfbCaption).foregroundStyle(Color.lfbTextTertiary)
                }
                Text("How many of the model's notes this track keeps on the next rewrite or take.")
                    .font(.lfbCaption).foregroundStyle(Color.lfbTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            VStack(alignment: .leading, spacing: LFBSpace.xs) {
                HStack {
                    Text("Note length").font(.lfbBodyMedium)
                    Spacer()
                    Toggle("Same as song", isOn: Binding(
                        get: { noteLength == nil },
                        set: { noteLength = $0 ? nil : songNoteLength }))
                        .checkboxToggleStyle().font(.lfbCaption)
                }
                HStack(spacing: LFBSpace.sm) {
                    Text("Short").font(.lfbCaption).foregroundStyle(Color.lfbTextTertiary)
                    Slider(value: Binding(get: { noteLength ?? songNoteLength }, set: { noteLength = $0 }), in: 0...1)
                        .tint(track.color)
                    Text("Long").font(.lfbCaption).foregroundStyle(Color.lfbTextTertiary)
                }
                Text("How long this track's new notes are, on the next rewrite or take.")
                    .font(.lfbCaption).foregroundStyle(Color.lfbTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
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
