import SwiftUI

/// Small style shims for controls that only exist on one platform, so shared views keep a
/// single code path.
extension View {
    /// A checkbox on the Mac; a switch on iOS, which has no checkbox.
    func checkboxToggleStyle() -> some View {
        #if os(macOS)
        toggleStyle(.checkbox)
        #else
        toggleStyle(.switch)
        #endif
    }
}
