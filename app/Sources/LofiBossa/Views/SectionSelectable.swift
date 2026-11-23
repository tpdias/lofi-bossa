import SwiftUI

enum SectionAction {
    case cut, copy, paste, delete, duplicate, useAsLoop, rewrite, clear
}

/// Makes a track's lane selectable by dragging: drag on empty lane to pick a stretch, drag
/// inside the picked stretch to move it. Draws the selection and a small action pill over it,
/// and adds the same actions to the lane's right-click menu.
///
/// Click-to-seek and double-click-to-edit are untouched: the drag only starts after the pointer
/// has moved a few points, so a plain click still reaches the lane's own tap gestures.
struct SectionSelectable: ViewModifier {
    let track: TrackID
    let duration: Double
    /// This track's selected stretch, if the selection is on this track.
    let selection: ClosedRange<Double>?
    let isEnabled: Bool
    let canPaste: Bool
    let grid: Double
    /// The stretch of the song the lane shows, for mapping x to time when zoomed in.
    var window = TimelineWindow()
    var onSelect: (Double, Double) -> Void
    var onMove: (Double) -> Void
    var onAction: (SectionAction) -> Void

    @State private var width: CGFloat = 1
    @State private var dragKind: DragKind?
    @State private var moveOffset: Double = 0

    private enum DragKind { case select, move }
    private let pillWidth: CGFloat = 206

    func body(content: Content) -> some View {
        content
            .background(GeometryReader { geo in
                Color.clear
                    .onAppear { width = max(geo.size.width, 1) }
                    .onChange(of: geo.size.width) { width = max($0, 1) }
            })
            .gesture(drag)
            .overlay { selectionOverlay }
            .contextMenu { menu }
    }

    // MARK: Drag

    private var drag: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { g in
                guard isEnabled else { return }
                let start = window.time(atX: g.startLocation.x, width: width, duration: duration)
                let now = window.time(atX: g.location.x, width: width, duration: duration)
                if dragKind == nil {
                    dragKind = (selection.map { $0.contains(start) } ?? false) ? .move : .select
                }
                switch dragKind {
                case .move: moveOffset = (now - start)
                case .select: onSelect(start, now)
                case nil: break
                }
            }
            .onEnded { _ in
                if dragKind == .move { onMove(moveOffset) }
                dragKind = nil
                moveOffset = 0
            }
    }

    // MARK: Drawing

    private func snapped(_ seconds: Double) -> Double { (seconds / grid).rounded() * grid }

    @ViewBuilder private var selectionOverlay: some View {
        if let selection {
            GeometryReader { geo in
                let shift = dragKind == .move ? snapped(moveOffset) : 0
                let length = selection.upperBound - selection.lowerBound
                let lo = min(max(selection.lowerBound + shift, 0), max(duration - length, 0))
                let x = window.x(for: lo, width: geo.size.width, duration: duration)
                let w = max(window.width(of: length, width: geo.size.width, duration: duration), 2)
                ZStack(alignment: .topLeading) {
                    Rectangle().fill(track.color.opacity(0.22))
                        .overlay(Rectangle().stroke(track.ink.opacity(0.9), lineWidth: 1.5))
                        .frame(width: w)
                        .offset(x: x)
                        .allowsHitTesting(false)
                    if dragKind == nil && isEnabled {
                        pill
                            .offset(x: min(max(x + w / 2 - pillWidth / 2, 2), max(geo.size.width - pillWidth - 2, 2)), y: 4)
                    }
                }
            }
        }
    }

    private var pill: some View {
        HStack(spacing: 2) {
            pillButton("scissors", "Cut", .cut)
            pillButton("doc.on.doc", "Copy", .copy)
            pillButton("doc.on.clipboard", "Paste at the playhead", .paste, enabled: canPaste)
            pillButton("plus.square.on.square", "Duplicate after", .duplicate)
            pillButton("trash", "Delete", .delete)
            pillButton("repeat", "Loop this section", .useAsLoop)
            pillButton("arrow.triangle.2.circlepath", "Rewrite this section with the model", .rewrite)
        }
        .padding(.horizontal, 4).frame(width: pillWidth, height: 26)
        .background(Color.lfbRaised, in: Capsule())
        .overlay(Capsule().stroke(Color.lfbControlHairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
    }

    private func pillButton(_ symbol: String, _ help: String, _ action: SectionAction, enabled: Bool = true) -> some View {
        Button { onAction(action) } label: {
            Image(systemName: symbol).font(.system(size: 12)).frame(width: 26, height: 22)
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? Color.lfbText : Color.lfbTextTertiary)
        .disabled(!enabled)
        .help(help)
        .accessibilityLabel(help)
    }

    // MARK: Right-click menu

    @ViewBuilder private var menu: some View {
        if isEnabled {
            Button("Cut Section") { onAction(.cut) }.disabled(selection == nil)
            Button("Copy Section") { onAction(.copy) }.disabled(selection == nil)
            Button("Paste at Playhead") { onAction(.paste) }.disabled(!canPaste)
            Button("Duplicate Section") { onAction(.duplicate) }.disabled(selection == nil)
            Button("Delete Section", role: .destructive) { onAction(.delete) }.disabled(selection == nil)
            Divider()
            Button("Rewrite Section") { onAction(.rewrite) }.disabled(selection == nil)
            Button("Use as Loop Range") { onAction(.useAsLoop) }.disabled(selection == nil)
            Button("Clear Selection") { onAction(.clear) }.disabled(selection == nil)
        }
    }
}
