import SwiftUI

/// Miniature piano-roll overview for one track. Pure drawing, one Canvas per lane.
/// Click anywhere to seek. Time maps to x through `window` (the stage's timeline zoom), the same
/// mapping the ruler uses (`TimelineRuler`); only the notes in view are drawn.
struct NoteLaneView: View {
    let notes: [Note]
    let duration: Double
    var window = TimelineWindow()
    let color: Color
    var ghostNotes: [Note] = []
    var ghostColor: Color = .clear
    var onSeek: (Double) -> Void = { _ in }
    /// Bar and beat lines behind the notes, when the song has a tempo.
    var grid: BeatGrid? = nil
    /// Notes light up while they sound (see `NoteGlowLayer`). Off for thumbnails.
    var glows = false
    var isDrums = false

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                guard duration > 0 else { return }
                if let grid {
                    TimelineRuler.drawLaneGrid(&ctx, size: size, duration: duration, window: window, grid: grid)
                }
                if !ghostNotes.isEmpty {
                    draw(ghostNotes, in: &ctx, size: size, color: ghostColor.opacity(0.35))
                }
                draw(notes, in: &ctx, size: size, color: color)
            }
            .contentShape(Rectangle())
            .gesture(SpatialTapGesture().onEnded { tap in
                onSeek(min(max(window.time(atX: tap.location.x, width: geo.size.width, duration: duration), 0), duration))
            })
        }
        .overlay {
            if glows { NoteGlowLayer(notes: notes, color: color, isDrums: isDrums, rect: glowRect) }
        }
        .accessibilityLabel("Notes overview")
        .accessibilityHint("Click to move the playhead")
    }

    /// Where `draw` puts a note, for the glow layer.
    private func glowRect(_ n: Note, _ size: CGSize) -> CGRect? {
        guard duration > 0, let lo = notes.map(\.pitch).min(), let hi = notes.map(\.pitch).max() else { return nil }
        let span = Double(max(hi - lo, 11))
        let x = window.x(for: n.start, width: size.width, duration: duration)
        let w = max(window.width(of: n.duration, width: size.width, duration: duration), 3)
        guard x + w >= 0, x <= size.width else { return nil }
        let t = 1 - Double(n.pitch - lo) / span
        return CGRect(x: x, y: 10 + CGFloat(t) * (size.height - 24), width: w, height: 4)
    }

    private func draw(_ notes: [Note], in ctx: inout GraphicsContext, size: CGSize, color: Color) {
        guard !notes.isEmpty else { return }
        let lo = notes.map(\.pitch).min() ?? 0
        let hi = notes.map(\.pitch).max() ?? 0
        let span = Double(max(hi - lo, 11))
        let pad: CGFloat = 10
        let noteH: CGFloat = 4
        for n in notes {
            let x = window.x(for: n.start, width: size.width, duration: duration)
            let w = max(window.width(of: n.duration, width: size.width, duration: duration), 3)
            guard x + w >= 0, x <= size.width else { continue }
            let t = 1 - Double(n.pitch - lo) / span
            let y = pad + CGFloat(t) * (size.height - pad * 2 - noteH)
            ctx.fill(Path(roundedRect: CGRect(x: x, y: y, width: w, height: noteH), cornerRadius: 2),
                     with: .color(color))
        }
    }
}
