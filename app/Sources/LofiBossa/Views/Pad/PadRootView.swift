import SwiftUI

/// iPad (and any regular-width iOS window): the Mac layout, touch-sized
/// (docs/design/HANDOFF.md §4). Placeholder: today it is the Mac's `RootView` unchanged.
///
/// The iPad layout work goes here and in this folder: touch sizes from `LFBTouchSize`,
/// sidebar hidden while a project is open, inspector as an overlay in portrait, Pencil in the
/// piano roll, Share / Save to Files after export.
struct PadRootView: View {
    var body: some View {
        RootView()
    }
}
