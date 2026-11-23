import SwiftUI

/// The project in the front window, for the menu bar (menu items live outside the window, so
/// they can't reach the view model directly).
private struct ProjectModelKey: FocusedValueKey { typealias Value = ProjectViewModel }
extension FocusedValues {
    var projectModel: ProjectViewModel? {
        get { self[ProjectModelKey.self] }
        set { self[ProjectModelKey.self] = newValue }
    }
}

/// Every menu and its shortcuts. `KeyboardShortcuts.groups` below is the same list in a form
/// the Keyboard Shortcuts sheet shows, so keep them together.
struct AppCommands: Commands {
    @FocusedValue(\.projectModel) private var model

    private func post(_ name: Notification.Name) { NotificationCenter.default.post(name: name, object: nil) }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Project") { post(.lfbNewProject) }.keyboardShortcut("n")
        }

        // Undo/Redo step through note edits while a piano roll is open (the model routes them
        // through the window's UndoManager), and through versions otherwise. Inside a text field
        // (rename, seed) they must still undo typing, so they pass the key on to the text system there.
        CommandGroup(replacing: .undoRedo) {
            Button(model?.undoTitle.map { "Undo \($0)" } ?? "Undo") { undo() }
                .keyboardShortcut("z")
                .disabled(!inTextField && model?.canUndo != true)
            Button(model?.redoTitle.map { "Redo \($0)" } ?? "Redo") { redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!inTextField && model?.canRedo != true)
        }

        CommandMenu("Song") {
            Button("Generate New Take") { post(.lfbGenerate) }.keyboardShortcut(.return, modifiers: .command)
            Button("Extend Song by 30 Seconds") { model?.extend() }
                .keyboardShortcut(.return, modifiers: [.command, .shift])
                .disabled(!(model?.canExtend ?? false))
            Button("Copy Seed") { post(.lfbCopySeed) }.keyboardShortcut("c", modifiers: [.command, .shift])
            Divider()
            Button("Export…") { post(.lfbExport) }.keyboardShortcut("e", modifiers: .command)
        }

        CommandMenu("Transport") {
            Button(model?.isPlaying == true ? "Pause" : "Play") { model?.togglePlay() }
                .disabled(model?.displayedSnapshot == nil)
            Button("Go to Start") { model?.seek(to: 0) }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
            Divider()
            Button("Back 1 Second") { model?.nudgePlayhead(by: -1) }.keyboardShortcut("[", modifiers: .command)
            Button("Forward 1 Second") { model?.nudgePlayhead(by: 1) }.keyboardShortcut("]", modifiers: .command)
            Button("Back 5 Seconds") { model?.nudgePlayhead(by: -5) }.keyboardShortcut("[", modifiers: [.command, .shift])
            Button("Forward 5 Seconds") { model?.nudgePlayhead(by: 5) }.keyboardShortcut("]", modifiers: [.command, .shift])
            Divider()
            Button("Loop Selection") { post(.lfbToggleLoop) }.keyboardShortcut("l", modifiers: .command)
        }

        CommandMenu("Track") {
            ForEach(Array(TrackID.allCases.enumerated()), id: \.element) { index, id in
                Button("Select \(id.title)") { model?.selectTrack(id) }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                    .disabled(model?.displayedSnapshot?.hasTrack(id) != true)
            }
            Divider()
            Menu("Add Track") {
                ForEach(TrackID.optional) { id in
                    Button(id.title) { model?.addTrack(id) }
                        .disabled(model?.addableTracks.contains(id) != true || model?.canChangeTracks != true)
                }
            }
            Menu("Remove Track") {
                ForEach(TrackID.optional) { id in
                    Button(id.title) { model?.removeTrack(id) }
                        .disabled(model?.displayedSnapshot?.hasTrack(id) != true || model?.canChangeTracks != true)
                }
            }
            Divider()
            Button("Mute Track") { model?.toggleMuteOfSelectedTrack() }
                .keyboardShortcut("m", modifiers: [.command, .option])
            Button("Solo Track") { model?.toggleSoloOfSelectedTrack() }
                .keyboardShortcut("s", modifiers: [.command, .option])
            Button("Lock Track") { model?.toggleLockOfSelectedTrack() }
                .keyboardShortcut("l", modifiers: [.command, .option])
            Divider()
            Button("Open Piano Roll") { model?.openEditorForSelectedTrack() }
                .keyboardShortcut("p", modifiers: [.command, .option])
            Button("Rewrite Track with the Model") { model?.rewriteSelectedTrack() }
                .keyboardShortcut("r", modifiers: .command)
        }
        // The Track items work on the track chosen with ⌘1–⌘4 (or clicked); with none chosen they do nothing.

        CommandGroup(after: .sidebar) {
            Button("Toggle Inspector") { post(.lfbToggleInspector) }.keyboardShortcut("i", modifiers: [.command, .option])
            Divider()
            // The track lanes' timeline, or the piano roll's while it is open (it has its own zoom).
            Button("Zoom In") { zoom(.in) }
                .keyboardShortcut("=", modifiers: .command)
                .disabled(!canZoom(.in))
            Button("Zoom Out") { zoom(.out) }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(!canZoom(.out))
            Button(model?.isPianoRollOpen == true ? "Show Whole Song in Roll" : "Show Whole Song") { zoom(.fit) }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(!canZoom(.fit))
        }

        CommandGroup(replacing: .help) {
            Button("Keyboard Shortcuts") { post(.lfbShowShortcuts) }.keyboardShortcut("/", modifiers: .command)
        }
    }

    private func zoom(_ command: TimelineZoomCommand) {
        guard let model else { return }
        if model.isPianoRollOpen {
            NotificationCenter.default.post(name: .lfbRollZoom, object: command)
            return
        }
        switch command {
        case .in: model.zoomTimelineIn()
        case .out: model.zoomTimelineOut()
        case .fit: model.zoomTimelineToFit()
        }
    }
    private func canZoom(_ command: TimelineZoomCommand) -> Bool {
        guard let model, model.displayedSnapshot != nil else { return false }
        if model.isPianoRollOpen { return true }
        return command == .in ? model.canZoomTimelineIn : model.canZoomTimelineOut
    }

    #if os(macOS)
    private var inTextField: Bool { NSApp.keyWindow?.firstResponder is NSText }

    private func undo() {
        if inTextField { NSApp.sendAction(Selector(("undo:")), to: nil, from: nil) } else { model?.undo() }
    }
    private func redo() {
        if inTextField { NSApp.sendAction(Selector(("redo:")), to: nil, from: nil) } else { model?.redo() }
    }
    #else
    private var inTextField: Bool { false }
    private func undo() { model?.undo() }
    private func redo() { model?.redo() }
    #endif
}

/// What the Keyboard Shortcuts sheet lists. Menu items are above; the rest are keys the window
/// handles itself (they only work when the thing they act on has focus).
enum KeyboardShortcuts {
    struct Item: Identifiable { let id = UUID(); let keys: String; let what: String }
    struct Group: Identifiable { let id = UUID(); let title: String; let items: [Item] }

    static let groups: [Group] = [
        Group(title: "Song", items: [
            Item(keys: "⌘N", what: "New project"),
            Item(keys: "⌘↩", what: "Generate a new take (locked tracks stay)"),
            Item(keys: "⇧⌘↩", what: "Extend the song by 30 seconds"),
            Item(keys: "⇧⌘C", what: "Copy the seed"),
            Item(keys: "⌘E", what: "Export"),
            Item(keys: "⌘Z / ⇧⌘Z", what: "Undo / redo (note edits in the piano roll, else versions)"),
        ]),
        Group(title: "Transport", items: [
            Item(keys: "Space", what: "Play / pause"),
            Item(keys: "⌥⌘←", what: "Go to start"),
            Item(keys: "⌘[ / ⌘]", what: "Back / forward 1 second"),
            Item(keys: "⇧⌘[ / ⇧⌘]", what: "Back / forward 5 seconds"),
            Item(keys: "⌘L", what: "Loop the selection"),
        ]),
        Group(title: "Tracks", items: [
            Item(keys: "⌘1 – ⌘7", what: "Select the first to seventh track"),
            Item(keys: "⌥⌘M / ⌥⌘S", what: "Mute / solo the selected track"),
            Item(keys: "⌥⌘L", what: "Lock / unlock the selected track"),
            Item(keys: "⌥⌘P", what: "Open the piano roll for the selected track"),
            Item(keys: "⌘R", what: "Rewrite the selected track with the model"),
            Item(keys: "⌥⌘I", what: "Show / hide the inspector"),
        ]),
        Group(title: "Timeline", items: [
            Item(keys: "⌘+ / ⌘− / ⌘0", what: "Zoom the track lanes in / out / show the whole song"),
            Item(keys: "Pinch", what: "Zoom the lanes around the pointer"),
            Item(keys: "Swipe sideways", what: "Scroll along the song when zoomed (two fingers on iPad)"),
        ]),
        Group(title: "Sections (after dragging on a track)", items: [
            Item(keys: "⌘X ⌘C ⌘V", what: "Cut, copy, paste at the playhead"),
            Item(keys: "⌘D", what: "Duplicate after the selection"),
            Item(keys: "⌫", what: "Delete the selection"),
            Item(keys: "Esc", what: "Clear the selection"),
        ]),
        Group(title: "Piano roll", items: [
            Item(keys: "V / P", what: "Select / draw tool"),
            Item(keys: "⌘A", what: "Select all notes"),
            Item(keys: "⌘X ⌘C ⌘V ⌘D", what: "Cut, copy, paste, duplicate"),
            Item(keys: "⌫", what: "Delete the selected notes"),
            Item(keys: "← →", what: "Nudge by the snap amount"),
            Item(keys: "↑ ↓  (⌥ = octave)", what: "Move a semitone"),
            Item(keys: "⌘+ / ⌘− / ⌘0", what: "Zoom in / out / fit"),
            Item(keys: "Esc", what: "Deselect"),
        ]),
    ]
}

struct ShortcutsSheet: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Keyboard Shortcuts").font(.lfbTitle)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(LFBSpace.lg)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: LFBSpace.lg) {
                    ForEach(KeyboardShortcuts.groups) { group in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(group.title).font(.lfbHeadline)
                            ForEach(group.items) { item in
                                HStack(alignment: .firstTextBaseline) {
                                    Text(item.keys).font(.system(.body, design: .monospaced))
                                        .frame(width: 170, alignment: .leading)
                                    Text(item.what).foregroundStyle(Color.lfbTextSecondary)
                                }
                            }
                        }
                    }
                }
                .padding(LFBSpace.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 520, height: 560)
    }
}
