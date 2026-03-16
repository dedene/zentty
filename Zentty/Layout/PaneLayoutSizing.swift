import CoreGraphics

struct PaneLayoutSizing: Equatable, Sendable {
    let horizontalInset: CGFloat
    let verticalInset: CGFloat
    let interPaneSpacing: CGFloat

    static let balanced = PaneLayoutSizing(
        horizontalInset: 8,
        verticalInset: 0,
        interPaneSpacing: 10
    )

    func readableWidth(
        for containerWidth: CGFloat,
        leadingVisibleInset: CGFloat
    ) -> CGFloat {
        let available = max(0, containerWidth - (horizontalInset * 2))
        return max(0, available - max(0, leadingVisibleInset))
    }

    func paneHeight(for containerHeight: CGFloat) -> CGFloat {
        max(0, containerHeight - (verticalInset * 2))
    }
}
