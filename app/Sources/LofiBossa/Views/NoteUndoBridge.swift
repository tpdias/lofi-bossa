import SwiftUI

/// Hands the window's `UndoManager` to the project's piano-roll undo stack while a roll is on
/// screen, so the Edit menu, ⌘Z / ⇧⌘Z, the iPad hardware keyboard and the iPhone's shake and
/// three-finger undo all step through note edits. The stack itself lives in `ProjectViewModel`.
private struct NoteUndoBridge: ViewModifier {
    let model: ProjectViewModel
    @Environment(\.undoManager) private var undoManager

    func body(content: Content) -> some View {
        content
            .onAppear { model.attachUndoManager(undoManager) }
            .onChange(of: undoManager) { _, manager in model.attachUndoManager(manager) }
            .onDisappear { model.attachUndoManager(nil) }
    }
}

extension View {
    func sharesNoteUndo(with model: ProjectViewModel) -> some View {
        modifier(NoteUndoBridge(model: model))
    }
}
