import AVFoundation

/// The background sound under a song (`MixEffects.background`): rain, forest, wind, ocean, or
/// white, grey or brown noise, all synthesized sample by sample, so nothing is recorded or
/// bundled. Each channel has its own noise, so the bed is wide rather than in the middle.
///
/// The render block owns the state (as in `VinylNoise`); the main thread only writes `ambience`
/// and `level`, and a value one buffer stale is harmless. Changing the sound fades the old one
/// out and the new one in, so switching never clicks.
final class BackgroundNoise {
    static let sampleRate: Float = 44100

    /// One channel's noise generators and filters.
    struct Voice {
        var seed: UInt32
        // pink (Paul Kellet's filter), brown (leaky integrator)
        var p0: Float = 0, p1: Float = 0, p2: Float = 0, p3: Float = 0, p4: Float = 0, p5: Float = 0, p6: Float = 0
        var brown: Float = 0
        // state-variable band-pass (wind, leaves), one-pole filters (rain, surf)
        var low: Float = 0, band: Float = 0
        var hp: Float = 0, hpIn: Float = 0, lp: Float = 0
        // rain drops
        var drop: Float = 0, dropTone: Float = 0, dropPhase: Float = 0

        init(seed: UInt32) { self.seed = seed }

        /// White noise in -1...1 (xorshift: cheap and fine for audio).
        mutating func white() -> Float {
            seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5
            return Float(seed) / Float(UInt32.max) * 2 - 1
        }

        mutating func uniform() -> Float { (white() + 1) / 2 }

        mutating func pink(_ w: Float) -> Float {
            p0 = 0.99886 * p0 + w * 0.0555179
            p1 = 0.99332 * p1 + w * 0.0750759
            p2 = 0.96900 * p2 + w * 0.1538520
            p3 = 0.86650 * p3 + w * 0.3104856
            p4 = 0.55000 * p4 + w * 0.5329522
            p5 = -0.7616 * p5 - w * 0.0168980
            let out = p0 + p1 + p2 + p3 + p4 + p5 + p6 + w * 0.5362
            p6 = w * 0.115926
            return out * 0.11
        }

        mutating func brownian(_ w: Float) -> Float {
            brown = (brown + 0.02 * w) / 1.02
            return brown * 3.5
        }

        /// Band-pass around `frequency` Hz (Chamberlin state-variable filter).
        mutating func bandPass(_ x: Float, frequency: Float, q: Float) -> Float {
            let f = 2 * sin(Float.pi * min(frequency, 8000) / BackgroundNoise.sampleRate)
            low += f * band
            let high = x - low - q * band
            band += f * high
            return band
        }
    }

    /// Slow movement shared by both channels: gusts, waves, birdsong.
    struct Scene {
        var time: Float = 0                  // seconds since this sound started
        var gust: Float = 0.5, gustTarget: Float = 0.5
        var wavePhase: Float = 0, wavePeriod: Float = 9
        var chirpsLeft = 0, chirpTime: Float = 0, chirpGap: Float = 0, chirpBase: Float = 3000
        var chirpPhase: Float = 0, chirpPan: Float = 0.5, nextBird: Float = 2
    }

    private final class State {
        var target: Ambience = .none
        var level: Float = 0
        var playing: Ambience = .none
        var gain: Float = 0                  // smoothed, so changes never click
        var left = Voice(seed: 0x9E37_79B9)
        var right = Voice(seed: 0x85EB_CA6B)
        var scene = Scene()
        var control = Voice(seed: 0xC2B2_AE35)   // randomness for the scene
    }

    private let state = State()
    let node: AVAudioSourceNode

    var ambience: Ambience {
        get { state.target }
        set { state.target = newValue }
    }

    /// 0...1 (0 while the song isn't playing).
    var level: Float {
        get { state.level }
        set { state.level = newValue }
    }

    init() {
        let state = state
        node = AVAudioSourceNode { _, _, frameCount, bufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            let left = buffers.first?.mData?.assumingMemoryBound(to: Float.self)
            let right = buffers.count > 1 ? buffers[1].mData?.assumingMemoryBound(to: Float.self) : nil
            for frame in 0..<Int(frameCount) {
                // Fade to silence before switching sounds, then fade the new one in.
                let switching = state.playing != state.target
                let wanted: Float = switching ? 0 : state.level * state.level
                state.gain += (wanted - state.gain) * 0.0004
                if switching && state.gain < 0.0005 {
                    state.playing = state.target
                    state.scene = Scene()
                }
                var l: Float = 0, r: Float = 0
                if state.playing != .none && state.gain > 0.00001 {
                    (l, r) = Self.render(state.playing, &state.left, &state.right, &state.scene, &state.control)
                    l *= state.gain; r *= state.gain
                }
                left?[frame] = l
                (right ?? left)?[frame] = right == nil ? (l + r) / 2 : r
            }
            return noErr
        }
    }

    /// One stereo sample of `sound`, at full level (about -12 dBFS peak).
    static func render(_ sound: Ambience, _ l: inout Voice, _ r: inout Voice, _ scene: inout Scene,
                       _ control: inout Voice) -> (Float, Float) {
        let dt = 1 / sampleRate
        scene.time += dt
        switch sound {
        case .none:
            return (0, 0)
        case .white:
            return (0.16 * l.white(), 0.16 * r.white())
        case .brown:
            return (0.28 * l.brownian(l.white()), 0.28 * r.brownian(r.white()))
        case .grey:
            // Equal loudness, roughly: pink noise with the lows and highs lifted against the mids.
            func grey(_ v: inout Voice) -> Float {
                let w = v.white()
                return 0.16 * v.pink(w) + 0.12 * v.brownian(w) + 0.035 * w
            }
            return (grey(&l), grey(&r))
        case .rain:
            func rain(_ v: inout Voice) -> Float {
                let w = v.white()
                // the hiss of rainfall: pink noise without its lowest rumble
                let pink = v.pink(w)
                v.hp = 0.995 * (v.hp + pink - v.hpIn); v.hpIn = pink
                // drops: short, bright ticks at random
                if v.uniform() < 0.0009 {
                    v.drop = 0.25 + 0.75 * v.uniform()
                    v.dropTone = 1800 + 2600 * v.uniform()
                }
                v.dropPhase += v.dropTone * dt
                let tick = v.drop * sin(2 * .pi * v.dropPhase) * (0.5 + 0.5 * w)
                v.drop *= 0.9965
                return 0.22 * v.hp + 0.1 * tick + 0.05 * v.brownian(w)
            }
            return (rain(&l), rain(&r))
        case .wind:
            // A gust level that wanders, setting how loud and how high the wind howls.
            if control.uniform() < 0.00005 { scene.gustTarget = 0.2 + 0.8 * control.uniform() }
            scene.gust += (scene.gustTarget - scene.gust) * 0.00003
            func wind(_ v: inout Voice) -> Float {
                let w = v.white()
                let body = v.bandPass(v.pink(w), frequency: 250 + 650 * scene.gust, q: 0.35)
                return (0.25 + 0.6 * scene.gust) * (0.55 * body + 0.12 * v.brownian(w))
            }
            return (wind(&l), wind(&r))
        case .ocean:
            // Waves: a swell that builds over a few seconds and breaks into surf.
            scene.wavePhase += dt / scene.wavePeriod
            if scene.wavePhase >= 1 {
                scene.wavePhase -= 1
                scene.wavePeriod = 7 + 5 * control.uniform()
            }
            let swell = pow(sin(.pi * scene.wavePhase), 2)
            let surf = max(0, sin(.pi * min(scene.wavePhase * 1.4, 1)) - 0.3) / 0.7
            func ocean(_ v: inout Voice) -> Float {
                let w = v.white()
                v.lp += (0.06 + 0.25 * surf) * (v.pink(w) - v.lp)
                return 0.1 * v.brownian(w) * (0.4 + 0.6 * swell) + 0.5 * v.lp * (0.15 + 0.85 * surf)
            }
            return (ocean(&l), ocean(&r))
        case .forest:
            // Leaves in a light breeze, and now and then a bird: a few quick rising chirps.
            if control.uniform() < 0.00004 { scene.gustTarget = 0.3 + 0.7 * control.uniform() }
            scene.gust += (scene.gustTarget - scene.gust) * 0.00002
            if scene.chirpsLeft == 0 && scene.time >= scene.nextBird {
                scene.chirpsLeft = 2 + Int(control.uniform() * 4)
                scene.chirpBase = 2400 + 2200 * control.uniform()
                scene.chirpPan = control.uniform()
                scene.chirpTime = 0; scene.chirpGap = 0
            }
            var bird: Float = 0
            if scene.chirpsLeft > 0 {
                let length: Float = 0.07
                if scene.chirpGap > 0 {
                    scene.chirpGap -= dt
                } else {
                    scene.chirpTime += dt
                    let x = scene.chirpTime / length
                    scene.chirpPhase += scene.chirpBase * (1 + 0.45 * x) * dt
                    bird = 0.09 * sin(2 * .pi * scene.chirpPhase) * sin(.pi * min(x, 1))
                    if x >= 1 {
                        scene.chirpsLeft -= 1
                        scene.chirpTime = 0
                        scene.chirpGap = 0.05 + 0.08 * control.uniform()
                        if scene.chirpsLeft == 0 { scene.nextBird = scene.time + 2.5 + 6 * control.uniform() }
                    }
                }
            }
            func leaves(_ v: inout Voice) -> Float {
                let w = v.white()
                let rustle = v.bandPass(w, frequency: 3200, q: 0.9)
                return (0.03 + 0.07 * scene.gust) * rustle + 0.06 * v.brownian(w)
            }
            return (leaves(&l) + bird * (1 - scene.chirpPan), leaves(&r) + bird * scene.chirpPan)
        }
    }
}
