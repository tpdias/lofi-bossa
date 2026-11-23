import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// ⌘+ / ⌘− / ⌘0 from the View menu (or a hardware keyboard on iPad).
enum TimelineZoomCommand { case `in`, out, fit }

extension Notification.Name {
    /// Posted with a `TimelineZoomCommand` while the piano roll is open, which zooms itself.
    static let lfbRollZoom = Notification.Name("lfbRollZoom")
}

// MARK: - Ruler ticks

/// The stage ruler's drawing, shared by the Mac stage and the iPad layout. Every tick and label
/// is drawn here (and only here), through the same `TimelineWindow` mapping as the lanes, so a
/// bar/beat grid can be added in this one function.
enum TimelineRuler {
    struct Style {
        var font: Font
        var tickHeight: CGFloat
        var labelInset: CGFloat
        /// Distance of the label's centre line from the bottom of the ruler.
        var labelRise: CGFloat
        /// Labels are at least this far apart.
        var minLabelSpacing: CGFloat = 96
    }

    static let mac = Style(font: .lfbCaption, tickHeight: 6, labelInset: 3, labelRise: 14)
    static let pad = Style(font: .system(size: 12, weight: .medium), tickHeight: 7, labelInset: 4, labelRise: 15)

    private static let steps: [Double] = [1, 2, 5, 10, 15, 30, 60]

    /// Seconds between labels: the shortest step that keeps labels `minSpacing` apart.
    static func labelStep(visibleSeconds: Double, width: CGFloat, minSpacing: CGFloat) -> Double {
        let pointsPerSecond = width / CGFloat(max(visibleSeconds, 0.001))
        return steps.first { CGFloat($0) * pointsPerSecond >= minSpacing } ?? steps.last!
    }

    static func drawTicks(_ ctx: inout GraphicsContext, size: CGSize, duration: Double,
                          window: TimelineWindow, style: Style) {
        guard duration > 0, size.width > 0 else { return }
        let step = labelStep(visibleSeconds: window.visibleSeconds(duration: duration),
                             width: size.width, minSpacing: style.minLabelSpacing)
        var t = (window.start / step).rounded(.down) * step
        let end = min(window.end(duration: duration), duration)
        while t <= end + 0.0001 {
            let x = window.x(for: t, width: size.width, duration: duration)
            if t >= 0, x >= -1 {
                var tick = Path()
                tick.move(to: CGPoint(x: x, y: size.height - style.tickHeight))
                tick.addLine(to: CGPoint(x: x, y: size.height))
                ctx.stroke(tick, with: .color(.lfbTextTertiary))
                ctx.draw(Text(formatTimecode(t)).font(style.font).foregroundStyle(.secondary),
                         at: CGPoint(x: x + style.labelInset, y: size.height - style.labelRise), anchor: .leading)
            }
            t += step
        }
    }
}

// MARK: - Pinch and sideways scrolling

/// Pinch zooms the lanes in time (about the point under the fingers); sideways scrolling (a
/// trackpad swipe or ⇧-wheel on the Mac, two fingers or a trackpad on iPad) moves along the song.
/// Put it on the ruler and the rows, not the piano roll, which has its own.
struct TimelineZoomGestures: ViewModifier {
    @Bindable var model: ProjectViewModel
    /// Where the lanes start inside the modified view (the track headers' width).
    let laneX: CGFloat

    @State private var size: CGSize = .zero
    @State private var pinchStart: (zoom: Double, anchor: Double, x: CGFloat)?
    @State private var panStart: (start: Double, x: CGFloat)?

    private var laneWidth: CGFloat { max(size.width - laneX, 1) }
    private var duration: Double { model.duration }

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGSize.self, of: { $0.size }) { size = $0 }
            .simultaneousGesture(pinch)
            #if os(macOS)
            .overlay {
                SidewaysScrollCatcher { dx, precise in
                    let points = dx * (precise ? 1 : 8)
                    model.scrollTimeline(by: -Double(points / laneWidth) * model.timeline.visibleSeconds(duration: duration))
                }
            }
            #else
            .gesture(TwoFingerPan { state, x in
                switch state {
                case .began: panStart = (model.timeline.start, x)
                case .changed:
                    guard let pan = panStart else { return }
                    let seconds = -Double((x - pan.x) / laneWidth) * model.timeline.visibleSeconds(duration: duration)
                    model.scrollTimeline(by: pan.start + seconds - model.timeline.start)
                default: panStart = nil
                }
            })
            #endif
    }

    private var pinch: some Gesture {
        MagnifyGesture()
            .onChanged { g in
                guard model.displayedSnapshot != nil else { return }
                if pinchStart == nil {
                    let x = g.startLocation.x - laneX
                    let w = model.timeline
                    pinchStart = (w.zoom, w.time(atX: x, width: laneWidth, duration: duration), x)
                }
                guard let start = pinchStart else { return }
                model.zoomTimeline(to: start.zoom * Double(g.magnification), anchor: start.anchor)
            }
            .onEnded { _ in pinchStart = nil }
    }
}

extension View {
    func timelineZoomGestures(model: ProjectViewModel, laneX: CGFloat) -> some View {
        modifier(TimelineZoomGestures(model: model, laneX: laneX))
    }
}

extension ProjectViewModel {
    /// `--stage-zoom Z [seconds]` opens the lanes zoomed (and scrolled to a time), for screenshot checks.
    func applyLaunchStageZoom() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--stage-zoom"), args.count > i + 1, let z = Double(args[i + 1]) else { return }
        zoomTimeline(to: z)
        if args.count > i + 2, let at = Double(args[i + 2]) { scrollTimeline(by: at - timeline.start) }
    }
}

#if os(macOS)
/// Invisible AppKit view that takes only sideways scroll-wheel events; clicks, drags, pinches
/// and up/down scrolling (the rows scroll vertically when there are more than four) pass through.
private struct SidewaysScrollCatcher: NSViewRepresentable {
    var onScroll: (CGFloat, Bool) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView(); view.onScroll = onScroll; return view
    }
    func updateNSView(_ view: CatcherView, context: Context) { view.onScroll = onScroll }

    final class CatcherView: NSView {
        var onScroll: (CGFloat, Bool) -> Void = { _, _ in }
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent, event.type == .scrollWheel,
                  abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) else { return nil }
            return super.hitTest(point)
        }
        override func scrollWheel(with event: NSEvent) {
            onScroll(event.scrollingDeltaX, event.hasPreciseScrollingDeltas)
        }
    }
}
#else
/// Two-finger drag (and trackpad / mouse-wheel scrolling) as a SwiftUI gesture; one finger is
/// left to the lanes' own gestures (seek, select a section).
private struct TwoFingerPan: UIGestureRecognizerRepresentable {
    var action: (UIGestureRecognizer.State, CGFloat) -> Void

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.minimumNumberOfTouches = 2
        pan.allowedScrollTypesMask = .all
        return pan
    }
    /// Reports where the fingers are (`translation(in:)` reads 0 inside a representable).
    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        action(recognizer.state, context.converter.localLocation.x)
    }
}
#endif
