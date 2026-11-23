import CoreGraphics

/// The stretch of the song the stage's lanes show: `zoom` 1 is the whole song across the lanes'
/// width; zooming in shows `duration / zoom` seconds starting at `start`. The ruler, the lanes,
/// section selections, the loop range and the playhead all map time to x through this one type,
/// so they stay lined up at any zoom.
struct TimelineWindow: Equatable {
    var zoom: Double = 1
    var start: Double = 0

    /// Zoomed all the way in, this many seconds still fill the lanes.
    static let minVisibleSeconds = 4.0
    /// One ⌘+ / ⌘− step.
    static let step = 1.5

    static func maxZoom(duration: Double) -> Double { max(duration / minVisibleSeconds, 1) }

    var isZoomed: Bool { zoom > 1.0001 }
    func visibleSeconds(duration: Double) -> Double { max(duration, 0.001) / zoom }
    func end(duration: Double) -> Double { start + visibleSeconds(duration: duration) }

    func x(for time: Double, width: CGFloat, duration: Double) -> CGFloat {
        CGFloat((time - start) / visibleSeconds(duration: duration)) * width
    }
    func time(atX x: CGFloat, width: CGFloat, duration: Double) -> Double {
        start + Double(x / max(width, 1)) * visibleSeconds(duration: duration)
    }
    /// The width on screen of `seconds` of music.
    func width(of seconds: Double, width: CGFloat, duration: Double) -> CGFloat {
        CGFloat(seconds / visibleSeconds(duration: duration)) * width
    }

    /// Kept inside the song: zoom between 1 and the maximum, start no later than the last window.
    func clamped(duration: Double) -> TimelineWindow {
        var w = self
        w.zoom = min(max(zoom, 1), Self.maxZoom(duration: duration))
        w.start = min(max(start, 0), max(duration - w.visibleSeconds(duration: duration), 0))
        if !w.isZoomed { w.start = 0 }
        return w
    }

    /// Zooms to `newZoom`, keeping the time at `anchor` (default: the middle) where it is on screen.
    mutating func setZoom(_ newZoom: Double, anchor: Double? = nil, duration: Double) {
        let current = clamped(duration: duration)
        let anchorTime = anchor ?? (current.start + current.visibleSeconds(duration: duration) / 2)
        let fraction = (anchorTime - current.start) / current.visibleSeconds(duration: duration)
        var next = current
        next.zoom = min(max(newZoom, 1), Self.maxZoom(duration: duration))
        next.start = anchorTime - fraction * next.visibleSeconds(duration: duration)
        self = next.clamped(duration: duration)
    }

    mutating func scroll(by seconds: Double, duration: Double) {
        start += seconds
        self = clamped(duration: duration)
    }

    /// Pages along so the playhead stays in view while playing.
    mutating func follow(_ position: Double, duration: Double) {
        guard isZoomed else { return }
        let visible = visibleSeconds(duration: duration)
        if position < start || position > start + visible * 0.95 {
            start = position - visible * 0.05
            self = clamped(duration: duration)
        }
    }
}
