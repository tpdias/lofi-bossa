import Foundation

/// How an export is finished after it is rendered: fades at the ends, or a seamless loop.
struct ExportOptions: Equatable {
    /// Seconds of fade at the start and end; 0 = none.
    var fadeIn: Double = 0
    var fadeOut: Double = 0
    /// Folds the reverb tail that rings past the end back onto the start, so the file repeats
    /// without a gap or a click. Fades are ignored while this is on (they would break the loop).
    var seamlessLoop = false

    static let fadeChoices: [Double] = [0, 1, 2, 4, 8]
    var isNeutral: Bool { fadeIn == 0 && fadeOut == 0 && !seamlessLoop }
}

/// Pure sample-buffer processing for exports, kept apart from the engine so it can be tested
/// without rendering anything.
enum ExportProcessing {
    /// `channels` holds the rendered audio: `bodyFrames` of song followed by its ringing tail.
    /// Returns the finished channels.
    static func finish(_ channels: [[Float]], bodyFrames: Int, sampleRate: Double,
                       options: ExportOptions) -> [[Float]] {
        var out = channels
        if options.seamlessLoop {
            out = out.map { foldTail($0, bodyFrames: bodyFrames) }
        } else {
            for i in out.indices {
                applyFades(&out[i], sampleRate: sampleRate, fadeIn: options.fadeIn, fadeOut: options.fadeOut)
            }
        }
        return out
    }

    /// Adds the tail (everything after `bodyFrames`) onto the start and drops it.
    static func foldTail(_ samples: [Float], bodyFrames: Int) -> [Float] {
        guard bodyFrames > 0, samples.count > bodyFrames else { return samples }
        var body = Array(samples[0..<bodyFrames])
        let tail = samples.count - bodyFrames
        for i in 0..<min(tail, bodyFrames) { body[i] += samples[bodyFrames + i] }
        for i in body.indices { body[i] = min(max(body[i], -1), 1) }   // two overlapping peaks must not wrap
        return body
    }

    /// A quarter-sine ramp (equal power), from silence at the first sample and back to silence
    /// at the last.
    static func applyFades(_ samples: inout [Float], sampleRate: Double, fadeIn: Double, fadeOut: Double) {
        let n = samples.count
        guard n > 1 else { return }
        let inFrames = min(Int(fadeIn * sampleRate), n)
        let outFrames = min(Int(fadeOut * sampleRate), n)
        if inFrames > 1 {
            for i in 0..<inFrames { samples[i] *= Float(sin(Double(i) / Double(inFrames - 1) * .pi / 2)) }
        }
        if outFrames > 1 {
            for k in 0..<outFrames {   // k counts back from the last sample
                samples[n - 1 - k] *= Float(sin(Double(k) / Double(outFrames - 1) * .pi / 2))
            }
        }
    }
}
