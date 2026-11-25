import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: - Dynamic color

// Colors are defined here rather than in an Asset Catalog so that the exact same source file
// compiles under both build systems this project uses on one machine: `swift run` (SwiftPM,
// no compiled asset catalog reachable from a plain executable's Bundle.main) and
// `LofiBossa.xcodeproj` (a native Xcode target, which has no `Bundle.module`). A programmatic
// NSColor dynamic provider behaves identically to a colorset with light/dark variants and
// needs no resource bundle at all. Values below are the hex values from the design's
// tokens.json, carried over by hand; keep the two in sync if either changes.
extension Color {
    /// A color that resolves differently in light and dark appearance, like an Asset Catalog
    /// colorset with two variants.
    init(light: (Double, Double, Double, Double), dark: (Double, Double, Double, Double)) {
        #if os(macOS)
        func rgba(_ v: (Double, Double, Double, Double)) -> NSColor {
            NSColor(srgbRed: v.0, green: v.1, blue: v.2, alpha: v.3)
        }
        self = Color(NSColor(name: nil) { appearance in
            let match = appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua,
                                                    .accessibilityHighContrastDarkAqua])
            let isDark = match == .darkAqua || match == .accessibilityHighContrastDarkAqua
            let increased = match == .accessibilityHighContrastAqua || match == .accessibilityHighContrastDarkAqua
            return rgba(increased ? Color.increasedContrast(isDark ? dark : light, dark: isDark) : (isDark ? dark : light))
        })
        #else
        func rgba(_ v: (Double, Double, Double, Double)) -> UIColor {
            UIColor(red: v.0, green: v.1, blue: v.2, alpha: v.3)
        }
        self = Color(UIColor { traits in
            let isDark = traits.userInterfaceStyle == .dark
            let base = isDark ? dark : light
            return rgba(traits.accessibilityContrast == .high ? Color.increasedContrast(base, dark: isDark) : base)
        })
        #endif
    }

    /// The token under Increase Contrast: pushed a quarter of the way toward black (light) or
    /// white (dark), and faint hairlines made more opaque, so text and borders stand out more.
    static func increasedContrast(_ v: (Double, Double, Double, Double), dark: Bool) -> (Double, Double, Double, Double) {
        let target = dark ? 1.0 : 0.0
        let luma = 0.299 * v.0 + 0.587 * v.1 + 0.114 * v.2
        // Surfaces (light colors in light mode, dark in dark mode) stay; only foregrounds move.
        let isForeground = dark ? luma > 0.5 : luma < 0.5
        func mix(_ c: Double) -> Double { isForeground ? c + (target - c) * 0.25 : c }
        return (mix(v.0), mix(v.1), mix(v.2), v.3 < 0.5 ? min(v.3 * 2.2, 1) : v.3)
    }

    /// Convenience for a token with no separate light/dark value.
    init(hex: String, alpha: Double = 1) {
        self = Color(hex: hex).opacity(alpha)
    }

    /// `#RRGGBB` (alpha applied separately via `.opacity`, matching how the tokens are written).
    init(hex: String) {
        var s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        if s.count < 6 { s = "000000" }
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255,
                   blue: Double(v & 0xFF) / 255)
    }
}

private func hex(_ s: String, _ a: Double = 1) -> (Double, Double, Double, Double) {
    var v: UInt64 = 0
    Scanner(string: s.trimmingCharacters(in: CharacterSet(charactersIn: "#"))).scanHexInt64(&v)
    return (Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255, a)
}

// MARK: - Palette (from tokens.json)

extension Color {
    static let lfbWindow = Color(light: hex("#F5F2EC"), dark: hex("#1D1A17"))
    static let lfbSidebar = Color(light: hex("#EBE7DF"), dark: hex("#24211D"))
    static let lfbSurface = Color(light: hex("#FCFBF8"), dark: hex("#282420"))
    static let lfbRaised = Color(light: hex("#FFFFFF"), dark: hex("#342F2A"))
    static let lfbWell = Color(light: hex("#EEEAE3"), dark: hex("#171411"))
    static let lfbHairline = Color(light: hex("#2E2418", 0.11), dark: hex("#FFF0DE", 0.09))
    static let lfbControlHairline = Color(light: hex("#2E2418", 0.16), dark: hex("#FFF0DE", 0.14))
    static let lfbControl = Color(light: hex("#FFFFFF"), dark: hex("#3D3731"))

    static let lfbText = Color(light: hex("#26211C"), dark: hex("#F3EEE7"))
    static let lfbTextSecondary = Color(light: hex("#5A5249"), dark: hex("#BDB3A7"))
    static let lfbTextTertiary = Color(light: hex("#6E655B"), dark: hex("#9C9287"))

    static let lfbAccent = Color(light: hex("#C4441A"), dark: hex("#FF8D61"))
    static let lfbOnAccent = Color(light: hex("#FFFFFF"), dark: hex("#2B1206"))
    static let lfbAccentWash = Color(light: hex("#C4441A", 0.14), dark: hex("#FF8D61", 0.18))
    static let lfbAccentText = Color(light: hex("#B03A12"), dark: hex("#FF9B74"))

    static let lfbPiano = Color(light: hex("#2F55A8"), dark: hex("#7C9EF0"))
    static let lfbGuitar = Color(light: hex("#D69A14"), dark: hex("#F5C75C"))
    static let lfbBass = Color(light: hex("#D277AE"), dark: hex("#F2A7D2"))
    static let lfbDrums = Color(light: hex("#12866B"), dark: hex("#3FBF9C"))
    static let lfbKeys = Color(light: hex("#7A4FC2"), dark: hex("#B79BEF"))
    static let lfbLead = Color(light: hex("#D4552B"), dark: hex("#F59A78"))
    static let lfbVibes = Color(light: hex("#1F8CA8"), dark: hex("#6CCBE3"))
    static let lfbPianoInk = Color(light: hex("#2A4C97"), dark: hex("#7C9EF0"))
    static let lfbGuitarInk = Color(light: hex("#8A5F00"), dark: hex("#F5C75C"))
    static let lfbBassInk = Color(light: hex("#A3447D"), dark: hex("#F2A7D2"))
    static let lfbDrumsInk = Color(light: hex("#0E6E58"), dark: hex("#3FBF9C"))

    static let lfbKeysInk = Color(light: hex("#6A3FB3"), dark: hex("#B79BEF"))
    static let lfbLeadInk = Color(light: hex("#B0401A"), dark: hex("#F59A78"))
    static let lfbVibesInk = Color(light: hex("#15708A"), dark: hex("#6CCBE3"))

    static let lfbReady = Color(light: hex("#0E6E58"), dark: hex("#3FBF9C"))
    static let lfbCaution = Color(light: hex("#8A5F00"), dark: hex("#F5C75C"))
    static let lfbFailure = Color(light: hex("#B3261E"), dark: hex("#FF8A80"))
}

// MARK: - Layout

enum LFBSpace {
    static let xs: CGFloat = 4    // inside controls
    static let sm: CGFloat = 8    // between controls
    static let md: CGFloat = 12   // panel padding
    static let lg: CGFloat = 16   // bar padding
    static let xl: CGFloat = 24   // between groups
}

enum LFBRadius {
    static let key: CGFloat = 5        // M / S buttons
    static let button: CGFloat = 7
    static let segmented: CGFloat = 8
    static let banner: CGFloat = 10
    static let card: CGFloat = 12      // library cards, effect cards, sheets
}

enum LFBSize {
    static let trackHeaderWidth: CGFloat = 232
    static let trackRowMinHeight: CGFloat = 92
    static let trackRowCompactHeight: CGFloat = 44   // while the piano roll is open
    static let rulerHeight: CGFloat = 24
    static let transportHeight: CGFloat = 56
    static let toolbarHeight: CGFloat = 52
    static let recipeBarHeight: CGFloat = 49
    static let inspectorWidth: CGFloat = 272
    static let sidebarWidth: CGFloat = 216
    static let controlHeight: CGFloat = 28
    static let controlHeightSmall: CGFloat = 24
    static let playButton: CGFloat = 36
    static let effectCardHeight: CGFloat = 64
    static let libraryCardThumbHeight: CGFloat = 112
    static let minWindow = CGSize(width: 960, height: 560)
}

/// Touch sizes (tokens.json `sizeTouch`, `sizePhone`, `devices`). Additions only: `LFBSize`
/// above stays the Mac's pointer sizes, so nothing on the Mac changes. iPad uses the Mac layout
/// with `LFBTouchSize` values (HANDOFF §4); iPhone and the iPhone Duo use `LFBPhoneSize` (§5, §6).
extension LFBSize {
    #if os(macOS)
    static let isTouch = false
    #else
    static let isTouch = true
    #endif
}

/// iPad: the Mac layout, touch-sized (tokens.json `sizeTouch`).
enum LFBTouchSize {
    static let controlHeight: CGFloat = 36
    static let controlHeightSmall: CGFloat = 32
    static let keyMS = CGSize(width: 36, height: 32)          // M / S keys (Mac: 24 × 22)
    static let trackHeaderWidth: CGFloat = 264
    static let trackRowMinHeight: CGFloat = 112
    static let transportHeight: CGFloat = 76
    static let playButton: CGFloat = 52
    static let inspectorWidth: CGFloat = 320
    static let sidebarWidth: CGFloat = 300
    static let sliderThumb: CGFloat = 24
    static let effectCardHeight: CGFloat = 76
    static let topInset: CGFloat = 24                         // status bar, no window chrome
}

/// iPhone and iPhone Duo (tokens.json `sizePhone`).
enum LFBPhoneSize {
    static let navBar: CGFloat = 44
    static let chipHeight: CGFloat = 36
    static let cardRadius: CGFloat = 18
    static let cardHeader: CGFloat = 40
    static let keyMS = CGSize(width: 40, height: 36)          // drawn size; hit area padded to 44
    static let minHitTarget: CGFloat = 44
    static let laneRadius: CGFloat = 10
    static let transportRadius: CGFloat = 26
    static let playButton: CGFloat = 56
    static let playButtonShort: CGFloat = 48
    static let sheetRadius: CGFloat = 34
    static let listRow: CGFloat = 50
    static let bigButton: CGFloat = 52
    static let pianoRowHeight: CGFloat = 18
    static let pianoRowHeightLandscape: CGFloat = 12
    static let pianoKeyColumn: CGFloat = 40
    /// Below this height (the Duo's outer display) the short variant applies (`.m-short`).
    static let shortVariantBelowHeight: CGFloat = 760
    /// Kept clear around the fold on the Duo's inner display; nothing interactive spans it.
    static let foldGap: CGFloat = 24

    /// Safe-area insets the artboards were drawn with. The system supplies the real ones; use
    /// these only to match the artboards, never to lay out around hardware.
    enum ArtboardInsets {
        static let iphonePortrait = (top: CGFloat(62), bottom: CGFloat(34))
        static let iphoneLandscape = (sides: CGFloat(59), bottom: CGFloat(21))
        static let duoOuter = (top: CGFloat(44), bottom: CGFloat(16))
    }
}

/// Artboard sizes in points (tokens.json `devices`). Layouts flex; read sizes at runtime. The
/// Duo sizes are unconfirmed third-party arithmetic (HANDOFF §3).
enum LFBDevice {
    static let iphone = CGSize(width: 402, height: 874)
    static let ipad11 = CGSize(width: 1194, height: 834)
    static let duoOuter = CGSize(width: 466, height: 678)
    static let duoInner = CGSize(width: 890, height: 626)
}

// MARK: - Type
// Rounded design for titles and numerals, default SF Pro for everything else.

extension Font {
    static let lfbLargeTitle = lfbText(26, .bold, .rounded, .largeTitle)
    static let lfbTitle = lfbText(17, .semibold, .rounded, .title3)
    static let lfbHeadline = lfbText(14, .semibold, .rounded, .headline)
    static let lfbBody = lfbText(13, .regular, .default, .body)
    static let lfbBodyMedium = lfbText(13, .medium, .default, .body)
    static let lfbCaption = lfbText(11, .medium, .default, .caption1)
    static let lfbTimecode = lfbText(20, .semibold, .rounded, .title3).monospacedDigit()

    /// The design's fixed size on the Mac; on iOS the same size scaled by the user's Dynamic Type
    /// setting (read when the app starts, capped so the layouts stay usable at the largest sizes).
    private static func lfbText(_ size: CGFloat, _ weight: Font.Weight, _ design: Font.Design,
                                _ style: LFBTextStyle) -> Font {
        #if os(iOS)
        var base = UIFont.systemFont(ofSize: size, weight: UIFont.Weight(rawValue: weightValue(weight)))
        if design == .rounded, let rounded = base.fontDescriptor.withDesign(.rounded) {
            base = UIFont(descriptor: rounded, size: size)
        }
        return Font(UIFontMetrics(forTextStyle: style).scaledFont(for: base, maximumPointSize: size * 1.6))
        #else
        return Font.system(size: size, weight: weight, design: design)
        #endif
    }

    #if os(iOS)
    private static func weightValue(_ w: Font.Weight) -> CGFloat {
        switch w {
        case .bold: UIFont.Weight.bold.rawValue
        case .semibold: UIFont.Weight.semibold.rawValue
        case .medium: UIFont.Weight.medium.rawValue
        default: UIFont.Weight.regular.rawValue
        }
    }
    #endif
}

// MARK: - Motion

enum LFBMotion {
    static let sweepSeconds: Double = 1.8
    static let writeHeadPulseSeconds: Double = 1.2
    static let spinnerSeconds: Double = 0.8
}

#if os(iOS)
typealias LFBTextStyle = UIFont.TextStyle
#else
/// On the Mac the sizes are fixed, so the text style is only a name.
enum LFBTextStyle { case largeTitle, title3, headline, body, caption1 }
#endif
