import CoreGraphics

struct PaneLayoutSizing: Equatable, Sendable {
    let defaultPaneWidthRatio: CGFloat
    let minimumPaneWidth: CGFloat
    let maximumPaneWidth: CGFloat
    let horizontalInset: CGFloat
    let verticalInset: CGFloat
    let interPaneSpacing: CGFloat

    static let balanced = PaneLayoutSizing(
        defaultPaneWidthRatio: 0.34,
        minimumPaneWidth: 280,
        maximumPaneWidth: 520,
        horizontalInset: 8,
        verticalInset: 8,
        interPaneSpacing: 10
    )

    func paneWidth(for containerWidth: CGFloat) -> CGFloat {
        let available = max(0, containerWidth - (horizontalInset * 2))
        return clamp(
            available * defaultPaneWidthRatio,
            min: minimumPaneWidth,
            max: maximumPaneWidth
        )
    }

    func paneHeight(for containerHeight: CGFloat) -> CGFloat {
        max(0, containerHeight - (verticalInset * 2))
    }

    private func clamp(_ value: CGFloat, min minimum: CGFloat, max maximum: CGFloat) -> CGFloat {
        Swift.min(Swift.max(value, minimum), maximum)
    }
}
