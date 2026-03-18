import CoreGraphics

struct PaneLayoutSizing: Equatable, Sendable {
    let horizontalInset: CGFloat
    let topInset: CGFloat
    let bottomInset: CGFloat
    let interPaneSpacing: CGFloat

    static let balanced = PaneLayoutSizing(
        horizontalInset: 0,
        topInset: 0,
        bottomInset: 0,
        interPaneSpacing: 6
    )

    static let edgeAligned = PaneLayoutSizing(
        horizontalInset: 0,
        topInset: balanced.topInset,
        bottomInset: balanced.bottomInset,
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
        max(0, containerHeight - topInset - bottomInset)
    }
}
