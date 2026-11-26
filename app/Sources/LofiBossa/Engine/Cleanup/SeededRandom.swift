import Foundation

extension Tidy {
    /// A small seedable generator (SplitMix64) for the clean-up's random choices, so a seed
    /// gives the same result on every device and OS version. It does not reproduce Python's
    /// `random.Random`; only Swift runs are comparable with each other.
    struct SeededRandom: RandomNumberGenerator {
        private var state: UInt64

        init(seed: UInt64) { state = seed }

        /// Seeded from a string (FNV-1a), e.g. "\(seed)-piano" as `tidy_song` does per track.
        init(_ text: String) {
            var h: UInt64 = 0xcbf2_9ce4_8422_2325
            for byte in text.utf8 {
                h ^= UInt64(byte)
                h = h &* 0x0000_0100_0000_01b3
            }
            state = h
        }

        mutating func next() -> UInt64 {
            state &+= 0x9e37_79b9_7f4a_7c15
            var z = state
            z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
            z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
            return z ^ (z >> 31)
        }

        /// Uniform in [0, 1).
        mutating func unit() -> Double { Double(next() >> 11) * 0x1p-53 }

        /// Uniform integer in 0..<bound (bound > 0).
        mutating func below(_ bound: Int) -> Int {
            Int(next().multipliedFullWidth(by: UInt64(bound)).high)
        }

        /// Normal deviate (Box-Muller), like Python's `random.gauss`.
        mutating func gauss(_ mean: Double, _ sigma: Double) -> Double {
            let u1 = 1 - unit()            // (0, 1]: log stays finite
            let u2 = unit()
            return mean + sigma * (-2 * Foundation.log(u1)).squareRoot() * cos(2 * .pi * u2)
        }

        /// `count` distinct elements of `items` in random order, like Python's `random.sample`.
        mutating func sample<T>(_ items: [T], _ count: Int) -> [T] {
            var pool = items
            let k = min(max(count, 0), pool.count)
            for i in 0..<k {
                pool.swapAt(i, i + below(pool.count - i))
            }
            return Array(pool.prefix(k))
        }
    }
}
