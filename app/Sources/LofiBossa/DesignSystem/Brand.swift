import SwiftUI

/// Saudade brand pieces. Display name: "Saudade — Lo-Fi & Bossa". The wordmark is just
/// "Saudade" in the system serif (italic, a display face that ships with every platform), with
/// SF for the rest of the UI. The mark echoes the app icon: a sunset-vinyl disc with note bars.
enum LFBBrand {
    static let name = "Saudade"
    static let displayName = "Saudade — Lo-Fi & Bossa"
}

struct SaudadeMark: View {
    var size: CGFloat = 56
    @Environment(\.lfbTheme) private var theme

    var body: some View {
        ZStack {
            Circle().fill(LinearGradient(colors: [theme.glow, theme.accent], startPoint: .top, endPoint: .bottom))
            ForEach([0.78, 0.56], id: \.self) { f in
                Circle().strokeBorder(Color.black.opacity(0.12), lineWidth: 1).frame(width: size * f, height: size * f)
            }
            VStack(alignment: .leading, spacing: size * 0.05) {
                bar(.lfbPiano, 0.46, 0)
                bar(.lfbGuitar, 0.44, 0.14)
                bar(.lfbBass, 0.3, 0.04)
            }
        }
        .frame(width: size, height: size)
        .shadow(color: theme.accent.opacity(0.35), radius: size * 0.2, y: size * 0.06)
        .accessibilityHidden(true)
    }

    private func bar(_ c: Color, _ w: CGFloat, _ x: CGFloat) -> some View {
        Capsule().fill(c).overlay(Capsule().strokeBorder(Color.black.opacity(0.55), lineWidth: max(size * 0.02, 1)))
            .frame(width: size * w, height: size * 0.11).offset(x: size * x)
    }
}

struct SaudadeWordmark: View {
    var size: CGFloat = 30
    var body: some View {
        Text(LFBBrand.name)
            .font(.system(size: size, weight: .semibold, design: .serif).italic())
            .foregroundStyle(Color.lfbText)
            .accessibilityAddTraits(.isHeader)
    }
}
