import SwiftUI

/// The track row for compact width (iPhone, iPhone Duo). Same states as TrackRowView, stacked:
/// header (tile, name + instrument, rewrite, M, S) above a full-width note lane.
/// Instrument and volume live in the track sheet: tap the name, or long-press the card.
struct TrackCard: View {
    @Binding var track: Track
    let duration: Double
    var playhead: Double
    var loop: ClosedRange<Double>? = nil
    var isRewriting = false
    var isSelected = false
    var isGeneratorBusy = false
    var onOpenTrack: () -> Void = {}
    var onEditNotes: () -> Void = {}
    var onRewrite: () -> Void = {}
    var onCancelRewrite: () -> Void = {}
    var onSeek: (Double) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button(action: onOpenTrack) {
                    HStack(spacing: 8) {
                        Image(systemName: track.id.symbol)
                            .foregroundStyle(track.id.ink)
                            .frame(width: 34, height: 34)
                            .background(track.id.color.opacity(0.2), in: RoundedRectangle(cornerRadius: 10))
                        VStack(alignment: .leading, spacing: 0) {
                            Text(track.id.title).font(.system(size: 16, weight: .semibold, design: .rounded))
                            Text(track.instrument).font(.system(size: 12)).foregroundStyle(Color.lfbTextTertiary)
                        }
                    }
                    .opacity(track.isMuted ? 0.5 : 1)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(track.id.title), \(track.instrument)")
                .accessibilityHint("Shows instrument, volume and note editing")

                Spacer(minLength: 0)

                Button(action: isRewriting ? onCancelRewrite : onRewrite) {
                    Image(systemName: isRewriting ? "stop.fill" : "arrow.triangle.2.circlepath")
                }
                .buttonStyle(TouchKeyStyle(isOn: false))
                .disabled(isGeneratorBusy && !isRewriting)
                .accessibilityLabel(isRewriting ? "Stop rewriting" : "Rewrite \(track.id.title)")

                Button("M") { track.isMuted.toggle() }
                    .buttonStyle(TouchKeyStyle(isOn: track.isMuted, onFill: .lfbText, onText: .lfbWindow))
                    .accessibilityLabel("Mute").accessibilityValue(track.isMuted ? "On" : "Off")
                Button("S") { track.isSoloed.toggle() }
                    .buttonStyle(TouchKeyStyle(isOn: track.isSoloed, onFill: .lfbAccent, onText: .lfbOnAccent))
                    .accessibilityLabel("Solo").accessibilityValue(track.isSoloed ? "On" : "Off")
            }

            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(Color.lfbWell)
                GeometryReader { geo in
                    if let loop, duration > 0 {
                        Rectangle().fill(Color.lfbAccentWash)
                            .frame(width: geo.size.width * (loop.upperBound - loop.lowerBound) / duration)
                            .offset(x: geo.size.width * loop.lowerBound / duration)
                    }
                    NoteLaneView(notes: track.notes, duration: duration,
                                 color: track.isMuted ? .lfbTextTertiary : track.id.color, onSeek: onSeek)
                        .opacity(isRewriting ? 0.2 : (track.isMuted ? 0.45 : 1))
                    if duration > 0 {
                        Rectangle().fill(Color.lfbText).frame(width: 2)
                            .offset(x: geo.size.width * playhead / duration - 1)
                            .allowsHitTesting(false)
                    }
                }
                if isRewriting {
                    SweepView(color: track.id.color)
                    RewritePill(text: "Rewriting the \(track.id.rawValue)…", action: onCancelRewrite)
                } else if track.notes.isEmpty {
                    EmptyLane(trackName: track.id.rawValue, action: onRewrite)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .frame(minHeight: 36)
        }
        .padding(EdgeInsets(top: 8, leading: 12, bottom: 12, trailing: 12))
        .background(Color.lfbSurface, in: RoundedRectangle(cornerRadius: LFBSize.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: LFBSize.cardRadius)
            .strokeBorder(isSelected ? track.id.color : .clear, lineWidth: 2.5))
        .contextMenu {
            Picker("Instrument", selection: $track.instrument) {
                ForEach(track.id.instruments, id: \.self) { Text($0) }
            }
            Button("Edit Notes", systemImage: "pencil", action: onEditNotes)
            Button("Rewrite This Part", systemImage: "arrow.triangle.2.circlepath", action: onRewrite)
        }
        .accessibilityElement(children: .contain)
    }
}

/// M / S / rewrite on touch: 40 x 36 drawn, padded to a 44 pt hit area.
struct TouchKeyStyle: ButtonStyle {
    var isOn: Bool
    var onFill: Color = .lfbText
    var onText: Color = .lfbWindow
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(isOn ? onText : Color.lfbTextSecondary)
            .frame(width: LFBSize.phoneKey.width, height: LFBSize.phoneKey.height)
            .background(isOn ? onFill : Color.lfbControl, in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(isOn ? .clear : Color.lfbControlHairline, lineWidth: 1))
            .contentShape(Rectangle().inset(by: -4))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
