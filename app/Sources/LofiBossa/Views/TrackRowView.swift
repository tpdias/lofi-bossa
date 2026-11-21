import SwiftUI

/// The track row, all states (see design artboard "Track row · all states").
///
/// States are derived, never stored:
///   normal      track has notes, nothing special
///   selected    the piano-roll editor is open on this track (tinted header and lane)
///   muted       track.isMuted: notes go grey, M is filled
///   soloed      track.isSoloed: S is filled in the accent
///   dimmed      another track is soloed: dimmed, controls stay live
///   rewriting   generator is rewriting this track: sweep, pill with Stop, rewrite button becomes Stop
///   empty       no notes: hatched lane with a one-click "Write the <track>" action
struct TrackRowView: View {
    @Binding var track: Track
    let duration: Double
    var isSelected = false
    var isDimmedBySolo = false
    var isRewriting = false
    var rewritingRange: ClosedRange<Double>? = nil   // set when only part of the track is rewritten
    var isGeneratorBusy = false
    var compact = false                       // true while the piano roll is open
    var songBusyness: Double = Project.defaultBusyness
    var songNoteLength: Double = Project.defaultNoteLength
    var onSeek: (Double) -> Void = { _ in }
    var onSelect: () -> Void = {}
    var onRewrite: () -> Void = {}
    var onCancelRewrite: () -> Void = {}
    var onResetEffects: () -> Void = {}
    // Section editing (see SectionSelectable)
    var sectionSelection: ClosedRange<Double>? = nil
    var sectionsEnabled = false
    var canPasteSection = false
    var onSelectSection: (Double, Double) -> Void = { _, _ in }
    var onMoveSection: (Double) -> Void = { _ in }
    var onSectionAction: (SectionAction) -> Void = { _ in }

    @State private var showEffects = false

    private var isEmpty: Bool { track.notes.isEmpty && !isRewriting }

    var body: some View {
        HStack(spacing: 0) {
            header
                .frame(width: LFBSize.trackHeaderWidth)
                .background(isSelected ? track.id.color.opacity(0.14) : .clear)
            Divider()
            lane
        }
        .frame(height: compact ? LFBSize.trackRowCompactHeight : nil)
        .frame(minHeight: compact ? nil : LFBSize.trackRowMinHeight)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(track.id.title) track")
    }

    // MARK: Header (name, M/S, instrument, rewrite, volume)

    private var header: some View {
        VStack(alignment: .leading, spacing: LFBSpace.xs) {
            HStack(spacing: 6) {
                TrackGlyph(id: track.id)
                Text(track.id.title)
                    .font(.lfbHeadline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("M") { track.isMuted.toggle() }
                    .buttonStyle(KeyToggleStyle(isOn: track.isMuted, onFill: .lfbText, onText: .lfbWindow))
                    .accessibilityLabel("Mute").accessibilityValue(track.isMuted ? "On" : "Off")
                Button("S") { track.isSoloed.toggle() }
                    .buttonStyle(KeyToggleStyle(isOn: track.isSoloed, onFill: .lfbAccent, onText: .lfbOnAccent))
                    .accessibilityLabel("Solo").accessibilityValue(track.isSoloed ? "On" : "Off")
            }
            if !compact {
                HStack(spacing: 6) {
                    Picker("Instrument", selection: $track.instrument) {
                        ForEach(track.id.instruments, id: \.name) { Text($0.name).tag($0.name) }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    Button { showEffects.toggle() } label: {
                        Image(systemName: "slider.horizontal.3")
                            .foregroundStyle(track.effects.isNeutral ? Color.lfbTextSecondary : track.id.ink)
                            .padding(3)
                            .background(track.effects.isNeutral ? .clear : track.id.color.opacity(0.2),
                                        in: RoundedRectangle(cornerRadius: 4))
                    }
                    .help("Effects for this track")
                    .accessibilityLabel("\(track.id.title) effects")
                    .popover(isPresented: $showEffects, arrowEdge: .bottom) {
                        TrackEffectsPopover(track: track.id, effects: $track.effects, busyness: $track.busyness,
                                            noteLength: $track.noteLength, songBusyness: songBusyness,
                                            songNoteLength: songNoteLength, onReset: onResetEffects)
                    }
                    if isRewriting {
                        Button(action: onCancelRewrite) { Image(systemName: "stop.fill") }
                            .help("Stop rewriting")
                    } else {
                        Button(action: onRewrite) { Image(systemName: "arrow.triangle.2.circlepath") }
                            .disabled(isGeneratorBusy)
                            .help("Rewrite this part to fit the other three")
                            .accessibilityLabel("Rewrite \(track.id.title)")
                    }
                }
                .buttonStyle(.borderless)
                HStack(spacing: 6) {
                    Image(systemName: "speaker.wave.2").font(.system(size: 11)).foregroundStyle(Color.lfbTextTertiary)
                    Slider(value: $track.volume, in: 0...1).controlSize(.small).tint(track.id.color)
                    Text("\(Int(track.volume * 100))").font(.lfbCaption).monospacedDigit()
                        .foregroundStyle(Color.lfbTextTertiary).frame(width: 22, alignment: .trailing)
                }
            }
        }
        .padding(.horizontal, LFBSpace.md)
        .padding(.vertical, LFBSpace.sm)
        .opacity(track.isMuted || isDimmedBySolo ? 0.55 : 1)
    }

    /// Sweep and Stop over just the stretch being rewritten; the rest of the lane stays as it is.
    private func rangeRewriteOverlay(_ range: ClosedRange<Double>) -> some View {
        GeometryReader { geo in
            let x = CGFloat(range.lowerBound / max(duration, 0.001)) * geo.size.width
            let w = max(CGFloat((range.upperBound - range.lowerBound) / max(duration, 0.001)) * geo.size.width, 2)
            ZStack {
                Color.lfbSurface.opacity(0.8)
                SweepView(color: track.id.color)
                if w > 120 { RewritePill(text: "Rewriting…", action: onCancelRewrite) }
                else { Button("Stop", action: onCancelRewrite).buttonStyle(.plain).font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.lfbAccentText) }
            }
            .frame(width: w)
            .clipped()
            .offset(x: x)
        }
    }

    // MARK: Lane (notes, states)

    private var lane: some View {
        ZStack {
            Color.lfbSurface
            if isSelected { track.id.color.opacity(0.06) }
            NoteLaneView(notes: track.notes, duration: duration,
                         color: track.isMuted ? .lfbTextTertiary : track.id.color, onSeek: onSeek)
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
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onSelect)   // double-click opens the piano-roll editor
        .modifier(SectionSelectable(
            track: track.id, duration: duration, selection: sectionSelection,
            isEnabled: sectionsEnabled && !compact, canPaste: canPasteSection,
            grid: ProjectViewModel.sectionGrid,
            onSelect: onSelectSection, onMove: onMoveSection, onAction: onSectionAction))
    }
}

// MARK: - Small pieces

/// Track icon tile: a colored rounded square with the track's glyph. Drums has no fitting
/// system symbol, so it draws four small dots rather than shipping a custom SF Symbol.
struct TrackGlyph: View {
    let id: TrackID
    var size: CGFloat = 26

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7).fill(id.color.opacity(0.2))
            if id == .drums {
                Grid(horizontalSpacing: 3, verticalSpacing: 3) {
                    GridRow { Circle().frame(width: 4, height: 4); Circle().frame(width: 4, height: 4) }
                    GridRow { Circle().frame(width: 4, height: 4); Circle().frame(width: 4, height: 4) }
                }
                .foregroundStyle(id.ink)
            } else {
                Image(systemName: id.symbol).font(.system(size: 13)).foregroundStyle(id.ink)
            }
        }
        .frame(width: size, height: size)
    }
}

/// M / S toggle: 24 x 22, radius 5, outlined when off, filled when on.
struct KeyToggleStyle: ButtonStyle {
    var isOn: Bool
    var onFill: Color
    var onText: Color
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(isOn ? onText : Color.lfbTextSecondary)
            .frame(width: 24, height: 22)
            .background(isOn ? onFill : Color.lfbControl, in: RoundedRectangle(cornerRadius: LFBRadius.key))
            .overlay(RoundedRectangle(cornerRadius: LFBRadius.key)
                .strokeBorder(isOn ? .clear : Color.lfbControlHairline, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

struct RewritePill: View {
    let text: String
    let action: () -> Void
    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text).font(.system(size: 12))
            Button("Stop", action: action).buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.lfbAccentText)
        }
        .padding(.leading, 10).padding(.trailing, 6).frame(height: 28)
        .background(Color.lfbRaised, in: Capsule())
        .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
    }
}

struct EmptyLane: View {
    let trackName: String
    let action: () -> Void
    var body: some View {
        HStack(spacing: 8) {
            Text("No notes in this part").font(.system(size: 12))
            Button("Write the \(trackName)", action: action).buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.lfbAccentText)
        }
        .padding(.horizontal, 12).frame(height: 28)
        .background(Color.lfbRaised, in: Capsule())
    }
}

/// Soft colored band that travels across the lane while a track is being rewritten.
/// Honors Reduce Motion by holding a static tint.
struct SweepView: View {
    let color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        if reduceMotion {
            color.opacity(0.18)
        } else {
            TimelineView(.animation) { timeline in
                GeometryReader { geo in
                    let t = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.8) / 1.8
                    LinearGradient(colors: [.clear, color.opacity(0.32), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: geo.size.width * 0.35)
                        .offset(x: -geo.size.width * 0.35 + (geo.size.width * 1.35) * t)
                }
            }
            .allowsHitTesting(false)
        }
    }
}
