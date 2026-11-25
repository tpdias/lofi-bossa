import SwiftUI

/// Sound-design control that invites playing with it: the whole card is the slider.
/// Used for Warmth, Reverb and Vinyl in the inspector's Sound tab.
struct EffectCard: View {
    let title: String
    let caption: String
    let symbol: String
    @Binding var amount: Double          // 0...1, displayed as 0...100

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: LFBRadius.card).fill(Color.lfbWell)
                Rectangle().fill(Color.lfbAccentWash)
                    .frame(width: geo.size.width * amount)
                    .overlay(alignment: .trailing) { Rectangle().fill(Color.lfbAccent).frame(width: 2) }
                HStack(spacing: 10) {
                    Image(systemName: symbol).foregroundStyle(Color.lfbTextSecondary).frame(width: 22)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(title).font(.lfbHeadline)
                        Text(caption).font(.lfbCaption).foregroundStyle(Color.lfbTextSecondary)
                    }
                    Spacer()
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
        .frame(height: LFBSize.isTouch ? LFBTouchSize.effectCardHeight : LFBSize.effectCardHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue("\(Int(amount * 100)) percent")
        .accessibilityHint("\(caption). Swipe up or down to adjust.")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: amount = min(amount + 0.05, 1)
            case .decrement: amount = max(amount - 0.05, 0)
            @unknown default: break
            }
        }
    }
}
