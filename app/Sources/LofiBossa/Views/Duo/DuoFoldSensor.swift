#if os(iOS)
import SwiftUI

/// Reads the iPhone Duo's fold and hands it to `LayoutModeReader` as a `FoldInfo`
/// (docs/design/HANDOFF.md §6.4). Uses the shipping iOS 27.1 SwiftUI APIs:
///
/// - `onHingeChange(isEnabled:_:)` → `DeviceHingeContext.hinge?.status` (closed, partially open,
///   fully open). The status decides "half folded", not an angle threshold, as Apple advises.
/// - `GeometryProxy.reservedRegions(kind: .division)` → where the fold runs. Its shape gives
///   the axis (taller than wide = vertical, the book posture) and its frame lets the two-page
///   layout centre its gap on the fold.
///
/// On iOS 27.0, or on any device without a hinge, it reports nothing and the size class
/// decides the layout. `--layout twoPage|tabletop` still forces a Duo layout on any simulator,
/// and `--log-fold` prints what was sensed (`DUOFOLD …`) for checking on the Duo simulator.
struct DuoFoldSensor: ViewModifier {
    @Binding var fold: FoldInfo?

    enum HingeStatus: String { case closed, partiallyOpen, fullyOpen }

    @State private var hinge: HingeStatus?
    @State private var divisions: [CGRect] = []

    func body(content: Content) -> some View {
        if #available(iOS 27.1, *) {
            content
                .onHingeChange { _, new in
                    hinge = new.hinge.map(Self.status)
                    update()
                }
                .onGeometryChange(for: [CGRect].self) { proxy in
                    let origin = proxy.frame(in: .global).origin
                    return proxy.reservedRegions(kind: .division)
                        .filter(\.isActive)
                        .map { $0.frame.offsetBy(dx: origin.x, dy: origin.y) }
                } action: { regions in
                    divisions = regions
                    update()
                }
        } else {
            content
        }
    }

    @available(iOS 27.1, *)
    private static func status(_ hinge: DeviceHinge) -> HingeStatus {
        switch hinge.status {
        case .closed: .closed
        case .partiallyOpen: .partiallyOpen
        default: .fullyOpen
        }
    }

    private func update() {
        let new = Self.foldInfo(hinge: hinge, divisions: divisions)
        if CommandLine.arguments.contains("--log-fold") {
            print("DUOFOLD hinge=\(hinge?.rawValue ?? "none") divisions=\(divisions) -> \(String(describing: new))")
        }
        if new != fold { fold = new }
    }

    /// Pure mapping, kept separate so it reads as the rule in HANDOFF §2.1.
    static func foldInfo(hinge: HingeStatus?, divisions: [CGRect]) -> FoldInfo? {
        guard hinge != .closed, let division = divisions.first else { return nil }
        let axis: FoldInfo.Axis = division.height >= division.width ? .vertical : .horizontal
        return FoldInfo(axis: axis, isHalfFolded: hinge == .partiallyOpen, frame: division)
    }
}
#endif
