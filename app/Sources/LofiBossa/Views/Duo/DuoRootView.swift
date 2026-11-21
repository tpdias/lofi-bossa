import SwiftUI

/// iPhone Duo open: two pages, or tabletop when half folded with the fold horizontal
/// (docs/design/HANDOFF.md §6). Placeholder: the Mac's `RootView`.
///
/// Nothing selects these modes yet: the Duo work sets `\.foldInfo` from the iOS 27.1 fold APIs
/// (see Platform/LayoutMode.swift). Until then launch with `--layout twoPage` or
/// `--layout tabletop` to see this view on any simulator. The closed Duo is compact width and
/// uses `PhoneRootView`.
struct DuoRootView: View {
    let mode: LayoutMode

    var body: some View {
        RootView()
    }
}
