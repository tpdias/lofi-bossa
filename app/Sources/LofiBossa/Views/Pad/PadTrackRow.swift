#if os(iOS)
import SwiftUI

/// The track row on iPad: the Mac row (TrackRowView) with touch sizes from `.touch` in lfb.css.
///
/// Header 264 wide, 10/14 padding, three 32 pt lines:
///   1. 32 pt tile, name (rounded 16, one line), Lock, M and S keys (36 × 32)
///   2. instrument menu (fills), effects, rewrite (or Stop) — 36 × 32 each
///   3. speaker, volume slider in the track color, value
/// States are the Mac's: selected, muted, soloed, dimmed by another solo, rewriting, empty.
/// Double-tap the lane (or "Edit Notes" in the header's long-press menu) opens the piano roll.
struct PadTrackRow: View {
    @Binding var track: Track
    let duration: Double
    /// The stretch of the song the lane shows (the stage's timeline zoom).
    var window = TimelineWindow()
    var grid: BeatGrid? = nil
    var isSelected = false
    var isDimmedBySolo = false
    var isRewriting = false
    var rewritingRange: ClosedRange<Double>? = nil
    var isGeneratorBusy = false
    var compact = false                       // the piano roll is open: name and keys only
    var songBusyness: Double = Project.defaultBusyness
    var songNoteLength: Double = Project.defaultNoteLength
    var onSeek: (Double) -> Void = { _ in }
    var onSelect: () -> Void = {}
    var onRewrite: () -> Void = {}
    var onCancelRewrite: () -> Void = {}
    var onResetEffects: () -> Void = {}
    var onRemove: (() -> Void)? = nil
    var sectionSelection: ClosedRange<Double>? = nil
    var sectionsEnabled = false
    var canPasteSection = false
    var onSelectSection: (Double, Double) -> Void = { _, _ in }
    var onMoveSection: (Double) -> Void = { _ in }
    var onSectionAction: (SectionAction) -> Void = { _ in }

    static let compactHeight: CGFloat = 52

    @State private var showEffects = false

    private var isEmpty: Bool { track.notes.isEmpty && !isRewriting }

    var body: some View {
        HStack(spacing: 0) {
            header
                .frame(width: LFBTouchSize.trackHeaderWidth)
                .frame(maxHeight: .infinity)
                .background(isSelected ? track.id.color.opacity(0.14) : Color.lfbWindow)
                .contentShape(Rectangle())
                .contextMenu { headerMenu }
            Divider()
            lane
        }
        .frame(height: compact ? Self.compactHeight : nil)
        .frame(minHeight: compact ? nil : LFBTouchSize.trackRowMinHeight)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(track.id.title) track")
        .accessibilityAction(named: track.isMuted ? "Unmute" : "Mute") { track.isMuted.toggle() }
        .accessibilityAction(named: track.isSoloed ? "Unsolo" : "Solo") { track.isSoloed.toggle() }
        .accessibilityAction(named: "Edit Notes", onSelect)
        .accessibilityAction(named: "Rewrite") { if !isGeneratorBusy { onRewrite() } }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                TrackGlyph(id: track.id, size: 32)
                Text(track.id.title)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button { track.isLocked.toggle() } label: {
                    Image(systemName: track.isLocked ? "lock.fill" : "lock.open").font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(PadKeyStyle(isOn: track.isLocked, onFill: track.id.color, onText: .lfbWindow))
                .accessibilityLabel("Lock").accessibilityValue(track.isLocked ? "On" : "Off")
                .accessibilityHint("A locked track stays as it is on the next Generate")
                Button("M") { track.isMuted.toggle() }
                    .buttonStyle(PadKeyStyle(isOn: track.isMuted, onFill: .lfbText, onText: .lfbWindow))
                    .accessibilityLabel("Mute").accessibilityValue(track.isMuted ? "On" : "Off")
                Button("S") { track.isSoloed.toggle() }
                    .buttonStyle(PadKeyStyle(isOn: track.isSoloed, onFill: .lfbAccent, onText: .lfbOnAccent))
                    .accessibilityLabel("Solo").accessibilityValue(track.isSoloed ? "On" : "Off")
            }
            .frame(height: 32)
            if !compact {
                HStack(spacing: 6) {
                    instrumentMenu
                    Button { showEffects.toggle() } label: {
                        Image(systemName: "slider.horizontal.3")
                            .foregroundStyle(track.effects.isNeutral ? Color.lfbTextSecondary : track.id.ink)
                    }
                    .buttonStyle(PadIconStyle(isOn: !track.effects.isNeutral, tint: track.id.color))
                    .accessibilityLabel("\(track.id.title) effects")
                    .popover(isPresented: $showEffects, arrowEdge: .trailing) {
                        TrackEffectsPopover(track: track.id, effects: $track.effects, busyness: $track.busyness,
                                            noteLength: $track.noteLength, songBusyness: songBusyness,
                                            songNoteLength: songNoteLength, onReset: onResetEffects)
                            .frame(width: 320)
                    }
                    if isRewriting {
                        Button(action: onCancelRewrite) { Image(systemName: "stop.fill") }
                            .buttonStyle(PadIconStyle())
                            .accessibilityLabel("Stop rewriting")
                    } else {
                        Button(action: onRewrite) { Image(systemName: "arrow.triangle.2.circlepath") }
                            .buttonStyle(PadIconStyle())
                            .disabled(isGeneratorBusy)
                            .accessibilityLabel("Rewrite \(track.id.title)")
                    }
                }
                .frame(height: 32)
                HStack(spacing: 8) {
                    Image(systemName: "speaker.wave.2").font(.system(size: 12)).foregroundStyle(Color.lfbTextTertiary)
                    Slider(value: $track.volume, in: 0...1)
                        .tint(track.id.color)
                        .accessibilityLabel("\(track.id.title) volume")
                    Text("\(Int(track.volume * 100))").font(.system(size: 13, weight: .medium)).monospacedDigit()
                        .foregroundStyle(Color.lfbTextTertiary).frame(width: 28, alignment: .trailing)
                }
                .frame(height: 24)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, compact ? 0 : 10)
        .opacity(track.isMuted || isDimmedBySolo ? 0.55 : 1)
    }

    private var instrumentMenu: some View {
        Menu {
            Picker("Instrument", selection: $track.instrument) {
                ForEach(track.id.instruments, id: \.name) { Text($0.name).tag($0.name) }
            }
        } label: {
            HStack(spacing: 4) {
                Text(track.instrument).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.lfbTextSecondary)
            }
            .font(.system(size: 14))
            .foregroundStyle(Color.lfbText)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: LFBTouchSize.controlHeightSmall)
            .background(Color.lfbControl, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.lfbControlHairline))
        }
        .accessibilityLabel("Instrument")
        .accessibilityValue(track.instrument)
    }

    @ViewBuilder private var headerMenu: some View {
        Button { onSelect() } label: { Label("Edit Notes", systemImage: "pianokeys") }
        Button { onRewrite() } label: { Label("Rewrite \(track.id.title)", systemImage: "arrow.triangle.2.circlepath") }
            .disabled(isGeneratorBusy)
        Button { track.isLocked.toggle() } label: {
            Label(track.isLocked ? "Unlock" : "Lock", systemImage: track.isLocked ? "lock.open" : "lock")
        }
        if let onRemove {
            Divider()
            Button(role: .destructive, action: onRemove) { Label("Remove Track", systemImage: "minus.circle") }
        }
    }

    // MARK: Lane

    private var lane: some View {
        ZStack {
            Color.lfbSurface
            if isSelected { track.id.color.opacity(0.06) }
            NoteLaneView(notes: track.notes, duration: duration, window: window,
                         color: track.isMuted ? .lfbTextTertiary : track.id.color, onSeek: onSeek, grid: grid,
                         glows: !track.isMuted, isDrums: track.id == .drums)
                .opacity(isRewriting && rewritingRange == nil ? 0.2 : (track.isMuted ? 0.45 : (isDimmedBySolo ? 0.3 : 1)))
            if isRewriting {
                if let range = rewritingRange {
                    rangeRewriteOverlay(range)
                } else {
                    SweepView(color: track.id.color)
                    RewritePill(text: "Rewriting the \(track.id.rawValue) to fit the other three…", action: onCancelRewrite)
                }
            }
            if isEmpty { EmptyLane(trackName: track.id.rawValue, action: onRewrite) }
        }
        .clipped()   // zoomed in, notes and selections past the edges stay inside the lane
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onSelect)
        .modifier(SectionSelectable(
            track: track.id, duration: duration, selection: sectionSelection,
            isEnabled: sectionsEnabled && !compact, canPaste: canPasteSection,
            grid: ProjectViewModel.sectionGrid, window: window,
            onSelect: onSelectSection, onMove: onMoveSection, onAction: onSectionAction))
    }

    private func rangeRewriteOverlay(_ range: ClosedRange<Double>) -> some View {
        GeometryReader { geo in
            let x = window.x(for: range.lowerBound, width: geo.size.width, duration: duration)
            let w = max(window.width(of: range.upperBound - range.lowerBound, width: geo.size.width, duration: duration), 2)
            ZStack {
                Color.lfbSurface.opacity(0.8)
                SweepView(color: track.id.color)
                if w > 140 { RewritePill(text: "Rewriting…", action: onCancelRewrite) }
                else {
                    Button("Stop", action: onCancelRewrite).buttonStyle(.plain)
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.lfbAccentText)
                }
            }
            .frame(width: w)
            .clipped()
            .offset(x: x)
        }
    }
}

// MARK: - Touch key and icon button styles

/// M / S / Lock key on touch: 36 × 32, radius 8, outlined off, filled on.
struct PadKeyStyle: ButtonStyle {
    var isOn: Bool
    var onFill: Color
    var onText: Color
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(isOn ? onText : Color.lfbTextSecondary)
            .frame(width: LFBTouchSize.keyMS.width, height: LFBTouchSize.keyMS.height)
            .lfbDepth(RoundedRectangle(cornerRadius: 8), fill: isOn ? onFill : Color.lfbControl,
                      elevation: isOn ? .none : .low, pressed: configuration.isPressed, highlight: !isOn)
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(isOn ? .clear : Color.lfbControlHairline, lineWidth: 1))
            .contentShape(Rectangle().inset(by: -4))   // a little more than drawn, toward 44
    }
}

/// Icon button on touch (`.ib`): 36 × 32.
struct PadIconStyle: ButtonStyle {
    var isOn = false
    var tint: Color = .lfbAccent
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15))
            .foregroundStyle(Color.lfbTextSecondary)
            .frame(width: 36, height: 32)
            .background(isOn ? tint.opacity(0.2) : (configuration.isPressed ? Color.lfbWell : .clear),
                        in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle().inset(by: -4))
            .opacity(isEnabled ? 1 : 0.4)
    }
}
#endif
