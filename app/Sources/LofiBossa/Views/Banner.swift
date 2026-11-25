import SwiftUI

/// Shared container for the banners under the recipe bar: generating, offline, starting, error.
struct BannerView<Content: View>: View {
    var tint: Color = .lfbTextSecondary
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .top, spacing: LFBSpace.sm) {
            content
        }
        .padding(.horizontal, LFBSpace.lg)
        .padding(.vertical, LFBSpace.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.lfbRaised)
        .overlay(Rectangle().fill(tint).frame(width: 3), alignment: .leading)
        .overlay(Divider(), alignment: .bottom)
    }
}

/// Status pill in the transport, always visible: ready, starting, or offline.
struct GeneratorStatusPill: View {
    let status: GeneratorStatus

    private var tint: Color {
        switch status {
        case .ready: .lfbReady
        case .starting: .lfbTextSecondary
        case .offline: .lfbCaution
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            switch status {
            case .ready: Circle().fill(tint).frame(width: 7, height: 7)
            case .starting: ProgressView().controlSize(.mini)
            case .offline: Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10)).foregroundStyle(tint)
            }
            Text(status.label).font(.lfbCaption).foregroundStyle(Color.lfbTextSecondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Elapsed-time banner for whole-song generation. The lanes behind it show the sweep (see
/// TrackRowView's isRewriting state, reused here per-row) since the local server does not
/// stream notes while it writes.
struct GeneratingBanner: View {
    let style: MusicStyle
    let length: Double
    let seed: UInt32
    let startedAt: Date
    let onCancel: () -> Void

    var body: some View {
        BannerView(tint: .lfbAccent) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text("Writing a new take").font(.lfbBodyMedium)
                TimelineView(.periodic(from: startedAt, by: 1)) { timeline in
                    let elapsed = Int(timeline.date.timeIntervalSince(startedAt))
                    Text("\(style.title) · \(formatTimecode(length)) · seed \(seed) — \(elapsed)s so far, "
                         + "usually under a minute. Cancelling keeps your current take.")
                        .font(.lfbCaption).foregroundStyle(Color.lfbTextSecondary)
                }
            }
            Spacer()
            Button("Cancel", action: onCancel).buttonStyle(.plain)
                .font(.lfbBodyMedium).foregroundStyle(Color.lfbAccentText)
        }
    }
}

struct StartingBanner: View {
    var body: some View {
        BannerView(tint: .lfbTextSecondary) {
            ProgressView().controlSize(.small)
            Text("Starting the generator. This takes a few seconds after launch. "
                 + "Everything except writing new music is ready.")
                .font(.lfbCaption).foregroundStyle(Color.lfbTextSecondary)
        }
    }
}

struct OfflineBanner: View {
    let reason: String?
    let onRestart: () -> Void
    let onShowLog: () -> Void

    var body: some View {
        BannerView(tint: .lfbCaution) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.lfbCaution)
            VStack(alignment: .leading, spacing: 4) {
                Text("The generator is offline. You can still play, mix, edit and export. "
                     + "Writing new music needs it running.")
                    .font(.lfbCaption).foregroundStyle(Color.lfbTextSecondary)
                if let reason {
                    Text(reason).font(.system(size: 11, design: .monospaced)).foregroundStyle(Color.lfbFailure)
                        .lineLimit(2)
                }
                HStack(spacing: 12) {
                    Button("Restart Generator", action: onRestart).buttonStyle(.borderedProminent).controlSize(.small)
                    if reason != nil {
                        Button("Show Log", action: onShowLog).buttonStyle(.plain).controlSize(.small)
                            .font(.lfbCaption).foregroundStyle(Color.lfbAccentText)
                    }
                }
            }
        }
    }
}

struct GenerationErrorBanner: View {
    let message: String
    let detail: String?
    let onRetry: () -> Void

    @State private var showDetail = false

    var body: some View {
        BannerView(tint: .lfbFailure) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.lfbFailure)
            VStack(alignment: .leading, spacing: 4) {
                Text(message).font(.lfbBodyMedium)
                Text("Your song is unchanged.").font(.lfbCaption).foregroundStyle(Color.lfbTextSecondary)
                if showDetail, let detail {
                    Text(detail).font(.system(size: 11, design: .monospaced)).foregroundStyle(Color.lfbTextSecondary)
                        .textSelection(.enabled)
                }
                HStack(spacing: 12) {
                    Button("Try Again", action: onRetry).buttonStyle(.borderedProminent).controlSize(.small)
                    if detail != nil {
                        Button(showDetail ? L("Hide Details") : L("Details")) { showDetail.toggle() }
                            .buttonStyle(.plain).controlSize(.small)
                            .font(.lfbCaption).foregroundStyle(Color.lfbAccentText)
                    }
                }
            }
        }
    }
}
