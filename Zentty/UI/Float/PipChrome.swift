import CoreGraphics

/// Pure geometry and wording of a PiP's own chrome, drawn unscaled on top of
/// the scaled terminal: the bottom status strip, the hover legend on the top
/// border, and the needs-input ring. Coordinates are the PiP's y-up bounds.
enum PipChrome {
    /// Bottom overlay strip: status dot + name + status word.
    static let statusStripHeight: CGFloat = 18
    static let statusHorizontalPadding: CGFloat = 7
    static let statusDotSize: CGFloat = 7
    static let statusGap: CGFloat = 5
    /// The legend's trailing inset from the PiP's right edge.
    static let legendTrailingInset: CGFloat = 12
    /// Corner radius of the PiP picture.
    static let cornerRadius: CGFloat = 8
    /// Needs input: an amber ring just outside the edge plus a soft glow.
    static let ringWidth: CGFloat = 1
    static let glowRadius: CGFloat = 11
    static let glowOpacity: Float = 0.45
    /// Drop shadow at rest and while dragged (y-up: negative drops it below).
    static let restingShadow = FloatShadowStyle.Layer(offsetY: -14, radius: 18, opacity: 0.55)
    static let liftedShadow = FloatShadowStyle.Layer(offsetY: -24, radius: 30, opacity: 0.65)
    /// A dragged PiP is drawn this much larger.
    static let liftScale: CGFloat = 1.06

    /// The right-legend buttons a PiP shows on hover.
    static var actions: [PaneBorderAction] {
        PaneBorderActionsLayout.actions(for: .pip)
    }

    static func statusStripFrame(in bounds: CGRect) -> CGRect {
        CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: min(statusStripHeight, bounds.height))
    }

    /// Right-aligned, centred on the top edge (half of it sits outside).
    static func legendFrame(in bounds: CGRect) -> CGRect {
        let size = PaneBorderActionsLayout.size(for: actions)
        return CGRect(
            x: bounds.maxX - legendTrailingInset - size.width,
            y: bounds.maxY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    /// Where the pointer counts as "over the PiP": its bounds plus the half
    /// of the legend that sticks out above it.
    static func hoverRect(in bounds: CGRect) -> CGRect {
        bounds.union(legendFrame(in: bounds))
    }

    static func showsRing(for status: PillBarItem?) -> Bool {
        status?.attention == .needsInput
    }

    /// "<name>, <status>, picture in picture".
    static func accessibilityLabel(for status: PillBarItem?) -> String {
        guard let status else { return "Picture in picture" }
        return [status.name, status.statusWord, "picture in picture"].compactMap { $0 }.joined(separator: ", ")
    }
}
