import SwiftUI

#if os(iOS)
/// iPhone Duo, open, fold vertical. See the "Duo open · …" artboards.
/// Left page: the song (the same compact stage as iPhone). Right page: PanelView (Sound, Versions, Notes).
/// The same split is used flat and half folded like a book, so nothing jumps when the hinge moves,
/// and nothing interactive ever crosses the fold.
///
/// TODO(iOS 27.1): replace the fixed HStack split with Apple's ArrangementView and keep custom controls
/// out of the fold's ReservedRegion. Names are from Apple's developer forum; verify the signatures.
struct TwoPageProjectView: View {
    @Bindable var session: ProjectSession

    var body: some View {
        HStack(spacing: LFBSize.foldGap) {
            PhoneProjectView(session: session)
                .frame(maxWidth: .infinity)
            PanelView(session: session)
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(Color.lfbSurface, in: RoundedRectangle(cornerRadius: 22))
        }
        .padding([.horizontal, .bottom], 8)
        .background(Color.lfbWindow)
        // On the Duo, "Edit notes" switches the right page to Notes instead of pushing an editor.
        .onChange(of: session.isEditingNotes) { _, editing in
            if editing { session.isEditingNotes = false; session.panel = .notes }
        }
    }
}

/// iPhone Duo half folded with the fold horizontal (resting on a table).
/// Top half: watch (four lanes with names, playhead, loop). Bottom half: touch (transport, three
/// large effect cards, a solo button per track). Mirrors the "Duo half folded · tabletop" artboard.
struct TabletopProjectView: View {
    @Bindable var session: ProjectSession

    var body: some View {
        VStack(spacing: LFBSize.foldGap) {
            VStack(spacing: 6) {
                ForEach(session.song.tracks) { track in
                    HStack(spacing: 8) {
                        Label(track.id.title, systemImage: track.id.symbol)
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 84, alignment: .leading)
                        NoteLaneView(notes: track.notes, duration: session.duration, color: track.id.color)
                            .background(Color.lfbWell, in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
            .frame(maxHeight: .infinity)

            VStack(spacing: 12) {
                PhoneTransport(session: session)
                HStack(spacing: 8) {
                    EffectCard(title: "Warmth", caption: "", symbol: "sun.max", amount: $session.song.effects.warmth)
                    EffectCard(title: "Reverb", caption: "", symbol: "dot.radiowaves.left.and.right", amount: $session.song.effects.reverb)
                    EffectCard(title: "Vinyl", caption: "", symbol: "opticaldisc", amount: $session.song.effects.vinyl)
                }
            }
            .padding(12)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(Color.lfbSurface, in: RoundedRectangle(cornerRadius: 22))
        }
        .padding(8)
        .background(Color.lfbWindow)
    }
}
#endif
