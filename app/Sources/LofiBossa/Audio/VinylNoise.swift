import AVFoundation

/// Vinyl surface noise: soft filtered hiss plus sparse crackle pops.
final class VinylNoise {
    /// Shared with the audio thread. The render block owns it, so it outlives this object
    /// for as long as the engine keeps pulling audio.
    private final class State {
        var level: Float = 0
        var hiss: Float = 0
        var pop: Float = 0
        var rng = SystemRandomNumberGenerator()
    }

    private let state = State()
    let node: AVAudioSourceNode

    /// 0...1. A stale value for one buffer on the audio thread is harmless.
    var level: Float {
        get { state.level }
        set { state.level = newValue }
    }

    init() {
        let state = state
        node = AVAudioSourceNode { _, _, frameCount, bufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            let level = state.level
            for frame in 0..<Int(frameCount) {
                var sample: Float = 0
                if level > 0 {
                    let white = Float.random(in: -1...1, using: &state.rng)
                    state.hiss += 0.12 * (white - state.hiss)          // one-pole low-pass
                    if Float.random(in: 0...1, using: &state.rng) < 0.00035 {
                        state.pop = Float.random(in: -1...1, using: &state.rng)
                    }
                    state.pop *= 0.82                                  // fast decay
                    sample = level * (0.035 * state.hiss + 0.22 * state.pop)
                }
                for buffer in buffers {
                    buffer.mData?.assumingMemoryBound(to: Float.self)[frame] = sample
                }
            }
            return noErr
        }
    }
}
