import CoreGraphics

struct PaneLayoutSizing: Equatable, Sendable {
    let horizontalInset: CGFloat
    let topInset: CGFloat
    let bottomInset: CGFloat
    let interPaneSpacing: CGFloat

    static let balanced = PaneLayoutSizing(
        horizontalInset: 0,
        topInset: 0,
        bottomInset: 1,
        interPaneSpacing: 6
    )

    func readableWidth(
        for containerWidth: CGFloat,
        leadingVisibleInset: CGFloat
    ) -> CGFloat {
        let available = max(0, containerWidth - (horizontalInset * 2))
        return max(0, available - max(0, leadingVisibleInset))
    }

    func paneHeight(for containerHeight: CGFloat) -> CGFloat {
        max(0, containerHeight - topInset - bottomInset)
    }
}
