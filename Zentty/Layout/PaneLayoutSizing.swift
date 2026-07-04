import CoreGraphics

struct PaneLayoutSizing: Equatable, Sendable {
    let horizontalInset: CGFloat
    let topInset: CGFloat
    let bottomInset: CGFloat
    let interPaneSpacing: CGFloat

    static let balanced = PaneLayoutSizing(
        horizontalInset: 0,
        topInset: 2,
        bottomInset: 0,
        interPaneSpacing: 6
    )

    static let edgeAligned = PaneLayoutSizing(
        horizontalInset: balanced.horizontalInset,
        topInset: balanced.topInset,
        bottomInset: balanced.bottomInset,
        interPaneSpacing: balanced.interPaneSpacing
    )

    static let borderless = PaneLayoutSizing(
        horizontalInset: edgeAligned.horizontalInset,
        topInset: edgeAligned.topInset,
        bottomInset: edgeAligned.bottomInset,
        interPaneSpacing: 2
    )

    static let collapsedSidebar = edgeAligned

    static func forSidebarVisibility(
        _ visibility: SidebarVisibilityMode,
        showPaneBorders: Bool
    ) -> PaneLayoutSizing {
        _ = visibility
        return showPaneBorders ? .edgeAligned : .borderless
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
