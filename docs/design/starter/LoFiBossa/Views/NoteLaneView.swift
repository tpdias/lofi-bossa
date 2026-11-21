import SwiftUI

/// Miniature piano-roll overview for one track. Pure drawing, one Canvas per lane.
/// Click anywhere to seek. The time mapping is the same one the ruler uses, so a bar/beat grid
/// can be added later by changing only the x(for:) function and the ruler ticks.
struct NoteLaneView: View {
    let notes: [Note]
    let duration: Double
    let color: Color
    var onSeek: (Double) -> Void = { _ in }

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                guard !notes.isEmpty, duration > 0 else { return }
                let lo = notes.map(\.pitch).min() ?? 0
                let hi = notes.map(\.pitch).max() ?? 0
                let span = Double(max(hi - lo, 11))
                let pad: CGFloat = 10
                let noteH: CGFloat = 4
                for n in notes {
                    let x = n.start / duration * size.width
                    let w = max(n.duration / duration * size.width, 3)
                    let t = 1 - Double(n.pitch - lo) / span
                    let y = pad + CGFloat(t) * (size.height - pad * 2 - noteH)
                    ctx.fill(Path(roundedRect: CGRect(x: x, y: y, width: w, height: noteH), cornerRadius: 2),
                             with: .color(color))
                }
            }
            .contentShape(Rectangle())
            .gesture(SpatialTapGesture().onEnded { tap in
                onSeek(Double(tap.location.x / geo.size.width) * duration)
            })
        }
        .accessibilityLabel("Notes overview")
        .accessibilityHint("Click to move the playhead")
    }
}
