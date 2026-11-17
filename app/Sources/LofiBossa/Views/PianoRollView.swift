import SwiftUI

/// Note editor for one track, opened as a split pane under the (now compact) track rows.
/// See design artboards "Editor" / "Editor · dark".
///
/// Simplification from the artboard: the roll always fits the whole song to the available
/// width (the same proportional mapping NoteLaneView and the ruler use), rather than a
/// scrollable/zoomable 24 s window. Editing is fully functional either way; true zoom can be
/// layered on later without changing the note model.
struct PianoRollView: View {
    @Bindable var model: ProjectViewModel
    let track: TrackID

    enum Tool { case select, draw }

    @State private var tool: Tool = .select
    @State private var snap: Double = 0.25   // seconds; 0 = off
    @State private var showOtherParts = true
    @State private var dragNoteID: Note.ID?
    @State private var dragMode: DragMode?
    @State private var dragOrigin: CGSize = .zero
    @State private var marqueeStart: CGPoint?
    @State private var marqueeRect: CGRect?

    private enum DragMode { case move(startPitch: Int, startTime: Double), resize(startDuration: Double) }

    private static let snapOptions: [Double] = [0, 0.1, 0.25, 0.5, 1]
    // Spelled out rather than formatted from the Double, so the decimal point doesn't turn
    // into a comma under locales that format numbers that way.
    private static let snapLabels: [Double: String] = [0: "Off", 0.1: "0.1s", 0.25: "0.25s", 0.5: "0.5s", 1: "1s"]
    private static let lowPitch = 36, highPitch = 96
    private static let rowHeight: CGFloat = 12
    private static let keyColumnWidth: CGFloat = 56

    private var notes: [Note] { model.displayedSnapshot?.track(track).notes ?? [] }
    private var duration: Double { max(model.duration, 1) }
    private var otherTracks: [Note] {
        guard showOtherParts, let snapshot = model.displayedSnapshot else { return [] }
        return snapshot.tracks.filter { $0.id != track }.flatMap(\.notes)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView(.vertical) {
                rollCanvas
                    .frame(height: CGFloat(Self.highPitch - Self.lowPitch + 1) * Self.rowHeight)
            }
            Divider()
            loudnessLane
        }
        .background(Color.lfbSurface)
        .focusable()
        .onDeleteCommand { deleteSelection() }
        .onMoveCommand { direction in
            switch direction {
            case .left: nudgeSelection(by: -effectiveSnap)
            case .right: nudgeSelection(by: effectiveSnap)
            case .up: transposeSelection(by: 1)
            case .down: transposeSelection(by: -1)
            @unknown default: break
            }
        }
    }

    private var effectiveSnap: Double { snap == 0 ? 0.05 : snap }

    // MARK: Header

    private var header: some View {
        HStack(spacing: LFBSpace.md) {
            TrackGlyph(id: track, size: 22)
            Text(track.title).font(.lfbHeadline)

            Picker("Tool", selection: $tool) {
                Image(systemName: "cursorarrow").tag(Tool.select)
                Image(systemName: "pencil.tip").tag(Tool.draw)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()

            Picker("Snap", selection: $snap) {
                ForEach(Self.snapOptions, id: \.self) { s in
                    Text(Self.snapLabels[s] ?? "\(s)s").tag(s)
                }
            }
            .pickerStyle(.menu).fixedSize()

            Toggle("Show other parts", isOn: $showOtherParts).toggleStyle(.button).controlSize(.small)

            Spacer()

            if !selectedNotes.isEmpty {
                Text("\(selectedNotes.count) selected").font(.lfbCaption).foregroundStyle(Color.lfbTextSecondary)
                HStack(spacing: 6) {
                    Image(systemName: "speaker.wave.1").font(.caption)
                    Slider(value: loudnessBinding, in: 1...127).frame(width: 90)
                }
                Button(role: .destructive, action: deleteSelection) { Image(systemName: "trash") }
                    .buttonStyle(.plain)
            }

            Button("Done") { model.closeEditor() }.buttonStyle(.borderedProminent).controlSize(.small)
        }
        .padding(.horizontal, LFBSpace.md).padding(.vertical, LFBSpace.sm)
    }

    private var selectedNotes: [Note] { notes.filter { model.selectedNoteIDs.contains($0.id) } }

    private var loudnessBinding: Binding<Double> {
        Binding(
            get: { Double(selectedNotes.map(\.velocity).reduce(0, +)) / Double(max(selectedNotes.count, 1)) },
            set: { newValue in
                var updated = notes
                for i in updated.indices where model.selectedNoteIDs.contains(updated[i].id) {
                    updated[i].velocity = Int(newValue.rounded())
                }
                model.updateEditingNotes(updated, for: track)
            }
        )
    }

    // MARK: Roll

    private func pitchToY(_ pitch: Int) -> CGFloat { CGFloat(Self.highPitch - pitch) * Self.rowHeight }
    private func yToPitch(_ y: CGFloat) -> Int {
        min(max(Self.highPitch - Int(y / Self.rowHeight), Self.lowPitch), Self.highPitch)
    }
    private func snapTime(_ t: Double) -> Double {
        guard snap > 0 else { return max(t, 0) }
        return max((t / snap).rounded() * snap, 0)
    }

    private var rollCanvas: some View {
        HStack(spacing: 0) {
            pianoKeys
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    rowBackground(width: geo.size.width)
                    Canvas { ctx, size in
                        draw(otherTracks, in: &ctx, size: size, color: .secondary.opacity(0.25), selected: [])
                        draw(notes, in: &ctx, size: size, color: track.color, selected: model.selectedNoteIDs)
                    }
                    if let rect = marqueeRect {
                        Rectangle().fill(Color.lfbAccent.opacity(0.12))
                            .overlay(Rectangle().stroke(Color.lfbAccent, lineWidth: 1))
                            .frame(width: rect.width, height: rect.height)
                            .offset(x: rect.minX, y: rect.minY)
                    }
                }
                .contentShape(Rectangle())
                .gesture(canvasDrag(width: geo.size.width))
                .onTapGesture(count: 2) { addNote(at: $0, width: geo.size.width) }
                .onTapGesture(count: 1) { tapCanvas(at: $0, width: geo.size.width) }
            }
        }
    }

    private var pianoKeys: some View {
        Canvas { ctx, size in
            for pitch in Self.lowPitch...Self.highPitch {
                let y = pitchToY(pitch)
                let isBlack = [1, 3, 6, 8, 10].contains(pitch % 12)
                ctx.fill(Path(CGRect(x: 0, y: y, width: size.width, height: Self.rowHeight)),
                         with: .color(isBlack ? Color.black.opacity(0.08) : .clear))
                if pitch % 12 == 0 {
                    ctx.draw(Text("C\(pitch / 12 - 1)").font(.system(size: 9)).foregroundStyle(.secondary),
                             at: CGPoint(x: size.width - 4, y: y + Self.rowHeight / 2), anchor: .trailing)
                }
            }
        }
        .frame(width: Self.keyColumnWidth)
        .background(Color.lfbWell)
    }

    private func rowBackground(width: CGFloat) -> some View {
        Canvas { ctx, size in
            for pitch in Self.lowPitch...Self.highPitch {
                let y = pitchToY(pitch)
                if [1, 3, 6, 8, 10].contains(pitch % 12) {
                    ctx.fill(Path(CGRect(x: 0, y: y, width: width, height: Self.rowHeight)),
                             with: .color(.black.opacity(0.03)))
                }
            }
        }
    }

    private func draw(_ notes: [Note], in ctx: inout GraphicsContext, size: CGSize, color: Color, selected: Set<Note.ID>) {
        for n in notes {
            let x = CGFloat(n.start / duration) * size.width
            let w = max(CGFloat(n.duration / duration) * size.width, 3)
            let y = pitchToY(n.pitch)
            let rect = CGRect(x: x, y: y + 1, width: w, height: Self.rowHeight - 2)
            let isSelected = selected.contains(n.id)
            ctx.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(isSelected ? color : color.opacity(0.85)))
            if isSelected {
                ctx.stroke(Path(roundedRect: rect, cornerRadius: 2), with: .color(.lfbText), lineWidth: 1.5)
            }
        }
    }

    private func noteRect(_ n: Note, width: CGFloat) -> CGRect {
        CGRect(x: CGFloat(n.start / duration) * width, y: pitchToY(n.pitch),
               width: max(CGFloat(n.duration / duration) * width, 3), height: Self.rowHeight)
    }

    private func hitTest(_ point: CGPoint, width: CGFloat) -> (note: Note, nearRightEdge: Bool)? {
        for n in notes.reversed() {
            let r = noteRect(n, width: width)
            if r.insetBy(dx: -1, dy: 0).contains(point) {
                return (n, point.x > r.maxX - 6)
            }
        }
        return nil
    }

    // MARK: Gestures

    private func tapCanvas(at point: CGPoint, width: CGFloat) {
        if let hit = hitTest(point, width: width) {
            model.selectedNoteIDs = [hit.note.id]
        } else if tool == .draw {
            addNote(at: point, width: width)
        } else {
            model.selectedNoteIDs = []
        }
    }

    private func addNote(at point: CGPoint, width: CGFloat) {
        let start = snapTime(Double(point.x / width) * duration)
        let pitch = yToPitch(point.y)
        let note = Note(pitch: pitch, start: start, duration: max(snap, 0.25), velocity: 90)
        model.updateEditingNotes(notes + [note], for: track)
        model.selectedNoteIDs = [note.id]
    }

    private func canvasDrag(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { g in
                if dragMode == nil && dragNoteID == nil && marqueeStart == nil {
                    if let hit = hitTest(g.startLocation, width: width) {
                        dragNoteID = hit.note.id
                        if !model.selectedNoteIDs.contains(hit.note.id) { model.selectedNoteIDs = [hit.note.id] }
                        dragMode = hit.nearRightEdge ? .resize(startDuration: hit.note.duration)
                                                      : .move(startPitch: hit.note.pitch, startTime: hit.note.start)
                    } else {
                        marqueeStart = g.startLocation
                    }
                }
                if let start = marqueeStart {
                    let rect = CGRect(x: min(start.x, g.location.x), y: min(start.y, g.location.y),
                                      width: abs(g.location.x - start.x), height: abs(g.location.y - start.y))
                    marqueeRect = rect
                    model.selectedNoteIDs = Set(notes.filter { noteRect($0, width: width).intersects(rect) }.map(\.id))
                } else if let id = dragNoteID, let mode = dragMode {
                    applyDrag(mode, translation: g.translation, width: width, draggedID: id)
                }
            }
            .onEnded { _ in
                dragNoteID = nil; dragMode = nil; marqueeStart = nil; marqueeRect = nil
            }
    }

    private func applyDrag(_ mode: DragMode, translation: CGSize, width: CGFloat, draggedID: Note.ID) {
        guard let anchor = notes.first(where: { $0.id == draggedID }) else { return }
        var updated = notes
        switch mode {
        case .move(let startPitch, let startTime):
            let dt = snapTime(startTime + Double(translation.width / width) * duration) - startTime
            let dPitch = -Int((translation.height / Self.rowHeight).rounded())
            for id in model.selectedNoteIDs {
                guard let i = updated.firstIndex(where: { $0.id == id }) else { continue }
                updated[i].start = max(updated[i].start + dt, 0)
                updated[i].pitch = min(max(updated[i].pitch + dPitch, Self.lowPitch), Self.highPitch)
            }
            _ = (startPitch, anchor)
        case .resize(let startDuration):
            let newDuration = max(snapTime(startDuration + Double(translation.width / width) * duration), 0.05)
            if let i = updated.firstIndex(where: { $0.id == draggedID }) { updated[i].duration = newDuration }
        }
        model.updateEditingNotes(updated, for: track)
    }

    private func nudgeSelection(by dt: Double) {
        guard !model.selectedNoteIDs.isEmpty else { return }
        var updated = notes
        for i in updated.indices where model.selectedNoteIDs.contains(updated[i].id) {
            updated[i].start = max(updated[i].start + dt, 0)
        }
        model.updateEditingNotes(updated, for: track)
    }

    private func transposeSelection(by semitones: Int) {
        guard !model.selectedNoteIDs.isEmpty else { return }
        var updated = notes
        for i in updated.indices where model.selectedNoteIDs.contains(updated[i].id) {
            updated[i].pitch = min(max(updated[i].pitch + semitones, Self.lowPitch), Self.highPitch)
        }
        model.updateEditingNotes(updated, for: track)
    }

    private func deleteSelection() {
        guard !model.selectedNoteIDs.isEmpty else { return }
        model.updateEditingNotes(notes.filter { !model.selectedNoteIDs.contains($0.id) }, for: track)
        model.selectedNoteIDs = []
    }

    // MARK: Loudness lane

    private var loudnessLane: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                for n in notes {
                    let x = CGFloat(n.start / duration) * size.width
                    let h = CGFloat(n.velocity) / 127 * size.height
                    let isSelected = model.selectedNoteIDs.contains(n.id)
                    ctx.fill(Path(CGRect(x: x, y: size.height - h, width: 3, height: h)),
                             with: .color(isSelected ? .lfbAccent : track.color.opacity(0.7)))
                }
            }
        }
        .frame(height: 36)
        .background(Color.lfbWell)
    }
}
