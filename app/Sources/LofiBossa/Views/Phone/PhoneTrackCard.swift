import SwiftUI

#if os(iOS)
/// A compact track card (HANDOFF §5.3, `.m-card`): header (tile, name and instrument, rewrite,
/// M, S) over a full-width lane with the loop range, playhead and write head.
///
/// - Tap the name: track sheet. Long press the header: Instrument, Lock, Edit notes, Rewrite.
/// - Tap the lane to seek; long press then drag in the lane to set the loop range.
/// - States as on the Mac row: selected, muted, soloed, silenced by a solo, locked, rewriting,
///   empty. VoiceOver reads the card as one element with custom actions (HANDOFF §10).
struct PhoneTrackCard: View {
    @Bindable var model: ProjectViewModel
    let id: TrackID
    var isShort = false
    var isSelected = false
    var onOpenTrack: () -> Void

    @State private var loopAnchor: Double?
    @Environment(\.dynamicTypeSize) private var typeSize

    private var track: Track { model.displayedSnapshot?.track(id) ?? Track(id: id, instrument: id.defaultInstrument) }
    private var binding: Binding<Track> { phoneTrackBinding(model, id) }
    private var isRewriting: Bool { model.rewritingTrack == id }
    private var isDimmed: Bool { model.isDimmedBySolo(id) }
    private var duration: Double { max(model.duration, 1) }
    private var isEmpty: Bool { track.notes.isEmpty && !isRewriting }
    private var hasSong: Bool { model.displayedSnapshot != nil }
    private var keySize: CGSize { isShort ? CGSize(width: 36, height: 32) : LFBPhoneSize.keyMS }

    var body: some View {
        VStack(alignment: .leading, spacing: isShort ? 4 : 6) {
            header
            lane
        }
        .padding(isShort ? EdgeInsets(top: 6, leading: 10, bottom: 8, trailing: 10)
                         : EdgeInsets(top: 8, leading: 12, bottom: 12, trailing: 12))
        .background(Color.lfbSurface, in: RoundedRectangle(cornerRadius: isShort ? 16 : LFBPhoneSize.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: isShort ? 16 : LFBPhoneSize.cardRadius)
            .strokeBorder(isSelected ? id.color : Color.lfbHairline, lineWidth: isSelected ? 2.5 : 0.5))
        .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
        .opacity(isDimmed ? 0.55 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue)
        .accessibilityHint("Shows instrument, volume and note editing")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onOpenTrack() }
        .accessibilityAction(named: track.isMuted ? L("Unmute") : L("Mute")) { binding.wrappedValue.isMuted.toggle() }
        .accessibilityAction(named: track.isSoloed ? L("Unsolo") : L("Solo")) { binding.wrappedValue.isSoloed.toggle() }
        .accessibilityAction(named: isRewriting ? L("Stop rewriting") : L("Rewrite")) { rewriteOrStop() }
        .accessibilityAction(named: track.isLocked ? L("Unlock") : L("Lock")) { binding.wrappedValue.isLocked.toggle() }
        .accessibilityAction(named: "Edit notes") { model.openEditor(for: id) }
        .accessibilityAction(named: "Change instrument") { onOpenTrack() }
        .accessibilityIdentifier("track-card-\(id.rawValue)")
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 6) {
            Button(action: onOpenTrack) {
                HStack(spacing: 8) {
                    TrackGlyph(id: id, size: isShort ? 30 : 34)
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 4) {
                            Text(id.title).font(.system(size: 16, weight: .semibold, design: .rounded)).lineLimit(1)
                            if track.isLocked {
                                Image(systemName: "lock.fill").font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(id.ink)
                            }
                        }
                        if !typeSize.isAccessibilitySize {
                            Text(localizedName(track.instrument)).font(.system(size: 12)).foregroundStyle(Color.lfbTextTertiary).lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .opacity(track.isMuted ? 0.5 : 1)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(minHeight: LFBPhoneSize.minHitTarget)
            .contextMenu { contextMenu }

            Button(action: rewriteOrStop) {
                Image(systemName: isRewriting ? "stop.fill" : "arrow.triangle.2.circlepath")
                    .font(.system(size: 15, weight: .semibold))
            }
            .buttonStyle(PhoneKeyStyle(size: keySize))
            .disabled(!isRewriting && (model.isGeneratorBusy || !hasSong || model.status != .ready || model.isListeningToPastVersion))

            Button("M") { binding.wrappedValue.isMuted.toggle() }
                .buttonStyle(PhoneKeyStyle(isOn: track.isMuted, onFill: .lfbText, onText: .lfbWindow, size: keySize))
            Button("S") { binding.wrappedValue.isSoloed.toggle() }
                .buttonStyle(PhoneKeyStyle(isOn: track.isSoloed, onFill: .lfbAccent, onText: .lfbOnAccent, size: keySize))
        }
        .frame(height: isShort ? 36 : LFBPhoneSize.cardHeader)
    }

    @ViewBuilder private var contextMenu: some View {
        Picker("Instrument", selection: binding.instrument) {
            ForEach(id.instruments, id: \.name) { Text(localizedName($0.name)).tag($0.name) }
        }
        .pickerStyle(.menu)
        Button(track.isLocked ? L("Unlock") : L("Lock for Next Take"), systemImage: track.isLocked ? "lock.open" : "lock") {
            binding.wrappedValue.isLocked.toggle()
        }
        Button("Edit Notes", systemImage: "pianokeys") { model.openEditor(for: id) }
            .disabled(!hasSong)
        Button("Rewrite This Part", systemImage: "arrow.triangle.2.circlepath") { model.rewrite(id) }
            .disabled(model.isGeneratorBusy || !hasSong || model.status != .ready)
    }

    private func rewriteOrStop() {
        if isRewriting { model.cancelRewrite() } else { model.rewrite(id) }
    }

    // MARK: Lane

    private var lane: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .topLeading) {
                Color.lfbWell
                if !hasSong || isEmpty { PhoneHatch(color: id.color) }
                if model.isLoopEnabled || loopAnchor != nil, let range = model.loopRange {
                    Rectangle().fill(Color.lfbAccentWash)
                        .overlay(alignment: .leading) { Rectangle().fill(Color.lfbAccent).frame(width: 1.5) }
                        .overlay(alignment: .trailing) { Rectangle().fill(Color.lfbAccent).frame(width: 1.5) }
                        .frame(width: max(CGFloat((range.upperBound - range.lowerBound) / duration) * w, 2))
                        .offset(x: CGFloat(range.lowerBound / duration) * w)
                }
                NoteLaneView(notes: track.notes, duration: duration,
                             color: track.isMuted ? .lfbTextTertiary : id.color)
                    .padding(.vertical, -3)   // NoteLaneView pads 10; the card lane wants 7
                    .opacity(isRewriting && model.rewritingRange == nil ? 0.2 : (track.isMuted ? 0.45 : 1))
                    .allowsHitTesting(false)
                if hasSong && !model.isGenerating {
                    Rectangle().fill(Color.lfbText).frame(width: 2)
                        .offset(x: CGFloat(min(model.position / duration, 1)) * w - 1)
                }
                if model.isGenerating { SweepView(color: id.color) }
                overlayPill
                    .frame(width: w, height: geo.size.height)
            }
            .contentShape(Rectangle())
            .gesture(laneGesture(width: w))
        }
        .frame(minHeight: 24)
        .clipShape(RoundedRectangle(cornerRadius: LFBPhoneSize.laneRadius))
    }

    @ViewBuilder private var overlayPill: some View {
        if isRewriting {
            if let range = model.rewritingRange {
                GeometryReader { geo in
                    SweepView(color: id.color)
                        .frame(width: CGFloat((range.upperBound - range.lowerBound) / duration) * geo.size.width)
                        .offset(x: CGFloat(range.lowerBound / duration) * geo.size.width)
                }
            } else {
                SweepView(color: id.color)
            }
            RewritePill(text: "Rewriting this track…", action: model.cancelRewrite)
                .font(.system(size: 13))
        } else if hasSong && isEmpty && !model.isGenerating {
            EmptyLane(trackName: id.rawValue, action: { model.rewrite(id) })
                .disabled(model.isGeneratorBusy || model.status != .ready)
        } else if case .failed(let message, _, let scope) = model.phase, scope == id {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.lfbFailure)
                Text(message).lineLimit(1)
                Button("Try again") { model.dismissError(); model.rewrite(id) }
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.lfbAccentText)
            }
            .font(.system(size: 12))
            .padding(.horizontal, 10).frame(height: 28)
            .background(Color.lfbRaised, in: Capsule())
        }
    }

    /// Tap seeks; long press then drag sets the loop range (HANDOFF §5.3).
    private func laneGesture(width: CGFloat) -> some Gesture {
        let seconds: (CGFloat) -> Double = { x in min(max(Double(x / max(width, 1)) * duration, 0), duration) }
        let loopDrag = LongPressGesture(minimumDuration: 0.35)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .onChanged { value in
                guard case .second(true, let drag?) = value else { return }
                if loopAnchor == nil {
                    loopAnchor = seconds(drag.startLocation.x)
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
                let a = loopAnchor ?? 0, b = seconds(drag.location.x)
                let lo = min(a, b), hi = max(a, b)
                model.setLoopRange(lo...max(hi, min(lo + 0.5, duration)))
            }
            .onEnded { _ in loopAnchor = nil }
        return loopDrag.exclusively(before: SpatialTapGesture().onEnded { tap in
            guard hasSong else { return }
            model.seek(to: seconds(tap.location.x))
        })
    }

    // MARK: Accessibility

    private var accessibilityLabel: String { "\(id.title) track, \(track.instrument)" }
    private var accessibilityValue: String {
        var parts: [String] = []
        if track.isMuted { parts.append("muted") }
        if track.isSoloed { parts.append("soloed") }
        if isDimmed { parts.append("silenced by another solo") }
        if track.isLocked { parts.append("locked") }
        if isRewriting { parts.append("rewriting") }
        if hasSong && isEmpty { parts.append("no notes") }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Floating transport

/// The floating transport (HANDOFF §5.2, `.m-tp`): scrubber with the playhead knob and the loop
/// range, the time row, then Sound · back to start · play · loop · Versions.
/// Drag the knob to scrub; drag anywhere else on the scrubber to set the loop range; tap to seek.
struct PhoneTransport: View {
    @Bindable var model: ProjectViewModel
    var isShort = false
    var onSound: () -> Void
    var onVersions: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    private var hasSong: Bool { model.displayedSnapshot != nil }

    var body: some View {
        VStack(spacing: 2) {
            PhoneScrubber(model: model)
                .frame(height: 28)
                .disabled(!hasSong)
            if !isShort {
                HStack {
                    Text(formatTimecode(model.position))
                    Spacer()
                    if let range = model.loopRange {
                        Button { model.clearLoop() } label: {
                            HStack(spacing: 3) {
                                Text("Loop \(formatTimecode(range.lowerBound)) – \(formatTimecode(range.upperBound))")
                                Image(systemName: "xmark.circle.fill")
                            }
                            .foregroundStyle(model.isLoopEnabled ? Color.lfbAccentText : Color.lfbTextTertiary)
                            .frame(minHeight: 22)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear loop \(formatTimecode(range.lowerBound)) to \(formatTimecode(range.upperBound))")
                    }
                    Spacer()
                    Text(formatTimecode(model.duration))
                }
                .font(.system(size: 12)).monospacedDigit()
                .foregroundStyle(Color.lfbTextTertiary)
                .padding(.top, -4)
            }
            HStack {
                paneButton("Sound", "slider.horizontal.3", action: onSound)
                    .accessibilityIdentifier("sound")
                Spacer()
                Button { model.seek(to: model.loopRange?.lowerBound ?? 0) } label: {
                    Image(systemName: "backward.end.fill").font(.system(size: 20))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain).foregroundStyle(Color.lfbTextSecondary)
                .disabled(!hasSong)
                .accessibilityLabel("Back to start")
                Spacer()
                Button(action: model.togglePlay) {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(Color.lfbWindow)
                        .frame(width: isShort ? LFBPhoneSize.playButtonShort : LFBPhoneSize.playButton,
                               height: isShort ? LFBPhoneSize.playButtonShort : LFBPhoneSize.playButton)
                        .background(Color.lfbText, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(!hasSong)
                .opacity(hasSong ? 1 : 0.35)
                .accessibilityLabel(model.isPlaying ? L("Pause") : L("Play"))
                .accessibilityIdentifier("play")
                Spacer()
                Button(action: model.toggleLoop) {
                    Image(systemName: "repeat").font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(model.isLoopEnabled ? Color.lfbAccentText : Color.lfbTextSecondary)
                        .frame(width: 44, height: 44)
                        .background(model.isLoopEnabled ? Color.lfbAccentWash : .clear, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(model.loopRange == nil)
                .opacity(model.loopRange == nil ? 0.4 : 1)
                .accessibilityLabel("Loop the selected range")
                .accessibilityValue(model.isLoopEnabled ? L("On") : L("Off"))
                Spacer()
                paneButton("Versions", "clock.arrow.circlepath", action: onVersions)
                    .accessibilityIdentifier("versions")
            }
        }
        .padding(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
        .background(Color.lfbRaised, in: RoundedRectangle(cornerRadius: LFBPhoneSize.transportRadius))
        .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
        .overlay(RoundedRectangle(cornerRadius: LFBPhoneSize.transportRadius).strokeBorder(Color.lfbHairline, lineWidth: 0.5))
    }

    private func paneButton(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 1) {
                Image(systemName: symbol).font(.system(size: 20))
                if !isShort && !typeSize.isAccessibilitySize {
                    Text(title).font(.system(size: 11, weight: .medium))
                }
            }
            .foregroundStyle(Color.lfbTextSecondary)
            .frame(width: isShort ? 48 : 64, height: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

/// The transport's scrubber: track, played part, loop range and the playhead knob.
struct PhoneScrubber: View {
    @Bindable var model: ProjectViewModel
    @State private var mode: Mode?
    @State private var anchor: Double = 0
    private enum Mode { case scrub, loop }

    private var duration: Double { max(model.duration, 1) }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let px = CGFloat(min(model.position / duration, 1)) * w
            ZStack(alignment: .leading) {
                Capsule().fill(Color.lfbControlHairline).frame(height: 4)
                if let range = model.loopRange {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.lfbAccentWash)
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.lfbAccent, lineWidth: 1.5))
                        .frame(width: max(CGFloat((range.upperBound - range.lowerBound) / duration) * w, 6), height: 18)
                        .offset(x: CGFloat(range.lowerBound / duration) * w)
                        .opacity(model.isLoopEnabled ? 1 : 0.5)
                }
                Capsule().fill(Color.lfbText).frame(width: px, height: 4)
                Circle().fill(Color.lfbText).frame(width: 16, height: 16)
                    .overlay(Circle().strokeBorder(Color.lfbRaised, lineWidth: 2))
                    .offset(x: px - 8)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(drag(width: w, knobX: px))
        }
        .accessibilityElement()
        .accessibilityLabel("Playhead")
        .accessibilityValue("\(formatTimecode(model.position)) of \(formatTimecode(model.duration))")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: model.nudgePlayhead(by: 5)
            case .decrement: model.nudgePlayhead(by: -5)
            @unknown default: break
            }
        }
    }

    private func drag(width: CGFloat, knobX: CGFloat) -> some Gesture {
        let t: (CGFloat) -> Double = { x in min(max(Double(x / max(width, 1)) * duration, 0), duration) }
        return DragGesture(minimumDistance: 0)
            .onChanged { g in
                if mode == nil {
                    let moved = abs(g.translation.width) > 6
                    if abs(g.startLocation.x - knobX) <= 22 { mode = .scrub }
                    else if moved { mode = .loop; anchor = t(g.startLocation.x) }
                    else { return }
                }
                switch mode {
                case .scrub: model.seek(to: t(g.location.x))
                case .loop:
                    let b = t(g.location.x)
                    let lo = min(anchor, b), hi = max(anchor, b)
                    model.setLoopRange(lo...max(hi, min(lo + 0.5, duration)))
                case nil: break
                }
            }
            .onEnded { g in
                if mode == nil { model.seek(to: t(g.location.x)) }   // a tap
                mode = nil
            }
    }
}
#endif
