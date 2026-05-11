import AppKit

#if DEBUG
struct SidebarViewDebugSnapshot {
    let renderInvocationCount: Int
    let reorderPreviewLastAnimationDuration: TimeInterval?
    let worklaneButtons: [NSButton]
    let arrangedWorklaneIDs: [WorklaneID]
    let reorderSpacerHeight: CGFloat
    let worklaneRowFramesForReordering: [(WorklaneID, CGRect)]
    let resizeHandleWidth: CGFloat
    let appearanceMatch: NSAppearance.Name?
    let shimmerDriverIsRunning: Bool
    let isUpdateRowHidden: Bool
    let updateAvailableRowHeight: CGFloat
}

enum SidebarViewDebugAction {
    case setAddWorklaneHovered(Bool)
    case updateShimmerVisibility
    case performUpdateAvailableRowClick
}

@MainActor
struct SidebarViewDebugAccess {
    let sidebarView: SidebarView
    let renderInvocationCount: Int
    let reorderPreviewLastAnimationDuration: TimeInterval?
    let worklaneButtons: [SidebarWorklaneRowButton]
    let worklaneSummaries: [WorklaneSidebarSummary]
    let listStack: NSStackView
    let reorderSpacerView: SidebarReorderSpacerView?
    let resizeHandleView: SidebarResizeHandleView
    let updateAvailableRowView: SidebarUpdateAvailableRowView
    let addWorklaneButton: SidebarCreateWorklaneButton
    let addWorklaneWidthConstraintConstant: CGFloat
    let headerView: NSView
    let listScrollView: NSScrollView
    let appearance: NSAppearance?
    let shimmerDriverIsRunning: Bool
    let performAction: (SidebarViewDebugAction) -> Void

    var snapshot: SidebarViewDebugSnapshot {
        SidebarViewDebugSnapshot(
            renderInvocationCount: renderInvocationCount,
            reorderPreviewLastAnimationDuration: reorderPreviewLastAnimationDuration,
            worklaneButtons: worklaneButtons,
            arrangedWorklaneIDs: listStack.arrangedSubviews.compactMap { view in
                (view as? SidebarWorklaneRowButton)?.worklaneID
            },
            reorderSpacerHeight: reorderSpacerView?.spacerHeight ?? 0,
            worklaneRowFramesForReordering: sidebarView.worklaneRowFramesForReordering(),
            resizeHandleWidth: resizeHandleView.frame.width,
            appearanceMatch: appearance?.bestMatch(from: [.darkAqua, .aqua]),
            shimmerDriverIsRunning: shimmerDriverIsRunning,
            isUpdateRowHidden: updateAvailableRowView.isHidden,
            updateAvailableRowHeight: updateAvailableRowView.frame.height
        )
    }

    func listStackHasConstraintsReferencingView(_ view: NSView) -> Bool {
        listStack.constraints.contains { constraint in
            (constraint.firstItem as AnyObject?) === view
                || (constraint.secondItem as AnyObject?) === view
        }
    }

    var firstWorklaneButton: SidebarWorklaneRowButton? {
        worklaneButtons.first
    }

    var firstWorklaneFrameInSidebar: CGRect? {
        firstWorklaneButton.map { sidebarView.convert($0.bounds, from: $0) }
    }

    var addWorklaneFrameInSidebar: CGRect {
        sidebarView.convert(addWorklaneButton.bounds, from: addWorklaneButton)
    }
}

@MainActor
extension SidebarView {
    var worklanePrimaryTexts: [String] {
        debugAccessForTesting.worklaneSummaries.map(\.primaryText)
    }

    var worklaneContextTexts: [String] {
        debugAccessForTesting.worklaneSummaries.map(\.contextText)
    }

    var debugSnapshotForTesting: SidebarViewDebugSnapshot {
        debugAccessForTesting.snapshot
    }

    func debugListStackHasConstraintsReferencingView(_ view: NSView) -> Bool {
        debugAccessForTesting.listStackHasConstraintsReferencingView(view)
    }

    var addWorklaneTitle: String {
        debugAccessForTesting.addWorklaneButton.titleText
    }

    var isHeaderHidden: Bool {
        debugAccessForTesting.headerView.isHidden
    }

    var hasVisibleDivider: Bool {
        false
    }

    var firstWorklaneTopInset: CGFloat {
        guard let frame = debugAccessForTesting.firstWorklaneFrameInSidebar else {
            return .greatestFiniteMagnitude
        }

        return debugAccessForTesting.listScrollView.frame.maxY - frame.maxY
    }

    var firstWorklaneMinY: CGFloat {
        debugAccessForTesting.firstWorklaneFrameInSidebar?.minY ?? 0
    }

    var firstWorklaneMaxY: CGFloat {
        debugAccessForTesting.firstWorklaneFrameInSidebar?.maxY ?? 0
    }

    var addWorklaneMinY: CGFloat {
        debugAccessForTesting.addWorklaneFrameInSidebar.minY
    }

    var addWorklaneMaxY: CGFloat {
        debugAccessForTesting.addWorklaneFrameInSidebar.maxY
    }

    var addWorklaneButtonMinX: CGFloat {
        debugAccessForTesting.addWorklaneFrameInSidebar.minX
    }

    var addWorklaneButtonWidth: CGFloat {
        debugAccessForTesting.addWorklaneFrameInSidebar.width
    }

    var addWorklaneButtonMidY: CGFloat {
        debugAccessForTesting.addWorklaneFrameInSidebar.midY
    }

    var firstWorklaneWidth: CGFloat {
        debugAccessForTesting.firstWorklaneFrameInSidebar?.width ?? 0
    }

    var firstWorklanePrimaryMinX: CGFloat {
        debugAccessForTesting.firstWorklaneButton?.primaryMinX(in: self) ?? 0
    }

    var secondWorklanePrimaryMinX: CGFloat {
        let buttons = debugAccessForTesting.worklaneButtons
        guard buttons.count > 1 else {
            return 0
        }

        return buttons[1].primaryMinX(in: self)
    }

    var worklaneDetailTexts: [[String]] {
        debugAccessForTesting.worklaneButtons.map(\.debugSnapshotForTesting.detailTexts)
    }

    var worklaneOverflowTexts: [String] {
        debugAccessForTesting.worklaneButtons.map(\.debugSnapshotForTesting.overflowText)
    }

    var addWorklaneContentMinX: CGFloat {
        debugAccessForTesting.addWorklaneButton.contentMinX(in: self)
    }

    var addWorklaneWidthConstraintConstant: CGFloat {
        debugAccessForTesting.addWorklaneWidthConstraintConstant
    }

    var addWorklaneContentMidX: CGFloat {
        debugAccessForTesting.addWorklaneButton.contentMidX(in: self)
    }

    var addWorklaneIconAlpha: CGFloat {
        debugAccessForTesting.addWorklaneButton.iconAlpha
    }

    var addWorklaneTitleAlpha: CGFloat {
        debugAccessForTesting.addWorklaneButton.titleAlpha
    }

    var addWorklaneBackgroundAlpha: CGFloat {
        debugAccessForTesting.addWorklaneButton.backgroundAlpha
    }

    var addWorklaneBorderAlpha: CGFloat {
        debugAccessForTesting.addWorklaneButton.borderAlpha
    }

    var addWorklaneUsesPointingHandCursor: Bool {
        debugAccessForTesting.addWorklaneButton.usesPointingHandCursorForTesting
    }

    var addWorklaneToolTipForTesting: String {
        debugAccessForTesting.addWorklaneButton.toolTip ?? ""
    }

    var bookmarksToolTipForTesting: String {
        debugAccessForTesting.sidebarView.bookmarksButtonAnchor.toolTip ?? ""
    }

    var resizeHandleMinX: CGFloat {
        debugAccessForTesting.resizeHandleView.frame.minX
    }

    var resizeHandleMaxX: CGFloat {
        debugAccessForTesting.resizeHandleView.frame.maxX
    }

    var resizeHandleFillAlpha: CGFloat {
        debugAccessForTesting.resizeHandleView.fillAlpha
    }

    var isResizeHandleHidden: Bool {
        debugAccessForTesting.resizeHandleView.isHidden
    }

    var trailingEdgeHitTargetsResizeHandle: Bool {
        hitTest(NSPoint(x: bounds.maxX - 1, y: bounds.midY)) === debugAccessForTesting.resizeHandleView
    }

    func hitTargetsResizeHandle(atX x: CGFloat) -> Bool {
        hitTest(NSPoint(x: x, y: bounds.midY)) === debugAccessForTesting.resizeHandleView
    }

    var isUpdateAvailableRowVisible: Bool {
        !debugAccessForTesting.updateAvailableRowView.isHidden
    }

    func performDebugActionForTesting(_ action: SidebarViewDebugAction) {
        debugAccessForTesting.performAction(action)
    }
}
#endif
