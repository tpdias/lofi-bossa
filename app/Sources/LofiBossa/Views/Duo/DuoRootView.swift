#if os(iOS)
import SwiftUI

/// iPhone Duo inner display (docs/design/HANDOFF.md §6, artboards `Duo*.dc.html`).
///
/// - `.twoPage` (fold vertical, flat or half folded like a book): the song on the left page,
///   Sound / Versions / Notes on the right page. In the library: the list on the left, a
///   preview of the selected project on the right.
/// - `.tabletop` (half folded, fold horizontal): watch on top (lanes), touch below (transport,
///   effects, solo).
///
/// The closed Duo is compact width and uses `PhoneRootView`. `LayoutModeReader` picks the mode
/// from the hinge and the fold (`DuoFoldSensor`); `--layout twoPage|tabletop` forces it.
///
/// Nothing here owns song state: playback, the loop, the selection, the open panel (the
/// model's `inspectorTab` and `isPianoRollOpen`) and any generation live in `AppSession` and
/// its `ProjectViewModel`, so folding and unfolding carry everything across (§2.3).
struct DuoRootView: View {
    let mode: LayoutMode
    @Environment(AppSession.self) private var session

    var body: some View {
        Group {
            switch session.selection {
            case .project(let id):
                if let model = session.activeModel, model.project.id == id {
                    if mode == .tabletop {
                        DuoTabletopView(model: model)
                    } else {
                        DuoTwoPageProjectView(model: model)
                    }
                } else {
                    ProgressView()
                }
            case .allProjects, .recentlyDeleted:
                DuoLibraryView(axis: mode == .tabletop ? .horizontal : .vertical)
            }
        }
        .background(Color.lfbWindow.ignoresSafeArea())
    }
}

/// Two pages with a gap centred on the fold (HANDOFF §6.2). The gap sits where the system says
/// the fold is (`FoldInfo.frame`, from the `.division` reserved region) and falls back to the
/// middle, so the same split is used flat and half folded and nothing jumps when the hinge
/// moves. Nothing interactive spans the gap.
///
/// `axis` is the fold's axis: `.vertical` puts the pages side by side, `.horizontal` stacks them.
struct DuoPages<First: View, Second: View>: View {
    var axis: FoldInfo.Axis = .vertical
    @ViewBuilder var first: First
    @ViewBuilder var second: Second
    @Environment(\.foldInfo) private var fold

    /// Page padding from `.d-pages` (0 8 8 side by side, 8 all round when stacked).
    private let edge: CGFloat = 8

    var body: some View {
        GeometryReader { geo in
            let split = splitPosition(in: geo)
            let gap = gapLength
            if axis == .vertical {
                HStack(spacing: gap) {
                    first.padding(.leading, edge).frame(width: max(split - gap / 2, 0))
                    second.padding(.trailing, edge).frame(width: max(geo.size.width - split - gap / 2, 0))
                }
                .padding(.bottom, edge)
            } else {
                VStack(spacing: gap) {
                    first.padding(.top, edge).frame(height: max(split - gap / 2, 0))
                    second.padding(.bottom, edge).frame(height: max(geo.size.height - split - gap / 2, 0))
                }
                .padding(.horizontal, edge)
            }
        }
    }

    /// Wider than the design's 24 pt only if the system reports a wider fold.
    private var gapLength: CGFloat {
        guard let frame = fold?.frame else { return LFBPhoneSize.foldGap }
        return max(LFBPhoneSize.foldGap, axis == .vertical ? frame.width : frame.height)
    }

    private func splitPosition(in geo: GeometryProxy) -> CGFloat {
        let length = axis == .vertical ? geo.size.width : geo.size.height
        if let frame = fold?.frame {
            let global = geo.frame(in: .global)
            let mid = axis == .vertical ? frame.midX - global.minX : frame.midY - global.minY
            // Only trust a fold that actually crosses this view (not, say, a narrow window).
            if mid > length * 0.25 && mid < length * 0.75 { return mid }
        }
        return length / 2
    }
}

/// The open project on the unfolded Duo: song on the left page, panel on the right page.
struct DuoTwoPageProjectView: View {
    @Bindable var model: ProjectViewModel
    @State private var showExport = false

    var body: some View {
        DuoPages(axis: .vertical) {
            DuoSongPage(model: model, onExport: { showExport = true })
        } second: {
            DuoPanelPage(model: model)
        }
        .padding(.top, 8)
        .sheet(isPresented: $showExport) { ExportSheetView(model: model) }
        .onReceive(NotificationCenter.default.publisher(for: .lfbExport)) { _ in
            if model.displayedSnapshot != nil { showExport = true }
        }
    }
}
#endif
