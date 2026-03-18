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

    static let edgeAligned = PaneLayoutSizing(
        horizontalInset: 0,
        verticalInset: balanced.verticalInset,
        interPaneSpacing: balanced.interPaneSpacing
    )

    static let collapsedSidebar = edgeAligned

    static func forSidebarVisibility(_ visibility: SidebarVisibilityMode) -> PaneLayoutSizing {
        _ = visibility
        return .edgeAligned
    }

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
