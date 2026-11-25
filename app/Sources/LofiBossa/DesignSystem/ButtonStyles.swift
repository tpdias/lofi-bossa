import SwiftUI

// Shared button depth: a 1 pt top highlight, a two-layer shadow (tight and dark, wide and warm),
// and a pressed state that sits a little lower. Every layout (Mac, iPad, iPhone, Duo) uses these,
// directly or through its own style that calls `lfbDepth`. Increase Contrast swaps the soft
// shadows for a crisp border.

private struct LFBDepth<S: InsettableShape, F: ShapeStyle>: ViewModifier {
    let shape: S
    let fill: F
    let elevation: LFBElevation
    let pressed: Bool
    let highlight: Bool
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let e = pressed ? elevation.pressed : elevation
        content
            .background(fill, in: shape)
            .overlay {
                if highlight {
                    // Top highlight: white at about 25%, fading out by the middle of the control.
                    shape.strokeBorder(
                        LinearGradient(colors: [.white.opacity(pressed ? 0.12 : 0.25), .white.opacity(0)],
                                       startPoint: .top, endPoint: .center), lineWidth: 1)
                }
                if contrast == .increased {
                    shape.strokeBorder(Color.lfbText.opacity(0.7), lineWidth: 1.5)
                }
            }
            .shadow(color: shadow(.black, e.tightOpacity), radius: e.tightRadius, y: e.tightY)
            .shadow(color: shadow(Color(hex: "#7A3A12"), e.wideOpacity), radius: e.wideRadius, y: e.wideY)
            .scaleEffect(pressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: pressed)
    }

    private func shadow(_ c: Color, _ opacity: Double) -> Color {
        contrast == .increased ? .clear : c.opacity(scheme == .dark ? opacity * 1.6 : opacity)
    }
}

extension View {
    /// Raised control look: fill, top highlight, two-layer shadow, and a pressed state.
    func lfbDepth<S: InsettableShape, F: ShapeStyle>(_ shape: S, fill: F, elevation: LFBElevation = .low,
                                           pressed: Bool = false, highlight: Bool = true) -> some View {
        modifier(LFBDepth(shape: shape, fill: fill, elevation: elevation, pressed: pressed, highlight: highlight))
    }
}

/// The main action (Generate, Export, Save): theme accent fill. `isBusy` adds a slow breathing
/// glow while the work runs, held still under Reduce Motion.
struct LFBPrimaryButtonStyle: ButtonStyle {
    var capsule = false
    var isBusy = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.lfbTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let minH = LFBSize.isTouch ? LFBTouchSize.controlHeight : LFBSize.controlHeight
        let isEnabled = isEnabled || isBusy   // a working Generate button keeps its look
        let label = configuration.label
            .font(.lfbBodyMedium)
            .lineLimit(1)
            .foregroundStyle(isEnabled ? theme.onAccent : Color.lfbTextTertiary)
            .padding(.horizontal, 14)
            .frame(minHeight: minH)
        return Group {
            if capsule {
                label.lfbDepth(Capsule(), fill: isEnabled ? theme.accent : Color.lfbWell,
                               elevation: isEnabled ? .mid : .none, pressed: configuration.isPressed, highlight: isEnabled)
                    .contentShape(Capsule())
            } else {
                label.lfbDepth(RoundedRectangle(cornerRadius: LFBRadius.button), fill: isEnabled ? theme.accent : Color.lfbWell,
                               elevation: isEnabled ? .mid : .none, pressed: configuration.isPressed, highlight: isEnabled)
                    .contentShape(RoundedRectangle(cornerRadius: LFBRadius.button))
            }
        }
        .background { if isBusy { BreathingGlow(color: theme.accent, still: reduceMotion) } }
    }
}

private struct BreathingGlow: View {
    let color: Color
    let still: Bool
    var body: some View {
        if still {
            Capsule().fill(color.opacity(0.35)).blur(radius: 10)
        } else {
            TimelineView(.animation) { tl in
                let phase = (sin(tl.date.timeIntervalSinceReferenceDate * 2 * .pi / 2.4) + 1) / 2
                Capsule().fill(color.opacity(0.25 + 0.4 * phase)).blur(radius: 8 + 6 * phase).scaleEffect(1.05 + 0.1 * phase)
            }
        }
    }
}

/// Toggleable chip (style picker, recipe strip, options): raised when off, accent wash when on.
struct LFBChipStyle: ButtonStyle {
    var isOn = false
    var capsule = true
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.lfbTheme) private var theme

    func makeBody(configuration: Configuration) -> some View {
        let minH = LFBSize.isTouch ? LFBTouchSize.controlHeightSmall : LFBSize.controlHeightSmall
        let label = configuration.label
            .font(.lfbBodyMedium)
            .lineLimit(1)
            .foregroundStyle(isOn ? Color.lfbAccentText : Color.lfbText)
            .padding(.horizontal, 12)
            .frame(minHeight: minH)
        return Group {
            if capsule {
                label.lfbDepth(Capsule(), fill: isOn ? theme.wash : Color.lfbControl, elevation: isOn ? .none : .low,
                               pressed: configuration.isPressed, highlight: !isOn)
                    .contentShape(Capsule())
            } else {
                label.lfbDepth(RoundedRectangle(cornerRadius: LFBRadius.button), fill: isOn ? theme.wash : Color.lfbControl,
                               elevation: isOn ? .none : .low, pressed: configuration.isPressed, highlight: !isOn)
                    .contentShape(RoundedRectangle(cornerRadius: LFBRadius.button))
            }
        }
        .opacity(isEnabled ? 1 : 0.45)
    }
}

/// Icon-only button: flat at rest, a raised well under the pointer or finger when pressed.
struct LFBIconButtonStyle: ButtonStyle {
    var solid = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color.lfbTextSecondary)
            .lfbDepth(Circle(), fill: solid ? AnyShapeStyle(Color.lfbControl) : AnyShapeStyle(configuration.isPressed ? Color.lfbWell : Color.clear),
                      elevation: solid ? .low : .none, pressed: configuration.isPressed, highlight: solid)
            .contentShape(Circle())
            .opacity(isEnabled ? 1 : 0.4)
    }
}
