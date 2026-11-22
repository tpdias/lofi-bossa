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

/// Where the fold is. `LayoutModeReader` sets it from Apple's iOS 27.1 fold APIs (see
/// `Views/Duo/DuoFoldSensor.swift`: `onHingeChange` for the hinge status and the `.division`
/// `ReservedRegion` for where the fold runs). With no fold it stays nil and the size class decides.
struct FoldInfo: Equatable {
    enum Axis { case vertical, horizontal }
    var axis: Axis              // vertical = book held open; horizontal = rotated, fold across
    var isHalfFolded: Bool      // partially open; prefer the hinge *status*, not an angle threshold
    /// The fold's area in global coordinates, so a layout can centre its gap on it. Nil when
    /// only the posture is known (for example under `--layout`); layouts then split in half.
    var frame: CGRect? = nil
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
    @Environment(\.foldInfo) private var outerFold
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontal
    /// What the hinge and the reserved regions say (iOS 27.1 and later; nil elsewhere).
    @State private var sensedFold: FoldInfo?
    #endif

    /// A fold set from outside (previews, tests) wins over the sensed one.
    private var fold: FoldInfo? {
        #if os(iOS)
        outerFold ?? sensedFold
        #else
        outerFold
        #endif
    }

    var body: some View {
        #if os(iOS)
        content(mode)
            .environment(\.foldInfo, fold)
            .modifier(DuoFoldSensor(fold: $sensedFold))
        #else
        content(mode)
        #endif
    }

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
