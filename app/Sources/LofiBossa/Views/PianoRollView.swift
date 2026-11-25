import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Note editor for one track, opened as a split pane under the (now compact) track rows.
///
/// - **Zoom and scroll in time.** `zoom` 1 fits the whole song to the width (as before);
///   zooming in makes the roll scroll sideways. The grid is a ScrollView holding only an empty,
///   correctly sized surface that takes the gestures; everything visible is drawn by Canvases
///   the size of the window onto it, using the scroll offset, so a long zoomed song never makes
///   a huge drawing surface. The key column, ruler and loudness lane follow the same offset.
/// - **Own ruler** with click to seek, drag to loop, playhead and loop range.
/// - **Keyboard** (when the roll has focus): V select, P draw, ⌘A all, ⌘C/⌘X/⌘V/⌘D, ⌫, ←/→ nudge
///   by the snap, ↑/↓ semitone, ⇧↑/⇧↓ octave, Esc deselect, ⌘+ ⌘− ⌘0 zoom.
/// - **Loudness stems** can be dragged. **Notes are auditioned** as they are clicked, drawn
///   or dragged to another pitch.
struct PianoRollView: View {
    @Bindable var model: ProjectViewModel
    let track: TrackID

    enum Tool { case select, draw }

    @State private var tool: Tool = .select
    /// "s:<seconds>" or "b:<beats>" (beats only when the song has a tempo); "s:0" = off.
    @State private var snapChoice = "s:0.25"
    @State private var showOtherParts = true
    @State private var followPlayhead = true
    @State private var zoom: CGFloat = 1
    @State private var scroll: CGPoint = .zero
    @State private var viewport: CGSize = CGSize(width: 800, height: 400)
    @State private var didPlaceView = false
    @FocusState private var focused: Bool
    @State private var pressHandled = false

    // dragging notes
    @State private var dragOriginals: [Note.ID: Note] = [:]
    @State private var dragMode: DragMode?
    @State private var dragAnchorID: Note.ID?
    @State private var lastAuditionPitch: Int?
    @State private var marqueeStart: CGPoint?
    @State private var marqueeRect: CGRect?
    // ruler / loudness
    @State private var rulerDragStart: Double?
    @State private var stemID: Note.ID?
    // copy / paste inside the roll
    @State private var noteClipboard: [Note] = []
    // touch (iOS)
    @State private var heldModifiers: EventModifiers = []
    @State private var touchMode: TouchMode?
    @State private var touchStart: CGPoint = .zero          // on the surface
    @State private var touchAnchor: CGPoint = .zero         // where the pan began, in the view
    @State private var scrollAtTouchStart: CGPoint = .zero
    @State private var zoomAtPinchStart: CGFloat = 1
    @AppStorage("lfb.pencilUsed") private var pencilUsed = false

    private enum TouchMode { case scroll, notes, marquee, pinch }

    private enum DragMode { case move, resize }

    private static let snapOptions: [Double] = [0, 0.1, 0.25, 0.5, 1]
    private static let beatSnapOptions: [(beats: Double, label: String)] =
        [(0.25, "1/16"), (0.5, "1/8"), (1, "Beat"), (4, "Bar")]
    private var grid: BeatGrid? { model.displayedSnapshot?.beatGrid }
    /// Seconds between snap points (0 = off), and whether they count from the song's first beat.
    private var snapStep: Double {
        let value = Double(snapChoice.dropFirst(2)) ?? 0
        if snapChoice.hasPrefix("b:") { return grid.map { $0.beat * value } ?? 0.25 }
        return value
    }
    private var snapsToBeat: Bool { snapChoice.hasPrefix("b:") && grid != nil }
    // Spelled out rather than formatted from the Double, so the decimal point doesn't turn
    // into a comma under locales that format numbers that way.
    private static let snapLabels: [Double: String] = [0: "Off", 0.1: "0.1s", 0.25: "0.25s", 0.5: "0.5s", 1: "1s"]
    private static let lowPitch = 21, highPitch = 108       // A0...C8, the range of a piano
    private static let rowHeight: CGFloat = 12
    private static let keyColumnWidth: CGFloat = 56
    private static let loudnessHeight: CGFloat = 40
    private static let maxPixelsPerSecond: CGFloat = 320
    private static let blackKeys: Set<Int> = [1, 3, 6, 8, 10]

    private var notes: [Note] { model.displayedSnapshot?.track(track).notes ?? [] }
    private var duration: Double { max(model.duration, 1) }
    /// The other instruments, each kept apart so it can be drawn in its own colour.
    private var otherTracks: [(id: TrackID, notes: [Note])] {
        guard showOtherParts, let snapshot = model.displayedSnapshot else { return [] }
        return snapshot.tracks.filter { $0.id != track }.map { ($0.id, $0.notes) }
    }

    /// Zoom as a 0...1 slider position on a log scale (zoom 1 = whole song).
    private var zoomSliderBinding: Binding<Double> {
        Binding(
            get: { maxZoom > 1.001 ? log(Double(zoom)) / log(Double(maxZoom)) : 0 },
            set: { setZoom(CGFloat(exp($0 * log(Double(maxZoom))))) })
    }

    // MARK: Geometry

    private var viewW: CGFloat { max(viewport.width - Self.keyColumnWidth, 1) }
    private var viewH: CGFloat {
        max(viewport.height - LFBSize.rulerHeight - Self.loudnessHeight - 2, 1)
    }
    private var fitPPS: CGFloat { viewW / CGFloat(duration) }
    private var pps: CGFloat { fitPPS * zoom }
    private var maxZoom: CGFloat { max(Self.maxPixelsPerSecond / fitPPS, 1) }
    private var contentWidth: CGFloat { max(CGFloat(duration) * pps, viewW) }
    private var contentHeight: CGFloat { CGFloat(Self.highPitch - Self.lowPitch + 1) * Self.rowHeight }

    private func timeToX(_ t: Double) -> CGFloat { CGFloat(t) * pps }
    private func xToTime(_ x: CGFloat) -> Double { Double(x / pps) }
    private func pitchToY(_ pitch: Int) -> CGFloat { CGFloat(Self.highPitch - pitch) * Self.rowHeight }
    private func yToPitch(_ y: CGFloat) -> Int {
        min(max(Self.highPitch - Int(y / Self.rowHeight), Self.lowPitch), Self.highPitch)
    }
    private func snapTime(_ t: Double) -> Double {
        guard snapStep > 0 else { return max(t, 0) }
        if snapsToBeat, let grid { return max(grid.snap(t, step: snapStep), 0) }
        return max((t / snapStep).rounded() * snapStep, 0)
    }
    private var effectiveSnap: Double { snapStep == 0 ? 0.05 : snapStep }

    // MARK: Body

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            GeometryReader { _ in
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        Color.lfbWell.frame(width: Self.keyColumnWidth)
                        rulerView
                    }
                    .frame(height: LFBSize.rulerHeight)
                    Divider()
                    HStack(spacing: 0) {
                        keysView
                        rollView
                    }
                    Divider()
                    HStack(spacing: 0) {
                        Color.lfbWell.frame(width: Self.keyColumnWidth)
                            .overlay { Text("Loudness").font(.system(size: 9)).foregroundStyle(.secondary) }
                        loudnessLane
                    }
                    .frame(height: Self.loudnessHeight)
                }
            }
            .onGeometryChange(for: CGSize.self, of: { $0.size }) { size in
                viewport = size.width > 0 ? CGSize(width: size.width, height: size.height) : viewport
                placeViewOnNotesOnce()
            }
        }
        .background(Color.lfbSurface)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(phases: [.down, .repeat], action: handleKey)
        #if os(iOS)
        // Squeeze (Apple Pencil Pro) or double-tap (Apple Pencil 2) toggles Select / Draw.
        .onPencilSqueeze { phase in if case .ended = phase { toggleTool() } }
        .onPencilDoubleTap { _ in toggleTool() }
        #endif
        .onAppear {
            focused = true
            // `--roll-zoom N [seconds]` opens zoomed (and scrolled to a time), for screenshot checks.
            let args = CommandLine.arguments
            if let i = args.firstIndex(of: "--roll-zoom"), args.count > i + 1, let z = Double(args[i + 1]) {
                zoom = CGFloat(z)
                if args.count > i + 2, let at = Double(args[i + 2]) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { scrollTo(x: CGFloat(at) * fitPPS * zoom) }
                }
            }
        }
        .onChange(of: model.position) { _, position in followIfPlaying(position) }
        .onChange(of: model.displayedSnapshot?.lengthSeconds) { clampZoom() }
        .sharesNoteUndo(with: model)
        .onReceive(NotificationCenter.default.publisher(for: .lfbRollZoom)) { note in
            switch note.object as? TimelineZoomCommand {
            case .in: zoomBy(1.5)
            case .out: zoomBy(1 / 1.5)
            case .fit: setZoom(1)
            case nil: break
            }
        }
    }

    // MARK: Header

    /// On iOS the roll can sit in a narrow pane (the iPhone Duo's right page), so the header
    /// scrolls sideways there instead of squeezing its controls. The Mac is unchanged.
    @ViewBuilder private var header: some View {
        #if os(iOS)
        ScrollView(.horizontal, showsIndicators: false) { headerRow }
        #else
        headerRow
        #endif
    }

    private var headerRow: some View {
        HStack(spacing: LFBSpace.md) {
            TrackGlyph(id: track, size: 22)
            Text(track.title).font(.lfbHeadline)

            Picker("Tool", selection: $tool) {
                Image(systemName: "cursorarrow").tag(Tool.select)
                Image(systemName: "pencil.tip").tag(Tool.draw)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            .help("Select (V) or draw (P)")

            Picker("Snap", selection: $snapChoice) {
                if grid != nil {
                    ForEach(Self.beatSnapOptions, id: \.beats) { o in Text(o.label).tag("b:\(o.beats)") }
                    Divider()
                }
                ForEach(Self.snapOptions, id: \.self) { s in
                    Text(Self.snapLabels[s] ?? "\(s)s").tag("s:\(s)")
                }
            }
            .pickerStyle(.menu).fixedSize()
            .onAppear { if grid != nil, snapChoice == "s:0.25" { snapChoice = "b:0.25" } }

            Toggle("Other parts", isOn: $showOtherParts).toggleStyle(.button).controlSize(.small)
                .help("Show the other instruments' notes, each in its own colour, faded")

            HStack(spacing: 2) {
                Button { zoomBy(1 / 1.5) } label: { Image(systemName: "minus.magnifyingglass") }
                    .help("Zoom out (⌘−)").disabled(zoom <= 1.001)
                Button { zoomBy(1.5) } label: { Image(systemName: "plus.magnifyingglass") }
                    .help("Zoom in (⌘+)").disabled(zoom >= maxZoom - 0.001)
                Slider(value: zoomSliderBinding, in: 0...1).frame(width: 90).controlSize(.small)
                    .help("Zoom the timeline")
                    .accessibilityIdentifier("roll-zoom").accessibilityLabel("Zoom")
                Button("Fit") { setZoom(1) }.help("Show the whole song (⌘0)").disabled(zoom <= 1.001).fixedSize()
            }
            .buttonStyle(.borderless)

            Toggle("Follow", isOn: $followPlayhead).toggleStyle(.button).controlSize(.small)
                .help("Scroll along with the playhead while playing")

            #if os(iOS)
            if !pencilUsed {
                Text("Pencil draws · finger moves")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Color.lfbTextSecondary)
                    .padding(.horizontal, 8).frame(height: 24)
                    .background(Color.lfbWell, in: Capsule())
                    .fixedSize()
            }
            #endif

            Spacer()

            if !selectedNotes.isEmpty {
                Text("\(selectedNotes.count) selected").font(.lfbCaption).foregroundStyle(Color.lfbTextSecondary)
                HStack(spacing: 6) {
                    Image(systemName: "speaker.wave.1").font(.caption)
                    Slider(value: loudnessBinding, in: 1...127) { editing in
                        editing ? model.beginNoteGesture() : model.endNoteGesture()
                    }
                    .frame(width: 90)
                }
                Button(role: .destructive, action: deleteSelection) { Image(systemName: "trash") }
                    .buttonStyle(.plain)
            }

            Button("Done") { model.closeEditor() }.buttonStyle(LFBPrimaryButtonStyle()).controlSize(.small)
                .accessibilityIdentifier("roll-done")
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

    // MARK: Ruler

    private var rulerView: some View {
        Canvas { ctx, size in
            let step = labelStep
            var t = (Double(scroll.x / pps) / step).rounded(.down) * step
            while timeToX(t) - scroll.x < size.width {
                let x = timeToX(t) - scroll.x
                if t >= 0, t <= duration {
                    var tick = Path()
                    tick.move(to: CGPoint(x: x, y: size.height - 6))
                    tick.addLine(to: CGPoint(x: x, y: size.height))
                    ctx.stroke(tick, with: .color(.lfbTextTertiary))
                    ctx.draw(Text(formatTimecode(t)).font(.lfbCaption).foregroundStyle(.secondary),
                             at: CGPoint(x: x + 3, y: size.height - 14), anchor: .leading)
                }
                t += step
            }
            drawLoopAndPlayhead(&ctx, size: size)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { g in
                    if rulerDragStart == nil { rulerDragStart = xToTime(g.startLocation.x + scroll.x) }
                    let a = rulerDragStart ?? 0
                    let b = xToTime(g.location.x + scroll.x)
                    model.setLoopRange(max(min(a, b), 0)...min(max(a, b, min(a, b) + 0.5), duration))
                }
                .onEnded { _ in rulerDragStart = nil }
                .exclusively(before: SpatialTapGesture().onEnded { tap in
                    model.seek(to: min(max(xToTime(tap.location.x + scroll.x), 0), duration))
                })
        )
    }

    /// A tick every `step` seconds, at least ~64 points apart.
    private var labelStep: Double {
        let wanted = 64 / Double(pps)
        return [0.25, 0.5, 1, 2, 5, 10, 15, 30, 60].first { $0 >= wanted } ?? 60
    }

    private func drawLoopAndPlayhead(_ ctx: inout GraphicsContext, size: CGSize) {
        if model.isLoopEnabled, let range = model.loopRange {
            let x0 = timeToX(range.lowerBound) - scroll.x, x1 = timeToX(range.upperBound) - scroll.x
            ctx.fill(Path(CGRect(x: x0, y: 0, width: max(x1 - x0, 1), height: size.height)),
                     with: .color(Color.lfbAccentWash))
        }
        let px = timeToX(min(model.position, duration)) - scroll.x
        if px >= -1, px <= size.width + 1 {
            ctx.fill(Path(CGRect(x: px - 0.75, y: 0, width: 1.5, height: size.height)),
                     with: .color(Color.lfbText.opacity(0.75)))
        }
    }

    // MARK: Keys

    private var keysView: some View {
        Canvas { ctx, size in
            for pitch in Self.lowPitch...Self.highPitch {
                let y = pitchToY(pitch) - scroll.y
                guard y > -Self.rowHeight, y < size.height else { continue }
                if Self.blackKeys.contains(pitch % 12) {
                    ctx.fill(Path(CGRect(x: 0, y: y, width: size.width, height: Self.rowHeight)),
                             with: .color(Color.black.opacity(0.08)))
                }
                if pitch % 12 == 0 {
                    ctx.draw(Text("C\(pitch / 12 - 1)").font(.system(size: 9)).foregroundStyle(.secondary),
                             at: CGPoint(x: size.width - 4, y: y + Self.rowHeight / 2), anchor: .trailing)
                }
            }
        }
        .frame(width: Self.keyColumnWidth)
        .background(Color.lfbWell)
        .clipped()
    }

    // MARK: Roll

    private var rollView: some View {
        ZStack(alignment: .topLeading) {
            Canvas { ctx, size in drawRoll(&ctx, size: size) }
                .allowsHitTesting(false)
            NoteGlowLayer(notes: notes, color: track.color, isDrums: track == .drums) { n, size in
                let r = CGRect(x: timeToX(n.start) - scroll.x, y: pitchToY(n.pitch) - scroll.y + 1,
                               width: max(CGFloat(n.duration) * pps, 3), height: Self.rowHeight - 2)
                return r.maxX >= 0 && r.minX <= size.width && r.maxY >= 0 && r.minY <= size.height ? r : nil
            }
            NoteAccessibilityLayer(
                notes: notes, grid: grid, songLength: duration, lengthStep: effectiveSnap,
                frame: { n in noteRect(n).offsetBy(dx: -scroll.x, dy: -scroll.y) },
                select: { model.selectedNoteIDs = [$0] },
                commit: { model.updateEditingNotes($0, for: track) },
                audition: { audition($0.pitch, $0.velocity) })
            // Takes the clicks and drags. Points are in the window's coordinates; the surface
            // they mean is that plus the scroll offset.
            #if os(macOS)
            Color.clear
                .contentShape(Rectangle())
                .gesture(canvasDrag)
                .simultaneousGesture(pressSelect)
                .onTapGesture(count: 2) { addNote(at: onSurface($0)) }
                .onTapGesture(count: 1) { tapCanvas(at: onSurface($0)) }
            #else
            touchSurface
            #endif
            if let rect = marqueeRect {
                Rectangle().fill(Color.lfbAccent.opacity(0.12))
                    .overlay(Rectangle().stroke(Color.lfbAccent, lineWidth: 1))
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX - scroll.x, y: rect.minY - scroll.y)
                    .allowsHitTesting(false)
            }
            scrollIndicators.allowsHitTesting(false)
            // Wheel / trackpad scrolling and pinch: SwiftUI (macOS 14) has no hook for them, so a
            // small AppKit view answers only those events and lets everything else through.
            // Touch, Pencil and pinch on iOS: `touchSurface` (PianoRollView+Touch below).
            #if os(macOS)
            ScrollCatcher(
                onScroll: { dx, dy, precise in
                    let k: CGFloat = precise ? 1 : 8
                    scrollBy(dx: -dx * k, dy: -dy * k)
                },
                onMagnify: { setZoom(zoom * (1 + $0)) })
            #endif
        }
        .clipped()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityChartDescriptor(NoteContourDescriptor(title: track.title, notes: notes, duration: duration))
    }

    private func onSurface(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x + scroll.x, y: p.y + scroll.y) }

    /// Thin bars showing where the window is on the surface.
    private var scrollIndicators: some View {
        GeometryReader { geo in
            if contentWidth > viewW + 1 {
                Capsule().fill(Color.lfbTextTertiary.opacity(0.55))
                    .frame(width: max(geo.size.width * viewW / contentWidth, 24), height: 4)
                    .offset(x: (geo.size.width - max(geo.size.width * viewW / contentWidth, 24)) * (scroll.x / max(contentWidth - viewW, 1)),
                            y: geo.size.height - 7)
            }
            if contentHeight > viewH + 1 {
                let h = max(geo.size.height * viewH / contentHeight, 24)
                Capsule().fill(Color.lfbTextTertiary.opacity(0.55))
                    .frame(width: 4, height: h)
                    .offset(x: geo.size.width - 7,
                            y: (geo.size.height - h) * (scroll.y / max(contentHeight - viewH, 1)))
            }
        }
    }

    private func drawRoll(_ ctx: inout GraphicsContext, size: CGSize) {
        // alternate rows for black keys
        for pitch in Self.lowPitch...Self.highPitch where Self.blackKeys.contains(pitch % 12) {
            let y = pitchToY(pitch) - scroll.y
            guard y > -Self.rowHeight, y < size.height else { continue }
            ctx.fill(Path(CGRect(x: 0, y: y, width: size.width, height: Self.rowHeight)), with: .color(.black.opacity(0.03)))
        }
        // vertical time grid
        let step = labelStep
        var t = (Double(scroll.x / pps) / step).rounded(.down) * step
        while timeToX(t) - scroll.x < size.width {
            let x = timeToX(t) - scroll.x
            ctx.fill(Path(CGRect(x: x, y: 0, width: 1, height: size.height)), with: .color(Color.lfbTextTertiary.opacity(0.12)))
            t += step
        }
        for other in otherTracks {
            drawNotes(other.notes, in: &ctx, size: size, color: other.id.color.opacity(0.35), selected: [])
        }
        drawNotes(notes, in: &ctx, size: size, color: track.color, selected: model.selectedNoteIDs)
        drawLoopAndPlayhead(&ctx, size: size)
    }

    private func drawNotes(_ list: [Note], in ctx: inout GraphicsContext, size: CGSize, color: Color, selected: Set<Note.ID>) {
        for n in list {
            let x = timeToX(n.start) - scroll.x
            let w = max(CGFloat(n.duration) * pps, 3)
            guard x + w >= 0, x <= size.width else { continue }
            let y = pitchToY(n.pitch) - scroll.y
            guard y > -Self.rowHeight, y < size.height else { continue }
            let rect = CGRect(x: x, y: y + 1, width: w, height: Self.rowHeight - 2)
            let isSelected = selected.contains(n.id)
            ctx.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(isSelected ? color : color.opacity(0.85)))
            if isSelected {
                ctx.stroke(Path(roundedRect: rect, cornerRadius: 2), with: .color(.lfbText), lineWidth: 1.5)
            }
        }
    }

    private func noteRect(_ n: Note) -> CGRect {
        CGRect(x: timeToX(n.start), y: pitchToY(n.pitch), width: max(CGFloat(n.duration) * pps, 3), height: Self.rowHeight)
    }

    private func hitTest(_ point: CGPoint) -> (note: Note, nearRightEdge: Bool)? {
        for n in notes.reversed() {
            let r = noteRect(n)
            if r.insetBy(dx: -1, dy: 0).contains(point) {
                return (n, point.x > r.maxX - min(6, r.width / 2))
            }
        }
        return nil
    }

    // MARK: Gestures (points are in the scrolled surface's coordinates)

    #if os(macOS)
    private var shiftHeld: Bool { NSEvent.modifierFlags.contains(.shift) }
    private var optionHeld: Bool { NSEvent.modifierFlags.contains(.option) }
    #else
    // Hardware-keyboard modifiers (iPad), read from each touch's recognizer (RollRecognizer).
    private var shiftHeld: Bool { heldModifiers.contains(.shift) }
    private var optionHeld: Bool { heldModifiers.contains(.option) }
    #endif

    private func audition(_ pitch: Int, _ velocity: Int = 90) {
        model.previewNote(pitch: pitch, velocity: velocity, track: track)
    }

    private func tapCanvas(at point: CGPoint) {
        focused = true
        if let hit = hitTest(point) {
            if shiftHeld {
                if model.selectedNoteIDs.contains(hit.note.id) { model.selectedNoteIDs.remove(hit.note.id) }
                else { model.selectedNoteIDs.insert(hit.note.id) }
            } else {
                model.selectedNoteIDs = [hit.note.id]
            }
            audition(hit.note.pitch, hit.note.velocity)
        } else if tool == .draw {
            addNote(at: point)
        } else if !shiftHeld {
            model.selectedNoteIDs = []
        }
    }

    private func addNote(at point: CGPoint) {
        focused = true
        let start = snapTime(xToTime(point.x))
        let pitch = yToPitch(point.y)
        let note = Note(pitch: pitch, start: min(start, max(duration - 0.05, 0)), duration: max(snapStep, 0.25), velocity: 90)
        model.updateEditingNotes(notes + [note], for: track)
        model.selectedNoteIDs = [note.id]
        audition(pitch)
    }

    /// Pressing on a note selects it right away, so a note that is held down (before any drag, or
    /// without moving) is already the selection when Delete is pressed.
    private var pressSelect: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { g in
                guard !pressHandled else { return }
                pressHandled = true
                focused = true
                if !shiftHeld, let hit = hitTest(onSurface(g.startLocation)), !model.selectedNoteIDs.contains(hit.note.id) {
                    model.selectedNoteIDs = [hit.note.id]
                }
            }
            .onEnded { _ in pressHandled = false }
    }

    private var canvasDrag: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { g in
                focused = true
                if dragMode == nil && marqueeStart == nil {
                    if let hit = hitTest(onSurface(g.startLocation)) {
                        beginNoteDrag(on: hit.note, resize: hit.nearRightEdge)
                    } else {
                        marqueeStart = onSurface(g.startLocation)
                    }
                }
                if let start = marqueeStart {
                    let here = onSurface(g.location)
                    let rect = CGRect(x: min(start.x, here.x), y: min(start.y, here.y),
                                      width: abs(here.x - start.x), height: abs(here.y - start.y))
                    marqueeRect = rect
                    model.selectedNoteIDs = Set(notes.filter { noteRect($0).intersects(rect) }.map(\.id))
                } else if let mode = dragMode {
                    applyDrag(mode, translation: g.translation)
                }
            }
            .onEnded { _ in
                dragOriginals = [:]; dragMode = nil; dragAnchorID = nil; lastAuditionPitch = nil
                marqueeStart = nil; marqueeRect = nil
                model.endNoteGesture()
            }
    }

    /// The whole drag (and an ⌥-drag's copies) is one undo step, closed when the drag ends.
    private func beginNoteDrag(on hit: Note, resize: Bool) {
        model.beginNoteGesture()
        if !model.selectedNoteIDs.contains(hit.id) { model.selectedNoteIDs = [hit.id] }
        var anchor = hit.id
        if optionHeld && !resize {
            // ⌥-drag: drag copies, leave the originals where they are
            var updated = notes
            var copies: [Note] = []
            for n in notes where model.selectedNoteIDs.contains(n.id) {
                var c = n; c.id = UUID(); copies.append(c)
                if n.id == hit.id { anchor = c.id }
            }
            updated += copies
            model.updateEditingNotes(updated, for: track)
            model.selectedNoteIDs = Set(copies.map(\.id))
        }
        dragOriginals = Dictionary(uniqueKeysWithValues: notes.filter { model.selectedNoteIDs.contains($0.id) }.map { ($0.id, $0) })
        dragAnchorID = anchor
        dragMode = resize ? .resize : .move
        lastAuditionPitch = dragOriginals[anchor]?.pitch
        if let n = dragOriginals[anchor] { audition(n.pitch, n.velocity) }
    }

    /// Always works from the notes as they were when the drag began, so the total drag distance
    /// is applied once rather than piling up on every update.
    private func applyDrag(_ mode: DragMode, translation: CGSize) {
        var updated = notes
        switch mode {
        case .move:
            guard let anchorID = dragAnchorID, let anchor = dragOriginals[anchorID] else { return }
            let dt = snapTime(anchor.start + xToTime(translation.width)) - anchor.start
            let dPitch = -Int((translation.height / Self.rowHeight).rounded())
            for i in updated.indices {
                guard let original = dragOriginals[updated[i].id] else { continue }
                updated[i].start = min(max(original.start + dt, 0), max(duration - 0.05, 0))
                updated[i].pitch = min(max(original.pitch + dPitch, Self.lowPitch), Self.highPitch)
            }
            if let moved = updated.first(where: { $0.id == anchorID }), moved.pitch != lastAuditionPitch {
                lastAuditionPitch = moved.pitch
                audition(moved.pitch, moved.velocity)
            }
        case .resize:
            guard let anchorID = dragAnchorID, let original = dragOriginals[anchorID] else { return }
            let newDuration = max(snapTime(original.duration + xToTime(translation.width)), 0.05)
            if let i = updated.firstIndex(where: { $0.id == anchorID }) { updated[i].duration = newDuration }
        }
        model.updateEditingNotes(updated, for: track)
    }

    // MARK: Keyboard

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        let mods = press.modifiers
        let command = mods.contains(.command)
        let shift = mods.contains(.shift)
        if command {
            switch press.characters.lowercased() {
            case "a": model.selectedNoteIDs = Set(notes.map(\.id)); return .handled
            case "c": copySelection(); return .handled
            case "x": copySelection(); deleteSelection(); return .handled
            case "v": pasteAtPlayhead(); return .handled
            case "d": duplicateSelection(); return .handled
            case "=", "+": zoomBy(1.5); return .handled
            case "-": zoomBy(1 / 1.5); return .handled
            case "0": setZoom(1); return .handled
            default: return .ignored
            }
        }
        switch press.key {
        case .leftArrow: nudgeSelection(by: -effectiveSnap); return .handled
        case .rightArrow: nudgeSelection(by: effectiveSnap); return .handled
        case .upArrow: transposeSelection(by: shift ? 12 : 1); return .handled
        case .downArrow: transposeSelection(by: shift ? -12 : -1); return .handled
        case .delete, .deleteForward: deleteSelection(); return .handled
        case .escape: model.selectedNoteIDs = []; return .handled
        default: break
        }
        guard mods.isEmpty || mods == .shift else { return .ignored }
        switch press.characters.lowercased() {
        case "v": tool = .select; return .handled
        case "p": tool = .draw; return .handled
        default: return .ignored
        }
    }

    private func nudgeSelection(by dt: Double) {
        guard !model.selectedNoteIDs.isEmpty else { return }
        var updated = notes
        for i in updated.indices where model.selectedNoteIDs.contains(updated[i].id) {
            updated[i].start = min(max(updated[i].start + dt, 0), max(duration - 0.05, 0))
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
        if let first = updated.first(where: { model.selectedNoteIDs.contains($0.id) }) { audition(first.pitch, first.velocity) }
    }

    private func deleteSelection() {
        guard !model.selectedNoteIDs.isEmpty else { return }
        model.updateEditingNotes(notes.filter { !model.selectedNoteIDs.contains($0.id) }, for: track)
        model.selectedNoteIDs = []
        // deleting while a note is held mid-drag: the drag has nothing left to move
        dragOriginals = [:]; dragMode = nil; dragAnchorID = nil; lastAuditionPitch = nil
    }

    private func copySelection() {
        let chosen = selectedNotes
        guard let first = chosen.map(\.start).min() else { return }
        noteClipboard = chosen.map { var n = $0; n.start -= first; return n }
    }

    /// Pastes the copied notes at the playhead (snapped); the pasted notes become the selection.
    private func pasteAtPlayhead() {
        guard !noteClipboard.isEmpty else { return }
        let at = snapTime(model.position)
        let pasted: [Note] = noteClipboard.compactMap { n in
            var c = n; c.id = UUID(); c.start += at
            return c.start < duration ? c : nil
        }
        guard !pasted.isEmpty else { return }
        model.updateEditingNotes(NoteEditing.sorted(notes + pasted), for: track)
        model.selectedNoteIDs = Set(pasted.map(\.id))
    }

    /// A copy of the selection right after it (the same distance as the selection is long).
    private func duplicateSelection() {
        let chosen = selectedNotes
        guard let first = chosen.map(\.start).min(), let last = chosen.map({ $0.start + $0.duration }).max() else { return }
        let shift = max(last - first, effectiveSnap)
        let copies: [Note] = chosen.compactMap { n in
            var c = n; c.id = UUID(); c.start += shift
            return c.start < duration ? c : nil
        }
        guard !copies.isEmpty else { return }
        model.updateEditingNotes(NoteEditing.sorted(notes + copies), for: track)
        model.selectedNoteIDs = Set(copies.map(\.id))
    }

    // MARK: Zoom and scrolling

    private func zoomBy(_ factor: CGFloat) { setZoom(zoom * factor) }

    /// Sets the zoom keeping what is at the middle of the window where it is.
    private func setZoom(_ newZoom: CGFloat) {
        let clamped = min(max(newZoom, 1), maxZoom)
        guard abs(clamped - zoom) > 0.0001 else { return }
        let centerTime = xToTime(scroll.x + viewW / 2)
        zoom = clamped
        let x = clamped <= 1.0001 ? 0 : max(timeToX(centerTime) - viewW / 2, 0)
        scrollTo(x: x, contentWidth: max(CGFloat(duration) * fitPPS * clamped, viewW))
    }

    private func scrollBy(dx: CGFloat, dy: CGFloat) {
        scrollTo(x: scroll.x + dx, y: scroll.y + dy)
    }

    /// Puts this point of the surface at the window's top-left; an axis left out stays. Limited
    /// to the surface (`contentWidth` lets a zoom that has not rendered yet pass its new width).
    private func scrollTo(x: CGFloat? = nil, y: CGFloat? = nil, contentWidth width: CGFloat? = nil) {
        scroll = CGPoint(x: min(max(x ?? scroll.x, 0), max((width ?? contentWidth) - viewW, 0)),
                         y: min(max(y ?? scroll.y, 0), max(contentHeight - viewH, 0)))
    }

    private func clampZoom() { if zoom > maxZoom { zoom = maxZoom } }

    /// While playing, keeps the playhead in view by paging the window along.
    private func followIfPlaying(_ position: Double) {
        guard followPlayhead, model.isPlaying, zoom > 1.001 else { return }
        let x = timeToX(position)
        if x < scroll.x || x > scroll.x + viewW * 0.92 {
            scrollTo(x: max(x - viewW * 0.08, 0))
        }
    }

    /// First time the size is known: scroll vertically so the track's own notes are in view
    /// (a bass line and a piano part sit in very different octaves).
    private func placeViewOnNotesOnce() {
        guard !didPlaceView, viewport.height > 100 else { return }
        didPlaceView = true
        let pitches = notes.map(\.pitch).sorted()
        let middle = pitches.isEmpty ? (track == .bass ? 40 : track == .drums ? 45 : 64) : pitches[pitches.count / 2]
        scrollTo(y: max(pitchToY(middle) - viewH / 2, 0))
    }

    // MARK: Loudness lane

    private var loudnessLane: some View {
        Canvas { ctx, size in
            for n in notes {
                let x = timeToX(n.start) - scroll.x
                guard x >= -3, x <= size.width else { continue }
                let h = CGFloat(n.velocity) / 127 * (size.height - 4)
                let isSelected = model.selectedNoteIDs.contains(n.id)
                ctx.fill(Path(CGRect(x: x, y: size.height - h, width: 3, height: h)),
                         with: .color(isSelected ? .lfbAccent : track.color.opacity(0.7)))
                ctx.fill(Path(ellipseIn: CGRect(x: x - 2, y: size.height - h - 2, width: 7, height: 7)),
                         with: .color(isSelected ? .lfbAccent : track.color))
            }
        }
        .frame(maxWidth: .infinity)
        .background(Color.lfbWell)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { g in
                    focused = true
                    if stemID == nil {
                        stemID = nearestStem(to: g.startLocation.x + scroll.x)
                        if stemID != nil { model.beginNoteGesture() }
                    }
                    guard let id = stemID else { return }
                    let v = Int((1 - g.location.y / Self.loudnessHeight) * 127 + 1).clamped(to: 1...127)
                    var updated = notes
                    if let i = updated.firstIndex(where: { $0.id == id }) {
                        updated[i].velocity = v
                        if !model.selectedNoteIDs.contains(id) { model.selectedNoteIDs = [id] }
                        model.updateEditingNotes(updated, for: track)
                    }
                }
                .onEnded { _ in
                    if let id = stemID, let n = notes.first(where: { $0.id == id }) { audition(n.pitch, n.velocity) }
                    stemID = nil
                    model.endNoteGesture()
                }
        )
        .help("Drag a stem up or down to change how hard that note is played")
    }

    /// The stem closest to a horizontal position, if one is within a few points of it.
    private func nearestStem(to x: CGFloat) -> Note.ID? {
        let best = notes.min { abs(timeToX($0.start) - x) < abs(timeToX($1.start) - x) }
        guard let best, abs(timeToX(best.start) + 1.5 - x) <= 6 else { return nil }
        return best.id
    }
}

#if os(macOS)
/// Invisible AppKit view over the roll that handles only scroll-wheel and pinch events.
private struct ScrollCatcher: NSViewRepresentable {
    var onScroll: (CGFloat, CGFloat, Bool) -> Void
    var onMagnify: (CGFloat) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onScroll = onScroll; view.onMagnify = onMagnify
        return view
    }
    func updateNSView(_ view: CatcherView, context: Context) {
        view.onScroll = onScroll; view.onMagnify = onMagnify
    }

    final class CatcherView: NSView {
        var onScroll: (CGFloat, CGFloat, Bool) -> Void = { _, _, _ in }
        var onMagnify: (CGFloat) -> Void = { _ in }

        /// Clicks and drags go to the SwiftUI views underneath; only scrolling lands here.
        override func hitTest(_ point: NSPoint) -> NSView? {
            switch NSApp.currentEvent?.type {
            case .scrollWheel, .magnify: super.hitTest(point)
            default: nil
            }
        }
        override func scrollWheel(with event: NSEvent) {
            onScroll(event.scrollingDeltaX, event.scrollingDeltaY, event.hasPreciseScrollingDeltas)
        }
        override func magnify(with event: NSEvent) { onMagnify(event.magnification) }
    }
}
#endif

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}

#if os(iOS)
import UIKit

// MARK: - Touch and Apple Pencil (iPad, iPhone)

/// HANDOFF §4 and §5.5. Finger and Pencil are told apart with UIKit recognizers limited to one
/// touch type, so no tool switch is needed:
/// - **Finger:** tap selects a note (tap empty space deselects; with the Draw tool it adds a note);
///   drag a note to move it, drag its right end to resize; drag empty space to scroll (time and
///   pitch); long press then drag draws a marquee; pinch zooms time (moving the fingers scrolls).
/// - **Pencil:** tap adds a note at the snap length; press and drag draws a note as long as the
///   stroke; on an existing note it moves or resizes it like a finger.
extension PianoRollView {
    fileprivate static let fingerTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
    fileprivate static let pencilTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]

    var touchSurface: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(roll({
                let tap = UITapGestureRecognizer(); tap.allowedTouchTypes = Self.fingerTypes; return tap
            }) { r, p in if r.state == .ended { tapCanvas(at: onSurface(p)) } })
            .gesture(roll({
                let tap = UITapGestureRecognizer(); tap.allowedTouchTypes = Self.pencilTypes; return tap
            }) { r, p in
                guard r.state == .ended else { return }
                pencilUsed = true
                if let hit = touchHitTest(onSurface(p)) { model.selectedNoteIDs = [hit.note.id]; audition(hit.note.pitch, hit.note.velocity) }
                else { addNote(at: onSurface(p)) }
            })
            .gesture(roll({
                let pan = UIPanGestureRecognizer(); pan.allowedTouchTypes = Self.fingerTypes
                pan.maximumNumberOfTouches = 1; return pan
            }) { r, p in fingerPan(r, at: p) })
            .gesture(roll({
                let pan = UIPanGestureRecognizer(); pan.allowedTouchTypes = Self.pencilTypes; return pan
            }) { r, p in pencilPan(r, at: p) })
            .gesture(roll({
                let press = UILongPressGestureRecognizer(); press.allowedTouchTypes = Self.fingerTypes
                press.minimumPressDuration = 0.35; return press
            }) { r, p in marqueePress(r, at: p) })
            .gesture(roll({ UIPinchGestureRecognizer() }) { r, p in pinch(r, at: p) })
    }

    /// A recognizer that also keeps `heldModifiers` (shift-tap adds to the selection, ⌥-drag copies).
    fileprivate func roll<R: UIGestureRecognizer>(_ make: @escaping () -> R,
                                                  _ action: @escaping (R, CGPoint) -> Void) -> RollRecognizer<R> {
        RollRecognizer(make: make, onModifiers: { heldModifiers = $0 }, action: action)
    }

    fileprivate func toggleTool() { tool = tool == .select ? .draw : .select }

    /// Like `hitTest`, with a bigger target for a fingertip: a few points around each note, and the
    /// last 14 points (at most half the note) resize.
    fileprivate func touchHitTest(_ point: CGPoint) -> (note: Note, nearRightEdge: Bool)? {
        if let exact = hitTest(point) {
            let r = noteRect(exact.note)
            return (exact.note, point.x > r.maxX - min(14, r.width / 2))
        }
        let near = notes.reversed().first { noteRect($0).insetBy(dx: -6, dy: -4).contains(point) }
        guard let near else { return nil }
        let r = noteRect(near)
        return (near, point.x > r.maxX - min(14, r.width / 2))
    }

    /// How far the pan has gone. Measured from locations: the representable's recognizer reports
    /// no translation of its own.
    private func moved(to p: CGPoint) -> CGPoint { CGPoint(x: p.x - touchAnchor.x, y: p.y - touchAnchor.y) }

    fileprivate func fingerPan(_ r: UIGestureRecognizer, at p: CGPoint) {
        switch r.state {
        case .began:
            focused = true
            touchAnchor = p
            let moved = CGPoint.zero
            touchStart = onSurface(p)
            scrollAtTouchStart = scroll
            if let hit = touchHitTest(touchStart) {
                touchMode = .notes
                beginNoteDrag(on: hit.note, resize: hit.nearRightEdge)
                applyDrag(dragMode ?? .move, translation: CGSize(width: moved.x, height: moved.y))
            } else {
                touchMode = .scroll
                scrollTo(x: scrollAtTouchStart.x - moved.x, y: scrollAtTouchStart.y - moved.y)
            }
        case .changed:
            let moved = moved(to: p)
            switch touchMode {
            case .scroll: scrollTo(x: scrollAtTouchStart.x - moved.x, y: scrollAtTouchStart.y - moved.y)
            case .notes: if let mode = dragMode { applyDrag(mode, translation: CGSize(width: moved.x, height: moved.y)) }
            default: break
            }
        default:
            endTouch()
        }
    }

    fileprivate func pencilPan(_ r: UIGestureRecognizer, at p: CGPoint) {
        switch r.state {
        case .began:
            focused = true
            pencilUsed = true
            touchAnchor = p
            let moved = CGPoint.zero
            let start = onSurface(p)
            touchMode = .notes
            if let hit = touchHitTest(start) {
                beginNoteDrag(on: hit.note, resize: hit.nearRightEdge)
            } else {
                // Draw: a new note at the snapped start, as long as the stroke (one undo step).
                model.beginNoteGesture()
                let begin = snapTime(xToTime(start.x))
                let pitch = yToPitch(start.y)
                let note = Note(pitch: pitch, start: min(begin, max(duration - 0.05, 0)), duration: max(effectiveSnap, 0.05), velocity: 90)
                model.updateEditingNotes(notes + [note], for: track)
                model.selectedNoteIDs = [note.id]
                audition(pitch)
                beginNoteDrag(on: note, resize: true)
            }
            if let mode = dragMode { applyDrag(mode, translation: CGSize(width: moved.x, height: moved.y)) }
        case .changed:
            let moved = moved(to: p)
            if let mode = dragMode { applyDrag(mode, translation: CGSize(width: moved.x, height: moved.y)) }
        default:
            endTouch()
        }
    }

    fileprivate func marqueePress(_ r: UIGestureRecognizer, at p: CGPoint) {
        switch r.state {
        case .began:
            focused = true
            touchMode = .marquee
            marqueeStart = onSurface(p)
            marqueeRect = CGRect(origin: onSurface(p), size: .zero)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case .changed:
            guard let start = marqueeStart else { return }
            let here = onSurface(p)
            let rect = CGRect(x: min(start.x, here.x), y: min(start.y, here.y),
                              width: abs(here.x - start.x), height: abs(here.y - start.y))
            marqueeRect = rect
            model.selectedNoteIDs = Set(notes.filter { noteRect($0).intersects(rect) }.map(\.id))
        default:
            endTouch()
        }
    }

    /// Pinch zooms time around the fingers; moving both fingers scrolls (time and pitch).
    fileprivate func pinch(_ r: UIGestureRecognizer, at p: CGPoint) {
        guard let pinch = r as? UIPinchGestureRecognizer else { return }
        switch r.state {
        case .began:
            touchMode = .pinch
            zoomAtPinchStart = zoom
            touchStart = p                       // window point, for the two-finger scroll
            scrollAtTouchStart = scroll
        case .changed:
            let anchorTime = xToTime(scroll.x + p.x)
            let newZoom = min(max(zoomAtPinchStart * pinch.scale, 1), maxZoom)
            if abs(newZoom - zoom) > 0.0001 {
                zoom = newZoom
                let width = max(CGFloat(duration) * fitPPS * newZoom, viewW)
                scrollTo(x: timeToX(anchorTime) - p.x, contentWidth: width)
            }
            scrollTo(y: scrollAtTouchStart.y - (p.y - touchStart.y))
        default:
            endTouch()
        }
    }

    private func endTouch() {
        model.endNoteGesture()
        touchMode = nil
        dragOriginals = [:]; dragMode = nil; dragAnchorID = nil; lastAuditionPitch = nil
        marqueeStart = nil; marqueeRect = nil
    }
}

/// One UIKit recognizer as a SwiftUI gesture; reports its state and location in the view.
fileprivate struct RollRecognizer<R: UIGestureRecognizer>: UIGestureRecognizerRepresentable {
    let make: () -> R
    var onModifiers: (EventModifiers) -> Void = { _ in }
    let action: (R, CGPoint) -> Void

    func makeUIGestureRecognizer(context: Context) -> R { make() }
    func handleUIGestureRecognizerAction(_ recognizer: R, context: Context) {
        let flags = recognizer.modifierFlags
        var mods: EventModifiers = []
        if flags.contains(.shift) { mods.insert(.shift) }
        if flags.contains(.alternate) { mods.insert(.option) }
        if flags.contains(.command) { mods.insert(.command) }
        onModifiers(mods)
        action(recognizer, context.converter.localLocation)
    }
}
#endif
