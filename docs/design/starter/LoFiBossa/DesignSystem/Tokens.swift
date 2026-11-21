import SwiftUI

// MARK: - Color
// Every color is an Asset Catalog color set with light and dark appearances,
// so SwiftUI switches automatically. Values live in Assets.xcassets and tokens.json.

extension Color {
    static let lfbWindow = Color("Window")
    static let lfbSidebar = Color("Sidebar")
    static let lfbSurface = Color("Surface")
    static let lfbRaised = Color("Raised")
    static let lfbWell = Color("Well")
    static let lfbHairline = Color("Hairline")
    static let lfbControlHairline = Color("ControlHairline")
    static let lfbControl = Color("Control")

    static let lfbText = Color("TextPrimary")
    static let lfbTextSecondary = Color("TextSecondary")
    static let lfbTextTertiary = Color("TextTertiary")

    static let lfbAccent = Color("AccentColor")
    static let lfbOnAccent = Color("OnAccent")
    static let lfbAccentWash = Color("AccentWash")
    static let lfbAccentText = Color("AccentText")

    static let lfbReady = Color("Ready")
    static let lfbCaution = Color("Caution")
    static let lfbFailure = Color("Failure")
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

/// Pointer (Mac) and touch (iPad, iPhone, iPhone Duo) sizes. Same layout, larger targets on touch.
enum LFBSize {
    #if os(macOS)
    static let isTouch = false
    #else
    static let isTouch = true
    #endif

    static let trackHeaderWidth: CGFloat = isTouch ? 264 : 232     // Mac and iPad track rows
    static let trackRowMinHeight: CGFloat = isTouch ? 112 : 92
    static let trackRowCompactHeight: CGFloat = isTouch ? 52 : 44   // while the piano roll is open
    static let rulerHeight: CGFloat = 24
    static let transportHeight: CGFloat = isTouch ? 76 : 56
    static let inspectorWidth: CGFloat = isTouch ? 320 : 272
    static let controlHeight: CGFloat = isTouch ? 36 : 28
    static let effectCardHeight: CGFloat = isTouch ? 76 : 64
    static let keySize = isTouch ? CGSize(width: 36, height: 32) : CGSize(width: 24, height: 22)   // M / S
    static let minWindow = CGSize(width: 900, height: 560)                                         // Mac only

    // iPhone and iPhone Duo
    static let cardRadius: CGFloat = 18
    static let phoneKey = CGSize(width: 40, height: 36)    // drawn size; hit area is padded to 44
    static let playButtonPhone: CGFloat = 56
    static let foldGap: CGFloat = 24                         // kept clear on the Duo's inner display
    static let pianoRowHeightPhone: CGFloat = 18
    static let pianoRowHeightPointer: CGFloat = 12
}

// MARK: - Type
// Rounded design for titles and numerals, default SF Pro for everything else.

extension Font {
    static let lfbLargeTitle = Font.system(size: 26, weight: .bold, design: .rounded)
    static let lfbTitle = Font.system(size: 17, weight: .semibold, design: .rounded)
    static let lfbHeadline = Font.system(size: 14, weight: .semibold, design: .rounded)
    static let lfbBody = Font.system(size: 13)
    static let lfbCaption = Font.system(size: 11, weight: .medium)
    static let lfbTimecode = Font.system(size: 20, weight: .semibold, design: .rounded).monospacedDigit()
}
