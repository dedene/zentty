import CoreGraphics

struct PaneLayoutSizing: Equatable, Sendable {
    let defaultPaneWidthRatio: CGFloat
    let minimumPaneWidth: CGFloat
    let maximumPaneWidth: CGFloat
    let horizontalInset: CGFloat
    let verticalInset: CGFloat
    let interPaneSpacing: CGFloat

    static let balanced = PaneLayoutSizing(
        defaultPaneWidthRatio: 0.5,
        minimumPaneWidth: 280,
        maximumPaneWidth: .greatestFiniteMagnitude,
        horizontalInset: 8,
        verticalInset: 8,
        interPaneSpacing: 10
    )

    func standardColumnWidth(for containerWidth: CGFloat) -> CGFloat {
        let available = max(0, containerWidth - (horizontalInset * 2))
        let effectiveAvailable = max(0, available - interPaneSpacing)

        return clamp(
            effectiveAvailable * defaultPaneWidthRatio,
            min: minimumPaneWidth,
            max: min(maximumPaneWidth, available)
        )
    }

    func leadingReadableWidth(
        for containerWidth: CGFloat,
        leadingVisibleInset: CGFloat
    ) -> CGFloat {
        let available = max(0, containerWidth - (horizontalInset * 2))
        let readableWidth = max(0, available - max(0, leadingVisibleInset))
        return clamp(
            readableWidth,
            min: minimumPaneWidth,
            max: min(maximumPaneWidth, available)
        )
    }

    func paneHeight(for containerHeight: CGFloat) -> CGFloat {
        max(0, containerHeight - (verticalInset * 2))
    }

    private func clamp(_ value: CGFloat, min minimum: CGFloat, max maximum: CGFloat) -> CGFloat {
        Swift.min(Swift.max(value, minimum), maximum)
    }
}
