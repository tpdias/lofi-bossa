import SwiftUI

#if os(iOS)
import UIKit

// Small building blocks shared by the iPhone screens (docs/design/artboards/lfb.css, `.m-*`).

/// Capsule chip in the recipe strip and the piano-roll option bar (`.m-chip`, 36 pt high).
struct PhoneChipStyle: ButtonStyle {
    var isOn = false
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .medium))
            .lineLimit(1)
            .foregroundStyle(isOn ? Color.lfbAccentText : Color.lfbText)
            .padding(.horizontal, 12)
            .frame(minHeight: LFBPhoneSize.chipHeight)
            .background(isOn ? Color.lfbAccentWash : Color.lfbControl, in: Capsule())
            .shadow(color: .black.opacity(isOn ? 0 : 0.08), radius: 1.5, y: 1)
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.7 : (isEnabled ? 1 : 0.45))
    }
}

/// The strip's primary button (`.m-gen`): accent capsule, grey when it can't be used.
struct PhoneGenerateStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .lineLimit(1)
            .foregroundStyle(isEnabled ? Color.lfbOnAccent : Color.lfbTextTertiary)
            .padding(.horizontal, 14)
            .frame(minHeight: LFBPhoneSize.chipHeight)
            .background(isEnabled ? Color.lfbAccent : Color.lfbWell, in: Capsule())
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

/// Full-width 52 pt button (`.m-big`); `secondary` is the sunken variant.
struct PhoneBigButtonStyle: ButtonStyle {
    var secondary = false
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(secondary ? Color.lfbText : (isEnabled ? Color.lfbOnAccent : Color.lfbTextTertiary))
            .frame(maxWidth: .infinity, minHeight: LFBPhoneSize.bigButton)
            .background(secondary || !isEnabled ? Color.lfbWell : Color.lfbAccent,
                        in: RoundedRectangle(cornerRadius: LFBPhoneSize.bigButton / 2))
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

/// M / S / rewrite keys on a track card: drawn 40 × 36, hit area padded to 44 (HANDOFF §10).
struct PhoneKeyStyle: ButtonStyle {
    var isOn = false
    var onFill: Color = .lfbText
    var onText: Color = .lfbWindow
    var size: CGSize = LFBPhoneSize.keyMS
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(isOn ? onText : Color.lfbTextSecondary)
            .frame(width: size.width, height: size.height)
            .background(isOn ? onFill : Color.lfbControl, in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(isOn ? .clear : Color.lfbControlHairline, lineWidth: 1))
            .padding(.vertical, max((LFBPhoneSize.minHitTarget - size.height) / 2, 0))
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.7 : (isEnabled ? 1 : 0.35))
    }
}

/// Sheet header (`.m-sh`): title, optional trailing content, close button.
struct PhoneSheetHeader<Trailing: View>: View {
    let title: String
    var leading: AnyView? = nil
    @ViewBuilder var trailing: Trailing
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HStack(spacing: 10) {
            if let leading { leading }
            Text(title).font(.system(size: 19, weight: .bold, design: .rounded))
                .frame(maxWidth: .infinity, alignment: .leading)
            trailing
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 15, weight: .semibold))
                    .frame(width: 30, height: 30)
                    .background(Color.lfbWell, in: Circle())
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.lfbTextSecondary)
            .accessibilityLabel("Close")
        }
        .frame(minHeight: 44)
    }
}

extension PhoneSheetHeader where Trailing == EmptyView {
    init(title: String, leading: AnyView? = nil) {
        self.init(title: title, leading: leading) { EmptyView() }
    }
}

/// Inset grouped block (`.m-list`) with 50 pt rows.
struct PhoneList<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) {
            Group(subviews: content) { rows in
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    row
                        .padding(.horizontal, 14)
                        .frame(minHeight: LFBPhoneSize.listRow)
                    if index < rows.count - 1 { Divider().padding(.leading, 14) }
                }
            }
        }
        .background(Color.lfbSurface, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.lfbHairline, lineWidth: 0.5))
    }
}

/// Diagonal hatching for a lane with no notes (`EmptyLane` sits on top).
struct PhoneHatch: View {
    let color: Color
    var body: some View {
        Canvas { ctx, size in
            var x: CGFloat = -size.height
            while x < size.width {
                var path = Path()
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x + size.height, y: 0))
                ctx.stroke(path, with: .color(color.opacity(0.16)), lineWidth: 1)
                x += 10
            }
        }
    }
}

/// Seconds between time labels, so they never crowd: about four labels across the phone.
func phoneLabelStep(for duration: Double) -> Double {
    [5, 10, 15, 30, 60].first { duration / $0 <= 4.5 } ?? 60
}

// MARK: - Orientation

/// iPhone is portrait everywhere except the piano roll, which may rotate (HANDOFF §5.5, §11.5).
/// The app delegate answers `supportedInterfaceOrientationsFor` from `allowed`; screens change
/// it as they appear. iPad ignores it (`.all`).
enum PhoneOrientation {
    @MainActor static var allowed: UIInterfaceOrientationMask = .all

    @MainActor static func set(_ mask: UIInterfaceOrientationMask) {
        guard UIDevice.current.userInterfaceIdiom == .phone, allowed != mask else { return }
        allowed = mask
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            if mask == .portrait {
                scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait)) { _ in }
            }
        }
    }
}

final class PhoneAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        MainActor.assumeIsolated { PhoneOrientation.allowed }
    }
}
#endif
