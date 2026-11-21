#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The system clipboard on every platform (NSPasteboard on Mac, UIPasteboard on iOS).
enum Pasteboard {
    static func copy(_ string: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        #else
        UIPasteboard.general.string = string
        #endif
    }
}
