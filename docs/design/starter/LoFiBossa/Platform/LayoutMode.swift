import SwiftUI

/// Which layout the app uses. Chosen from size classes and the fold, never from the device model,
/// so Split View on iPad, Stage Manager and the iPhone Duo all fall out of the same rule.
enum LayoutMode: Equatable {
    case compact     // iPhone, iPhone Duo closed, narrow iPad Split View: stacked cards + sheets
    case regular     // Mac, iPad: sidebar + stage + inspector (the Mac layout, touch-sized on iPad)
    case twoPage     // iPhone Duo open with a vertical fold: song on one page, panel on the other
    case tabletop    // iPhone Duo half folded with a horizontal fold: watch on top, touch below
}

/// Where the fold is. Populate this from Apple's iPhone Duo APIs (iOS 27.1 SDK).
/// Apple's developer forum names `onHingeChange` (hinge angle and status), `ReservedRegion`
/// (fold and camera occlusion) and `ArrangementView` (split layouts across the fold).
/// Confirm the shipping signatures in the documentation before wiring them in; until then the
/// app behaves like an iPad on the inner display, which is Apple's default for regular/regular.
struct FoldInfo: Equatable {
    enum Axis { case vertical, horizontal }
    var axis: Axis              // vertical = book held open; horizontal = rotated, fold across
    var isHalfFolded: Bool      // partially open; prefer the hinge *status*, not an angle threshold
}

private struct FoldInfoKey: EnvironmentKey { static let defaultValue: FoldInfo? = nil }

extension EnvironmentValues {
    var foldInfo: FoldInfo? {
        get { self[FoldInfoKey.self] }
        set { self[FoldInfoKey.self] = newValue }
    }
}

struct LayoutModeReader<Content: View>: View {
    @ViewBuilder var content: (LayoutMode) -> Content
    @Environment(\.foldInfo) private var fold
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontal
    #endif

    var body: some View { content(mode) }

    private var mode: LayoutMode {
        if let fold {
            if fold.axis == .horizontal && fold.isHalfFolded { return .tabletop }
            if fold.axis == .vertical { return .twoPage }
        }
        #if os(iOS)
        return horizontal == .compact ? .compact : .regular
        #else
        return .regular
        #endif
    }
}
