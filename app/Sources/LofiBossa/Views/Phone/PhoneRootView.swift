import SwiftUI

/// iPhone, iPhone Duo closed and narrow iPad Split View (docs/design/HANDOFF.md §5).
/// Placeholder: the Mac's `RootView`, whose split view collapses to a stack on compact width,
/// so the app runs but looks cramped (the inspector opens as a sheet from its toolbar button).
///
/// The iPhone layout work replaces this body (and lives in this folder): library grid in a
/// NavigationStack, the project screen with track cards, recipe strip and floating transport,
/// Sound / Versions / Track / Export sheets and the pushed piano roll. Read state from
/// `@Environment(AppSession.self)` (selection, activeModel, generator).
struct PhoneRootView: View {
    var body: some View {
        RootView(showsInspectorInitially: false)
    }
}
