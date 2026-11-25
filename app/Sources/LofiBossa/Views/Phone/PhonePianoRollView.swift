import SwiftUI

#if os(iOS)
/// The iPhone piano roll, pushed full screen from "Edit notes" (HANDOFF §5.5, artboards
/// "iPhone · piano roll", "… landscape"). The one iPhone screen that rotates.
///
/// - Portrait: top bar (Done, title, Select / Draw), option chips (Snap, Show other parts, Undo),
///   the roll at 18 pt rows over a 12 s window, the loudness lane, then the action bar
///   ("N selected · Loudness", Duplicate, Delete, Play).
/// - Landscape: one top bar holds every control; 12 pt rows over 24 s.
/// - Touch: tap a note to select, tap empty space to deselect (Draw: add a note at the snap
///   length). Drag a selected note to move it, its round handle to resize. One-finger drag on
///   empty space scrolls time and pitch, pinch zooms time, long press then drag draws a marquee.
///   Drag a stem in the loudness lane to change that note's loudness.
/// - The other parts keep playing. Done adds one version for the session (as on the Mac).
/// - Undo walks the session's note edits on `ProjectViewModel`'s stack, the same one shake /
///   three-finger undo reach through the window's undo manager.
struct PhonePianoRollView: View {
    @Bindable var model: ProjectViewModel
    let track: TrackID
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    enum Tool { case select, draw }
    @State private var tool: Tool = .select
    @State private var snap: Double = 0.25
    @State private var showOtherParts = true
    /// The visible window: `startTime` at the left edge, `visibleSeconds` wide (zoom), and the
    /// (fractional) pitch at the top row.
    @State private var startTime: Double = 0
    @State private var visibleSeconds: Double = 12
    @State private var topPitch: Double = 76
    @State private var gridSize: CGSize = CGSize(width: 320, height: 400)
    @State private var didPlace = false

    // gesture state
    @State private var dragKind: DragKind?
    @State private var dragOriginals: [Note.ID: Note] = [:]
    @State private var dragAnchor: Note.ID?
    @State private var panOrigin: (time: Double, pitch: Double) = (0, 0)
    @State private var longPressArmed = false
    @State private var touchStart: Date?
    @State private var marquee: CGRect?
    @State private var pinchBase: Double?
    @State private var pinchAnchor: Double = 0
    @State private var stemID: Note.ID?
    @State private var lastAuditioned: Int?

    private enum DragKind { case move, resize, pan, marquee }

    private static let lowPitch = 21, highPitch = 108
    private static let blackKeys: Set<Int> = [1, 3, 6, 8, 10]
    private static let snapOptions: [Double] = [0, 0.1, 0.25, 0.5, 1]
    private static let snapLabels: [Double: String] = [0: "Off", 0.1: "0.1 s", 0.25: "0.25 s", 0.5: "0.5 s", 1: "1 s"]

    private var isLandscape: Bool { verticalSizeClass == .compact }
    private var rowH: CGFloat { isLandscape ? LFBPhoneSize.pianoRowHeightLandscape : LFBPhoneSize.pianoRowHeight }
    private var keyW: CGFloat { LFBPhoneSize.pianoKeyColumn }
    private var notes: [Note] { model.displayedSnapshot?.track(track).notes ?? [] }
    private var selected: [Note] { notes.filter { model.selectedNoteIDs.contains($0.id) } }
    private var duration: Double { max(model.duration, 1) }
    private var pps: CGFloat { gridSize.width / CGFloat(visibleSeconds) }
    private var visibleRows: Double { Double(gridSize.height / rowH) }
    private var instrument: String { model.displayedSnapshot?.track(track).instrument ?? track.defaultInstrument }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            if !isLandscape { optionBar }
            roll
            if !isLandscape { actionBar }
        }
        .background(Color.lfbWindow)
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            PhoneOrientation.set(.allButUpsideDown)
            visibleSeconds = min(isLandscape ? 24 : 12, duration)
        }
        .onDisappear { PhoneOrientation.set(.portrait) }
        .onChange(of: isLandscape) { _, land in
            // Keep the same start; the window widens to 24 s (or back to 12 s) like the artboards.
            visibleSeconds = min(land ? 24 : 12, duration)
            clampView()
        }
        .onChange(of: model.position) { _, p in followPlayhead(p) }
        .sharesNoteUndo(with: model)
    }

    // MARK: Bars

    private var title: some View {
        VStack(spacing: 0) {
            Text(track.title).font(.system(size: 16, weight: .semibold, design: .rounded))
            Text("\(instrument) · \(formatTimecode(startTime)) – \(formatTimecode(min(startTime + visibleSeconds, duration)))")
                .font(.system(size: 12)).foregroundStyle(Color.lfbTextTertiary).monospacedDigit()
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity)
        .layoutPriority(-1)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private var topBar: some View {
        HStack(spacing: 6) {
            Button("Done") { model.closeEditor() }
                .buttonStyle(PhoneChipStyle())
                .fontWeight(.semibold)
                .fixedSize()
                .accessibilityIdentifier("roll-done")
            title
            toolPicker
            if isLandscape {
                snapMenu
                otherPartsChip
                undoButton
                selectionControls
                playButton(size: 40)
            }
        }
        .padding(.horizontal, isLandscape ? 0 : 10)
        .frame(height: LFBPhoneSize.navBar + 6)
        .tint(track.color)
    }

    private var toolPicker: some View {
        Picker("Tool", selection: $tool) {
            Image(systemName: "hand.point.up.left").tag(Tool.select).accessibilityLabel("Select")
            Image(systemName: "pencil").tag(Tool.draw).accessibilityLabel("Draw")
        }
        .pickerStyle(.segmented)
        .frame(width: 96)
    }

    private var optionBar: some View {
        HStack(spacing: LFBSpace.sm) {
            snapMenu
            otherPartsChip
            Spacer()
            undoButton
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    private var snapMenu: some View {
        Menu {
            Picker("Snap", selection: $snap) {
                ForEach(Self.snapOptions, id: \.self) { Text(Self.snapLabels[$0] ?? "\($0)").tag($0) }
            }
        } label: {
            HStack(spacing: 5) {
                Text(isLandscape ? (Self.snapLabels[snap] ?? "") : "Snap \(Self.snapLabels[snap] ?? "")")
                Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.lfbTextTertiary)
            }
        }
        .buttonStyle(PhoneChipStyle())
        .fixedSize()
        .accessibilityLabel("Snap \(Self.snapLabels[snap] ?? "")")
    }

    private var otherPartsChip: some View {
        Button(isLandscape ? "Other parts" : "Show other parts") { showOtherParts.toggle() }
            .buttonStyle(PhoneChipStyle(isOn: showOtherParts))
            .fixedSize()
            .accessibilityAddTraits(showOtherParts ? .isSelected : [])
    }

    private var undoButton: some View {
        Button(action: model.undoNoteEdit) { Image(systemName: "arrow.uturn.backward").font(.system(size: 19)).frame(width: 44, height: 44) }
            .disabled(!model.canUndoNoteEdit)
            .foregroundStyle(model.canUndoNoteEdit ? Color.lfbAccentText : Color.lfbTextTertiary)
            .accessibilityLabel(model.noteUndoTitle.map { "Undo \($0)" } ?? "Undo note edit")
            .accessibilityIdentifier("roll-undo")
    }

    @ViewBuilder private var selectionControls: some View {
        Text(selected.isEmpty ? (isLandscape ? "" : "Tap a note to select it") : "\(selected.count) selected\(isLandscape ? "" : " · Loudness")")
            .font(.system(size: 13)).foregroundStyle(Color.lfbTextSecondary).lineLimit(1).fixedSize()
        if !selected.isEmpty {
            Slider(value: loudnessBinding, in: 1...127) { editing in
                editing ? model.beginNoteGesture() : model.endNoteGesture()
            }
                .frame(minWidth: 80, maxWidth: isLandscape ? 110 : .infinity)
                .accessibilityLabel("Loudness of the selected notes")
        } else if !isLandscape {
            Spacer()
        }
        Button(action: duplicateSelection) { Image(systemName: "plus.square.on.square").frame(width: 44, height: 44) }
            .disabled(selected.isEmpty).accessibilityLabel("Duplicate selected notes")
        Button(action: deleteSelection) { Image(systemName: "trash").frame(width: 44, height: 44) }
            .disabled(selected.isEmpty).accessibilityLabel("Delete selected notes")
            .accessibilityIdentifier("roll-delete")
    }

    private var actionBar: some View {
        HStack(spacing: 6) {
            selectionControls
            playButton(size: 44)
        }
        .foregroundStyle(Color.lfbAccentText)
        .tint(track.color)
        .padding(EdgeInsets(top: 10, leading: 12, bottom: 4, trailing: 12))
    }

    private func playButton(size: CGFloat) -> some View {
        Button(action: model.togglePlay) {
            Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.lfbWindow)
                .frame(width: size, height: size)
                .background(Color.lfbText, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(model.isPlaying ? "Pause" : "Play")
    }

    private var loudnessBinding: Binding<Double> {
        Binding(
            get: { Double(selected.map(\.velocity).reduce(0, +)) / Double(max(selected.count, 1)) },
            set: { v in
                var updated = notes
                for i in updated.indices where model.selectedNoteIDs.contains(updated[i].id) { updated[i].velocity = Int(v.rounded()) }
                model.updateEditingNotes(updated, for: track)
            })
    }

    // MARK: Roll

    private var roll: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Color.lfbWindow.frame(width: keyW)
                ruler
            }
            .frame(height: 20)
            .overlay(alignment: .bottom) { Divider() }
            HStack(spacing: 0) {
                keys
                grid
            }
            HStack(spacing: 0) {
                Text("Loud").font(.system(size: 9)).foregroundStyle(Color.lfbTextTertiary)
                    .frame(width: keyW)
                loudnessLane
            }
            .frame(height: isLandscape ? 44 : 64)
            .overlay(alignment: .top) { Divider() }
        }
        .background(Color.lfbSurface)
        .overlay(alignment: .top) { Divider() }
    }

    private func x(_ t: Double) -> CGFloat { CGFloat(t - startTime) * pps }
    private func time(_ x: CGFloat) -> Double { startTime + Double(x / pps) }
    private func y(_ pitch: Int) -> CGFloat { CGFloat(topPitch - Double(pitch)) * rowH }
    private func pitch(_ y: CGFloat) -> Int {
        min(max(Int((topPitch - Double(y / rowH)).rounded(.up)), Self.lowPitch), Self.highPitch)
    }
    private func snapped(_ t: Double) -> Double { snap > 0 ? max((t / snap).rounded() * snap, 0) : max(t, 0) }

    private var tickStep: Double { [0.5, 1, 2, 4, 5, 10, 15, 30].first { CGFloat($0) * pps >= 56 } ?? 30 }

    private var ruler: some View {
        Canvas { ctx, size in
            var t = (startTime / tickStep).rounded(.down) * tickStep
            while x(t) < size.width {
                // Labels are whole seconds (m:ss); half-second ticks keep their grid line only.
                if t >= 0 && t <= duration && t.truncatingRemainder(dividingBy: 1) == 0 {
                    ctx.draw(Text(formatTimecode(t)).font(.system(size: 11)).foregroundStyle(Color.lfbTextTertiary),
                             at: CGPoint(x: x(t) + 3, y: size.height / 2), anchor: .leading)
                }
                t += tickStep
            }
            drawLoopAndPlayhead(&ctx, size: size)
        }
        .contentShape(Rectangle())
        .gesture(SpatialTapGesture().onEnded { model.seek(to: min(max(time($0.location.x), 0), duration)) })
        .accessibilityHidden(true)
    }

    private var keys: some View {
        Canvas { ctx, size in
            for p in Self.lowPitch...Self.highPitch {
                let top = y(p)
                guard top > -rowH, top < size.height else { continue }
                let r = CGRect(x: 0, y: top, width: size.width, height: rowH)
                if Self.blackKeys.contains(p % 12) { ctx.fill(Path(r), with: .color(Color.lfbHairline)) }
                ctx.fill(Path(CGRect(x: 0, y: top + rowH - 0.5, width: size.width, height: 0.5)), with: .color(Color.lfbHairline))
                if p % 12 == 0 {
                    ctx.draw(Text("C\(p / 12 - 1)").font(.system(size: 10)).foregroundStyle(Color.lfbTextTertiary),
                             at: CGPoint(x: size.width - 4, y: top + rowH / 2), anchor: .trailing)
                }
            }
        }
        .frame(width: keyW)
        .background(Color.lfbWindow)
        .overlay(alignment: .trailing) { Divider() }
        .clipped()
        .accessibilityHidden(true)
    }

    private var grid: some View {
        Canvas { ctx, size in
            for p in Self.lowPitch...Self.highPitch {
                let top = y(p)
                guard top > -rowH, top < size.height else { continue }
                if Self.blackKeys.contains(p % 12) {
                    ctx.fill(Path(CGRect(x: 0, y: top, width: size.width, height: rowH)), with: .color(Color.lfbHairline.opacity(0.5)))
                }
                ctx.fill(Path(CGRect(x: 0, y: top + rowH - 0.5, width: size.width, height: 0.5)), with: .color(Color.lfbHairline))
            }
            var t = (startTime / tickStep).rounded(.down) * tickStep
            while x(t) < size.width {
                ctx.fill(Path(CGRect(x: x(t), y: 0, width: 1, height: size.height)), with: .color(Color.lfbHairline))
                t += tickStep
            }
            if showOtherParts, let snapshot = model.displayedSnapshot {
                for other in snapshot.tracks where other.id != track {
                    for n in other.notes {
                        let r = noteRect(n)
                        guard r.maxX >= 0, r.minX <= size.width, r.maxY >= 0, r.minY <= size.height else { continue }
                        let ghost = CGRect(x: r.minX, y: r.minY + rowH / 3, width: r.width, height: rowH / 3)
                        ctx.fill(Path(roundedRect: ghost, cornerRadius: 2), with: .color(other.id.color.opacity(0.3)))
                    }
                }
            }
            for n in notes {
                let r = noteRect(n).insetBy(dx: 0, dy: 1)
                guard r.maxX >= 0, r.minX <= size.width, r.maxY >= 0, r.minY <= size.height else { continue }
                let path = Path(roundedRect: r, cornerRadius: min(5, r.height / 2))
                ctx.fill(path, with: .color(track.color))
                if model.selectedNoteIDs.contains(n.id) {
                    ctx.stroke(Path(roundedRect: r.insetBy(dx: -2, dy: -2), cornerRadius: 6), with: .color(Color.lfbSurface), lineWidth: 2)
                    ctx.stroke(Path(roundedRect: r.insetBy(dx: -4, dy: -4), cornerRadius: 7), with: .color(Color.lfbText), lineWidth: 2)
                }
            }
            // Resize handles on the selection (one per note, on its right edge)
            if selected.count <= 8 {
                for n in selected {
                    let r = noteRect(n)
                    let h = CGRect(x: r.maxX - 6, y: r.midY - 13, width: 12, height: 26)
                    ctx.fill(Path(roundedRect: h.insetBy(dx: -2, dy: -2), cornerRadius: 8), with: .color(Color.lfbSurface))
                    ctx.fill(Path(roundedRect: h, cornerRadius: 6), with: .color(Color.lfbText))
                }
            }
            drawLoopAndPlayhead(&ctx, size: size)
            if let m = marquee {
                ctx.fill(Path(m), with: .color(Color.lfbAccent.opacity(0.12)))
                ctx.stroke(Path(m), with: .color(Color.lfbAccent), lineWidth: 1)
            }
        }
        .overlay {
            NoteGlowLayer(notes: notes, color: track.color, isDrums: track == .drums) { n, size in
                let r = noteRect(n).insetBy(dx: 0, dy: 1)
                return r.maxX >= 0 && r.minX <= size.width && r.maxY >= 0 && r.minY <= size.height ? r : nil
            }
        }
        .clipped()
        .contentShape(Rectangle())
        .onGeometryChange(for: CGSize.self, of: { $0.size }) { size in
            gridSize = size
            placeOnce()
            clampView()
        }
        .gesture(gridTouch)
        .simultaneousGesture(pinch)
        .accessibilityElement()
        .accessibilityLabel("\(track.title) notes, \(notes.count) notes")
        .accessibilityValue(selected.isEmpty ? "None selected" : "\(selected.count) selected")
        .accessibilityHint("Swipe up or down to move the selected notes by a semitone")
        .accessibilityAdjustableAction { direction in
            transposeSelection(by: direction == .increment ? 1 : -1)
        }
        .accessibilityAction(named: "Select all") { model.selectedNoteIDs = Set(notes.map(\.id)) }
        .accessibilityAction(named: "Delete selected") { deleteSelection() }
        .accessibilityIdentifier("roll-grid")
    }

    private func drawLoopAndPlayhead(_ ctx: inout GraphicsContext, size: CGSize) {
        if model.isLoopEnabled, let range = model.loopRange {
            let r = CGRect(x: x(range.lowerBound), y: 0, width: max(x(range.upperBound) - x(range.lowerBound), 1), height: size.height)
            ctx.fill(Path(r), with: .color(Color.lfbAccentWash))
        }
        let px = x(min(model.position, duration))
        if px >= -2, px <= size.width + 2 {
            ctx.fill(Path(CGRect(x: px - 1, y: 0, width: 2, height: size.height)), with: .color(Color.lfbText))
        }
    }

    private func noteRect(_ n: Note) -> CGRect {
        CGRect(x: x(n.start), y: y(n.pitch), width: max(CGFloat(n.duration) * pps, 6), height: rowH)
    }

    /// Selected-note handle first (it pokes out past the note), then the notes, topmost first.
    private func hit(_ p: CGPoint) -> (note: Note, onHandle: Bool)? {
        for n in selected.reversed() {
            let r = noteRect(n)
            // The handle is the part from just inside the right edge outwards, so a short note's
            // body still moves it.
            if p.x >= r.maxX - min(6, r.width / 3), p.x <= r.maxX + 16, abs(p.y - r.midY) <= max(rowH, 18) {
                return (n, true)
            }
        }
        for n in notes.reversed() where noteRect(n).insetBy(dx: -4, dy: -3).contains(p) { return (n, false) }
        return nil
    }

    // MARK: Gestures

    private func tap(at point: CGPoint) {
        if let h = hit(point) {
            model.selectedNoteIDs = [h.note.id]
            audition(h.note.pitch, h.note.velocity)
        } else if tool == .draw {
            addNote(at: point)
        } else {
            model.selectedNoteIDs = []
        }
    }

    /// One gesture for every one-finger touch, classified by how it moves: under 6 pt is a tap;
    /// held still for 0.35 s on empty space and then dragged is a marquee; otherwise a drag that
    /// moves or resizes the selection, or scrolls. (Separate tap, long-press and drag gestures
    /// fought over the same touches.)
    private var gridTouch: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { g in
                guard pinchBase == nil else { return }
                if touchStart == nil { touchStart = Date() }
                if dragKind == nil {
                    guard hypot(g.translation.width, g.translation.height) > 6 else { return }
                    longPressArmed = Date().timeIntervalSince(touchStart ?? Date()) > 0.35
                    beginDrag(at: g.startLocation)
                }
                switch dragKind {
                case .move: applyMove(g.translation)
                case .resize: applyResize(g.translation.width)
                case .pan:
                    startTime = panOrigin.time - Double(g.translation.width / pps)
                    topPitch = panOrigin.pitch + Double(g.translation.height / rowH)
                    clampView()
                case .marquee:
                    let a = g.startLocation, b = g.location
                    let rect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
                    marquee = rect
                    model.selectedNoteIDs = Set(notes.filter { noteRect($0).intersects(rect) }.map(\.id))
                case nil: break
                }
            }
            .onEnded { g in
                if dragKind == nil && pinchBase == nil && hypot(g.translation.width, g.translation.height) <= 6 {
                    tap(at: g.startLocation)
                }
                dragKind = nil; dragOriginals = [:]; dragAnchor = nil; marquee = nil; longPressArmed = false
                lastAuditioned = nil; touchStart = nil
                model.endNoteGesture()
            }
    }

    private var pinch: some Gesture {
        MagnifyGesture()
            .onChanged { g in
                if pinchBase == nil {
                    pinchBase = visibleSeconds
                    pinchAnchor = time(g.startLocation.x)
                    if dragKind == .pan { dragKind = nil }
                }
                let anchorX = g.startLocation.x
                let maxWindow = max(duration, 3)
                visibleSeconds = min(max((pinchBase ?? visibleSeconds) / Double(g.magnification), 2), maxWindow)
                startTime = pinchAnchor - Double(anchorX / pps)
                clampView()
            }
            .onEnded { _ in pinchBase = nil }
    }

    private func beginDrag(at point: CGPoint) {
        if longPressArmed, hit(point) == nil { dragKind = .marquee; return }
        if let h = hit(point), model.selectedNoteIDs.contains(h.note.id) {
            model.beginNoteGesture()   // the whole move / resize is one undo step
            dragOriginals = Dictionary(uniqueKeysWithValues: selected.map { ($0.id, $0) })
            dragAnchor = h.note.id
            dragKind = h.onHandle ? .resize : .move
            lastAuditioned = h.note.pitch
        } else {
            panOrigin = (startTime, topPitch)
            dragKind = .pan
        }
    }

    private func applyMove(_ translation: CGSize) {
        guard let id = dragAnchor, let anchor = dragOriginals[id] else { return }
        let dt = snapped(anchor.start + Double(translation.width / pps)) - anchor.start
        let dp = -Int((translation.height / rowH).rounded())
        var updated = notes
        for i in updated.indices {
            guard let o = dragOriginals[updated[i].id] else { continue }
            updated[i].start = min(max(o.start + dt, 0), max(duration - 0.05, 0))
            updated[i].pitch = min(max(o.pitch + dp, Self.lowPitch), Self.highPitch)
        }
        model.updateEditingNotes(updated, for: track)
        if let moved = updated.first(where: { $0.id == id }), moved.pitch != lastAuditioned {
            lastAuditioned = moved.pitch
            audition(moved.pitch, moved.velocity)
        }
    }

    private func applyResize(_ dx: CGFloat) {
        var updated = notes
        for i in updated.indices {
            guard let o = dragOriginals[updated[i].id] else { continue }
            let end = snapped(o.start + o.duration + Double(dx / pps))
            updated[i].duration = max(end - o.start, max(snap, 0.05))
        }
        model.updateEditingNotes(updated, for: track)
    }

    // MARK: Loudness lane

    private var loudnessLane: some View {
        Canvas { ctx, size in
            for n in notes {
                let sx = x(n.start)
                guard sx >= -4, sx <= size.width else { continue }
                let h = CGFloat(n.velocity) / 127 * (size.height - 8)
                let isSel = model.selectedNoteIDs.contains(n.id)
                let color = isSel ? track.color : track.color.opacity(0.45)
                ctx.fill(Path(roundedRect: CGRect(x: sx, y: size.height - h, width: 4, height: h), cornerRadius: 2), with: .color(color))
                if isSel {
                    ctx.fill(Path(ellipseIn: CGRect(x: sx - 2, y: size.height - h - 4, width: 8, height: 8)), with: .color(Color.lfbText))
                }
            }
        }
        .background(Color.lfbSurface)
        .clipped()
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { g in
                    if stemID == nil {
                        let target = notes.min { abs(x($0.start) - g.startLocation.x) < abs(x($1.start) - g.startLocation.x) }
                        guard let target, abs(x(target.start) + 2 - g.startLocation.x) <= 16 else { return }
                        stemID = target.id
                        model.beginNoteGesture()
                        if !model.selectedNoteIDs.contains(target.id) { model.selectedNoteIDs = [target.id] }
                    }
                    guard let id = stemID else { return }
                    let h = isLandscape ? 44.0 : 64.0
                    let v = min(max(Int((1 - Double(g.location.y) / (h - 4)) * 127), 1), 127)
                    var updated = notes
                    if let i = updated.firstIndex(where: { $0.id == id }) {
                        updated[i].velocity = v
                        model.updateEditingNotes(updated, for: track)
                    }
                }
                .onEnded { _ in
                    if let id = stemID, let n = notes.first(where: { $0.id == id }) { audition(n.pitch, n.velocity) }
                    stemID = nil
                    model.endNoteGesture()
                })
        .accessibilityLabel("Loudness")
        .accessibilityHint("Drag a stem up or down to change how hard that note is played")
    }

    // MARK: Edits

    private func addNote(at point: CGPoint) {
        let start = min(snapped(time(point.x)), max(duration - 0.05, 0))
        let note = Note(pitch: pitch(point.y), start: start, duration: max(snap, 0.25), velocity: 90)
        model.updateEditingNotes(NoteEditing.sorted(notes + [note]), for: track)
        model.selectedNoteIDs = [note.id]
        audition(note.pitch)
    }

    private func deleteSelection() {
        guard !selected.isEmpty else { return }
        model.updateEditingNotes(notes.filter { !model.selectedNoteIDs.contains($0.id) }, for: track)
        model.selectedNoteIDs = []
    }

    private func duplicateSelection() {
        let chosen = selected
        guard let first = chosen.map(\.start).min(), let last = chosen.map({ $0.start + $0.duration }).max() else { return }
        let shift = max(last - first, snap > 0 ? snap : 0.25)
        let copies: [Note] = chosen.compactMap { n in
            var c = n; c.id = UUID(); c.start += shift
            return c.start < duration ? c : nil
        }
        guard !copies.isEmpty else { return }
        model.updateEditingNotes(NoteEditing.sorted(notes + copies), for: track)
        model.selectedNoteIDs = Set(copies.map(\.id))
    }

    private func transposeSelection(by semitones: Int) {
        guard !selected.isEmpty else { return }
        var updated = notes
        for i in updated.indices where model.selectedNoteIDs.contains(updated[i].id) {
            updated[i].pitch = min(max(updated[i].pitch + semitones, Self.lowPitch), Self.highPitch)
        }
        model.updateEditingNotes(updated, for: track)
        if let n = updated.first(where: { model.selectedNoteIDs.contains($0.id) }) { audition(n.pitch, n.velocity) }
    }

    private func audition(_ pitch: Int, _ velocity: Int = 90) {
        model.previewNote(pitch: pitch, velocity: velocity, track: track)
    }

    // MARK: View placement

    private func clampView() {
        visibleSeconds = min(max(visibleSeconds, 2), max(duration, 2))
        startTime = min(max(startTime, 0), max(duration - visibleSeconds, 0))
        let rows = visibleRows
        topPitch = min(max(topPitch, Double(Self.lowPitch) + rows - 1), Double(Self.highPitch))
    }

    /// Opens on the loop (or the playhead) and centred on the track's own notes.
    private func placeOnce() {
        guard !didPlace, gridSize.height > 60 else { return }
        didPlace = true
        visibleSeconds = min(isLandscape ? 24 : 12, duration)
        startTime = model.loopRange?.lowerBound ?? max(model.position - 2, 0)
        let pitches = notes.map(\.pitch).sorted()
        let middle = pitches.isEmpty ? (track == .bass ? 40 : track == .drums ? 45 : 64) : pitches[pitches.count / 2]
        topPitch = Double(middle) + visibleRows / 2
        clampView()
    }

    private func followPlayhead(_ p: Double) {
        guard model.isPlaying, dragKind == nil, pinchBase == nil else { return }
        if p < startTime || p > startTime + visibleSeconds * 0.92 {
            startTime = max(p - visibleSeconds * 0.08, 0)
            clampView()
        }
    }
}
#endif
