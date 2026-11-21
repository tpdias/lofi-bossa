import SwiftUI

/// Which layout the app uses. Chosen from size classes and the fold, never from the device
/// model, so iPad Split View, Stage Manager and the iPhone Duo all follow one rule
/// (docs/design/HANDOFF.md §2.1). `AdaptiveRootView` switches on it.
enum LayoutMode: Equatable {
    case compact     // iPhone, iPhone Duo closed, narrow iPad Split View: stacked cards + sheets
    case regular     // Mac, iPad: sidebar + stage + inspector (the Mac layout, touch-sized on iPad)
    case twoPage     // iPhone Duo open with a vertical fold: song on one page, panel on the other
    case tabletop    // iPhone Duo half folded with a horizontal fold: watch on top, touch below
}

/// Where the fold is. Nothing sets this yet: the Duo layout session populates it from Apple's
/// iOS 27.1 fold APIs (`onHingeChange`, `ReservedRegion`, `ArrangementView`; verify the shipping
/// signatures first). Until then the Duo's inner display behaves like an iPad (regular/regular).
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

/// Reads the size class and the fold and hands the resulting `LayoutMode` to its content.
struct LayoutModeReader<Content: View>: View {
    @ViewBuilder var content: (LayoutMode) -> Content
    @Environment(\.foldInfo) private var fold
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontal
    #endif

    var body: some View { content(mode) }

    /// `--layout compact|regular|twoPage|tabletop` forces a layout, so each one can be built and
    /// checked on any simulator (there is no iPhone Duo simulator with fold APIs yet).
    static var forced: LayoutMode? {
        let args = CommandLine.arguments
        guard let flag = args.firstIndex(of: "--layout"), args.count > flag + 1 else { return nil }
        switch args[flag + 1] {
        case "compact": return .compact
        case "regular": return .regular
        case "twoPage": return .twoPage
        case "tabletop": return .tabletop
        default: return nil
        }
    }

    private var mode: LayoutMode {
        if let forced = Self.forced { return forced }
        #if os(iOS)
        if let fold {
            if fold.axis == .horizontal && fold.isHalfFolded { return .tabletop }
            if fold.axis == .vertical { return .twoPage }
        }
        return horizontal == .compact ? .compact : .regular
        #else
        return .regular
        #endif
    }
}
