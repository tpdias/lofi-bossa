#if os(iOS)
import SwiftUI

/// iPhone Duo half folded with the fold horizontal, resting on a table (HANDOFF §6.3, artboard
/// `DuoTabletop.dc.html`): the "mix while it plays" posture.
///
/// - Top half (watch): title, and four full-width lanes with a name tag, loop range and playhead.
/// - Bottom half (touch): back / 64 pt play / loop / time, three tall effect cards, and a Solo
///   button per track.
///
/// Generation, versions and the piano roll are reached by flattening the device, which returns
/// to the two-page layout with state unchanged. A generation already running keeps running and
/// shows in the lanes.
struct DuoTabletopView: View {
    @Bindable var model: ProjectViewModel

    private var ids: [TrackID] { model.displayedSnapshot?.trackIDs ?? TrackID.core }

    var body: some View {
        DuoPages(axis: .horizontal) {
            watch
        } second: {
            touch
        }
    }

    // MARK: Watch

    private var watch: some View {
        VStack(spacing: 8) {
            DuoNavBar(model: model, onExport: {}, showsActions: false)
            VStack(spacing: 6) {
                ForEach(ids) { id in
                    HStack(spacing: 8) {
                        HStack(spacing: 6) {
                            TrackGlyph(id: id, size: 26)
                            Text(id.title).font(.system(size: 13, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                        }
                        .frame(width: 76, alignment: .leading)
                        ZStack {
                            RoundedRectangle(cornerRadius: LFBPhoneSize.laneRadius).fill(Color.lfbWell)
                            if let track = model.displayedSnapshot?.track(id) {
                                NoteLaneView(notes: track.notes, duration: model.duration,
                                             color: model.isAudible(id) ? id.color : Color.lfbTextTertiary.opacity(0.45),
                                             onSeek: model.seek(to:))
                            }
                            DuoLaneOverlay(model: model, track: id)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: LFBPhoneSize.laneRadius))
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(id.title)
                }
            }
            .padding(.horizontal, 12)
            if model.isGenerating {
                Label("Writing a new take. Flatten the phone to cancel or to see it.", systemImage: "sparkles")
                    .font(.system(size: 12)).foregroundStyle(Color.lfbTextSecondary)
            }
        }
    }

    // MARK: Touch

    private var touch: some View {
        VStack(spacing: 12) {
            HStack(spacing: 14) {
                Button { model.seek(to: model.loopRange.map(\.lowerBound) ?? 0) } label: {
                    Image(systemName: "backward.end.fill").font(.system(size: 18))
                        .foregroundStyle(Color.lfbTextSecondary).frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back to start")
                DuoPlayButton(model: model, size: 64)
                DuoLoopButton(model: model)
                (Text(formatTimecode(model.position)) + Text(" / \(formatTimecode(model.duration))")
                    .font(.system(size: 15)).foregroundColor(.lfbTextSecondary))
                    .font(.system(size: 24, weight: .semibold, design: .rounded)).monospacedDigit()
                    .fixedSize()
            }
            DuoEffectCards(model: model, layout: .tall)
            HStack(spacing: 8) {
                ForEach(ids) { id in
                    let soloed = model.displayedSnapshot?.track(id).isSoloed ?? false
                    Button { model.setSoloed(!soloed, for: id) } label: {
                        HStack(spacing: 6) {
                            Image(systemName: id.symbol).foregroundStyle(soloed ? Color.lfbOnAccent : id.ink)
                            Text("Solo")
                        }
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(soloed ? Color.lfbOnAccent : Color.lfbTextSecondary)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(soloed ? Color.lfbAccent : Color.lfbControl, in: RoundedRectangle(cornerRadius: 11))
                        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(soloed ? .clear : Color.lfbControlHairline, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .disabled(model.displayedSnapshot == nil)
                    .accessibilityLabel("Solo \(id.title)")
                    .accessibilityAddTraits(soloed ? .isSelected : [])
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.lfbSurface, in: RoundedRectangle(cornerRadius: 22))
        .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
    }
}
#endif
