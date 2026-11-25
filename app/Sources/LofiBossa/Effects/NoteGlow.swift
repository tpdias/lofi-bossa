import SwiftUI

// MARK: - Setting

/// "Note effects" in the song settings: Full is the glowing "light saber" notes plus sparks,
/// Subtle is a static soft glow, Off draws nothing extra. Reduce Motion always behaves as Subtle.
enum NoteEffectsMode: String, CaseIterable, Identifiable {
    case full, subtle, off
    var id: String { rawValue }
    var title: String {
        switch self { case .full: "Full"; case .subtle: "Subtle"; case .off: "Off" }
    }
    static let storageKey = "lfb.noteEffects"
}

/// Small picker used in the song settings on every layout.
struct NoteEffectsPicker: View {
    @AppStorage(NoteEffectsMode.storageKey) private var mode = NoteEffectsMode.full.rawValue
    var body: some View {
        HStack {
            Text("Note effects").font(.lfbBodyMedium)
            Spacer()
            Picker("Note effects", selection: $mode) {
                ForEach(NoteEffectsMode.allCases) { Text($0.title).tag($0.rawValue) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            .accessibilityIdentifier("noteEffects")
        }
    }
}

// MARK: - Playback clock

/// Where the song is and whether it plays, readable from any lane without threading the view
/// model through. Injected once at the root (`AdaptiveRootView`).
struct NoteClock {
    var read: @MainActor () -> (position: Double, isPlaying: Bool)
    static let stopped = NoteClock { (0, false) }
}

private struct NoteClockKey: EnvironmentKey { static let defaultValue = NoteClock.stopped }
extension EnvironmentValues {
    var noteClock: NoteClock {
        get { self[NoteClockKey.self] }
        set { self[NoteClockKey.self] = newValue }
    }
}

// MARK: - Layer

/// Draws the glow for notes that sound right now, and their sparks, over a lane or roll.
/// The host says where a note sits (`rect`); everything else lives here. The note itself is
/// drawn twice: a halo (blurred, added with `.plusLighter` so overlaps add up like light) that
/// swells on note-on in proportion to velocity and fades on release, and a bright core with a
/// white center line, like a light saber blade.
struct NoteGlowLayer: View {
    let notes: [Note]
    let color: Color
    var isDrums = false
    /// Frame of a note in this layer's coordinates, or nil when it is out of view.
    let rect: (Note, CGSize) -> CGRect?

    @Environment(\.noteClock) private var clock
    @Environment(\.lfbTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    @AppStorage(NoteEffectsMode.storageKey) private var modeRaw = NoteEffectsMode.full.rawValue
    @State private var field = NoteParticleField()

    private var mode: NoteEffectsMode {
        let m = NoteEffectsMode(rawValue: modeRaw) ?? .full
        return reduceMotion && m == .full ? .subtle : m
    }

    var body: some View {
        if mode != .off {
            let state = clock.read()
            TimelineView(.animation(paused: !state.isPlaying && field.isEmpty)) { timeline in
                let now = clock.read()
                Canvas { ctx, size in
                    render(&ctx, size: size, date: timeline.date, t: now.position, playing: now.isPlaying)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private func render(_ ctx: inout GraphicsContext, size: CGSize, date: Date, t: Double, playing: Bool) {
        var rng = SystemRandomNumberGenerator()
        let full = mode == .full
        if full {
            field.advance(to: date)
            if playing, let last = field.lastPosition, t > last, t - last < 0.4 {
                for n in notes where n.start > last && n.start <= t {
                    guard let r = rect(n, size) else { continue }
                    let tint = tinted(color)
                    if isDrums { field.emitBurst(at: CGPoint(x: r.minX, y: r.midY), color: tint, using: &rng) }
                    else { field.emitSparks(at: CGPoint(x: r.minX, y: r.midY), color: tint, velocity: n.velocity, using: &rng) }
                }
            }
            field.lastPosition = playing ? t : nil
        }
        if playing {
            for n in notes {
                let age = t - n.start
                let end = n.start + max(n.duration, 0.12)
                guard age >= 0, t < end + LFBGlow.releaseSeconds, let r = rect(n, size) else { continue }
                drawGlow(&ctx, rect: r, velocity: n.velocity, age: age, release: max(t - end, 0), full: full)
            }
        }
        if full { field.draw(in: &ctx, blend: additive) }
    }

    /// Glows add like light on a dark surface; on a light one adding does nothing, so they
    /// draw as ordinary translucent color.
    private var additive: GraphicsContext.BlendMode { scheme == .dark ? .plusLighter : .normal }

    private func tinted(_ c: Color) -> Color { c }

    private func drawGlow(_ ctx: inout GraphicsContext, rect r: CGRect, velocity: Int, age: Double, release: Double, full: Bool) {
        let vel = 0.45 + 0.55 * Double(min(max(velocity, 1), 127)) / 127
        // Swell on note-on (a quick overshoot that settles), then fade through the release.
        let swell = full ? 1 + 0.9 * exp(-age * 9) : 1
        let fade = 1 - min(release / LFBGlow.releaseSeconds, 1)
        let strength = vel * fade
        let pad = LFBGlow.haloPadding * CGFloat(swell)
        // Wide soft bloom plus a tight bright one, both added so overlapping glows brighten.
        let bloom = r.insetBy(dx: -pad * 2, dy: -pad * 2)
        ctx.drawLayer { layer in
            layer.blendMode = additive
            layer.addFilter(.blur(radius: LFBGlow.haloRadius * CGFloat(full ? swell : 0.8)))
            layer.fill(Path(roundedRect: bloom, cornerRadius: bloom.height / 2), with: .color(color.opacity(strength)))
            layer.fill(Path(roundedRect: bloom, cornerRadius: bloom.height / 2), with: .color(theme.glow.opacity(0.35 * strength)))
        }
        let tight = r.insetBy(dx: -pad * 0.6, dy: -pad * 0.6)
        ctx.drawLayer { layer in
            layer.blendMode = additive
            layer.addFilter(.blur(radius: 2.5))
            layer.fill(Path(roundedRect: tight, cornerRadius: tight.height / 2), with: .color(color.opacity(0.9 * strength)))
        }
        // Rim in the track color, white-hot core inside it.
        let radius = min(r.height / 2, 3)
        ctx.fill(Path(roundedRect: r, cornerRadius: radius), with: .color(color.opacity(min(strength + 0.2, 1))))
        let core = r.insetBy(dx: min(1, r.width / 4), dy: r.height * 0.3)
        if core.height > 0.5, core.width > 0.5 {
            ctx.drawLayer { layer in
                layer.blendMode = additive
                layer.fill(Path(roundedRect: core, cornerRadius: core.height / 2), with: .color(.white.opacity(0.9 * strength)))
            }
        }
    }
}
