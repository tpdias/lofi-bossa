import SwiftUI

/// One spark. A value type, so the whole field is a plain array.
struct NoteParticle {
    var x: CGFloat
    var y: CGFloat
    var vx: CGFloat
    var vy: CGFloat
    var age: Double = 0
    var life: Double
    var size: CGFloat
    var color: Color
}

/// A small particle system for one lane or roll. Each note-on gives off a few sparks that drift
/// upward, shrink and fade over about 0.6 s; drums give a short radial burst instead. Capped at
/// `LFBGlow.maxParticles` live particles. Updated from the layer's `TimelineView(.animation)`
/// tick on the main thread; nothing here touches the audio thread.
final class NoteParticleField {
    private(set) var particles: [NoteParticle] = []
    private var lastDate: Date?
    /// Song position at the last tick, to find the notes that started since.
    var lastPosition: Double?

    var isEmpty: Bool { particles.isEmpty }

    /// Moves everything on by the time since the last tick and drops what has faded out.
    func advance(to date: Date) {
        let dt = min(max(date.timeIntervalSince(lastDate ?? date), 0), 0.1)
        lastDate = date
        guard dt > 0, !particles.isEmpty else { return }
        for i in particles.indices {
            particles[i].age += dt
            particles[i].x += particles[i].vx * CGFloat(dt)
            particles[i].y += particles[i].vy * CGFloat(dt)
            particles[i].vy -= 18 * CGFloat(dt)    // a little lift as it rises
        }
        particles.removeAll { $0.age >= $0.life }
    }

    func reset() { particles.removeAll(); lastDate = nil; lastPosition = nil }

    /// Sparks for a pitched note starting at `origin`; `velocity` is MIDI 1...127.
    func emitSparks(at origin: CGPoint, color: Color, velocity: Int, using rng: inout some RandomNumberGenerator) {
        let count = 2 + Int(Double(velocity) / 127 * 3)
        for _ in 0..<count {
            add(NoteParticle(
                x: origin.x + .random(in: -2...2, using: &rng), y: origin.y + .random(in: -2...2, using: &rng),
                vx: .random(in: -10...14, using: &rng), vy: .random(in: -46 ... -18, using: &rng),
                life: LFBGlow.particleLifeSeconds * .random(in: 0.7...1.1, using: &rng),
                size: .random(in: 2.2...4.2, using: &rng), color: color))
        }
    }

    /// A short radial burst for a drum hit.
    func emitBurst(at origin: CGPoint, color: Color, using rng: inout some RandomNumberGenerator) {
        let count = 7
        for i in 0..<count {
            let angle = (Double(i) / Double(count)) * 2 * .pi + Double.random(in: -0.3...0.3, using: &rng)
            let speed = CGFloat.random(in: 26...52, using: &rng)
            add(NoteParticle(
                x: origin.x, y: origin.y, vx: CGFloat(cos(angle)) * speed, vy: CGFloat(sin(angle)) * speed,
                life: LFBGlow.particleLifeSeconds * 0.6, size: .random(in: 2...3.4, using: &rng), color: color))
        }
    }

    private func add(_ p: NoteParticle) {
        if particles.count >= LFBGlow.maxParticles { particles.removeFirst(particles.count - LFBGlow.maxParticles + 1) }
        particles.append(p)
    }

    /// Draws the sparks additively, so overlapping ones brighten like light.
    func draw(in ctx: inout GraphicsContext, blend: GraphicsContext.BlendMode = .plusLighter) {
        guard !particles.isEmpty else { return }
        ctx.drawLayer { layer in
            layer.blendMode = blend
            for p in particles {
                let t = p.age / p.life
                let s = p.size * CGFloat(1 - 0.7 * t)
                let alpha = 1 - t * t
                let r = CGRect(x: p.x - s, y: p.y - s, width: s * 2, height: s * 2)
                layer.fill(Path(ellipseIn: r), with: .color(p.color.opacity(alpha * 0.9)))
                layer.fill(Path(ellipseIn: r.insetBy(dx: s * 0.45, dy: s * 0.45)), with: .color(.white.opacity(alpha * 0.8)))
            }
        }
    }
}
