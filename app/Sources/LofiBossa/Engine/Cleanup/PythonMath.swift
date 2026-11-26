import Foundation

/// Small helpers that make the Swift port round, wrap and sort exactly as training/tidy.py and
/// training/tracks.py do, so the golden fixtures match to the last digit.
enum PythonMath {
    /// Python's `round(x)`: to the nearest integer, ties to even.
    static func round(_ x: Double) -> Double { x.rounded(.toNearestOrEven) }

    /// Python's `round(x, digits)`: correctly rounded on the exact binary value, ties to even
    /// (`%.*f` formatting rounds the same way).
    static func round(_ x: Double, _ digits: Int) -> Double {
        guard x.isFinite else { return x }
        return Double(String(format: "%.\(digits)f", x)) ?? x
    }

    /// Python's / NumPy's float `a % b`: the result takes the sign of `b`.
    static func mod(_ a: Double, _ b: Double) -> Double {
        var m = fmod(a, b)
        if m != 0, (b < 0) != (m < 0) { m += b }
        return m
    }

    /// Python's integer `a % b` for b > 0: never negative.
    static func mod(_ a: Int, _ b: Int) -> Int { ((a % b) + b) % b }

    /// Python's `sorted(xs, key=...)`: stable, so equal keys keep their input order.
    static func sorted<T>(_ xs: [T], by less: (T, T) -> Bool) -> [T] {
        xs.enumerated()
            .sorted { a, b in
                if less(a.element, b.element) { return true }
                if less(b.element, a.element) { return false }
                return a.offset < b.offset
            }
            .map(\.element)
    }

    /// NumPy's `np.arange(start, stop, step)` for a positive step: the length is
    /// ceil((stop - start) / step) and element i is start + i * ((start + step) - start).
    static func arange(_ start: Double, _ stop: Double, _ step: Double) -> [Double] {
        let count = Int(((stop - start) / step).rounded(.up))
        guard count > 0 else { return [] }
        let delta = (start + step) - start
        return (0..<count).map { i in
            switch i {
            case 0: start
            case 1: start + step
            default: start + Double(i) * delta
            }
        }
    }
}
