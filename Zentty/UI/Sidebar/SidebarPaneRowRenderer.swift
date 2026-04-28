import AppKit

@MainActor
final class SidebarPaneRowRenderer {
    struct Callbacks {
        var onPaneSelected: ((PaneID) -> Void)?
        var onCloseWorklaneRequested: ((PaneID) -> Void)?
        var onClosePaneRequested: ((PaneID) -> Void)?
        var onSplitHorizontalRequested: ((PaneID) -> Void)?
        var onSplitVerticalRequested: ((PaneID) -> Void)?
        var onWorklaneColorChanged: ((WorklaneColor?) -> Void)?
        var onHoverChanged: ((Bool) -> Void)?
    }

    private(set) var panePrimaryRows: [SidebarPanePrimaryRowView] = []
    private(set) var paneDetailLabels: [SidebarStaticLabel] = []
    private(set) var paneStatusRows: [SidebarPaneTextRowView] = []
    private(set) var paneRowButtons: [SidebarPaneRowButton] = []
    private(set) var paneRowContainers: [SidebarInsetContainerView] = []

    private let paneWrapperInset: CGFloat

    init(paneWrapperInset: CGFloat) {
        self.paneWrapperInset = paneWrapperInset
    }

    func setShimmerCoordinator(_ coordinator: SidebarShimmerCoordinator?) {
        panePrimaryRows.forEach { $0.setShimmerCoordinator(coordinator) }
        paneStatusRows.forEach { $0.setShimmerCoordinator(coordinator) }
    }

    func setShimmerVisibility(_ isVisible: Bool) {
        panePrimaryRows.forEach { $0.setShimmerVisibility(isVisible) }
        paneStatusRows.forEach { $0.setShimmerVisibility(isVisible) }
    }

    func setVolatilePaneTitle(paneID: PaneID, text: String, paneRows: [WorklaneSidebarPaneRow]) {
        guard let rowIndex = paneRows.firstIndex(where: { $0.paneID == paneID }),
              panePrimaryRows.indices.contains(rowIndex)
        else {
            return
        }
        panePrimaryRows[rowIndex].setPrimaryText(text)
    }

    func configure(
        panePresentations: [SidebarWorklaneRowPresentation.PaneRow],
        animated: Bool,
        worklaneColor: WorklaneColor?,
        referenceWidthView: NSView,
        callbacks: Callbacks
    ) {
        ensureCapacity(panePresentations.count, referenceWidthView: referenceWidthView)

        for (index, panePresentation) in panePresentations.enumerated() {
            let paneRow = panePresentation.row
            let panePhaseOffset = SidebarShimmerPhaseOffset.forIdentifier(paneRow.paneID.rawValue)

            panePrimaryRows[index].configure(
                primaryText: paneRow.primaryText,
                trailingText: panePresentation.presentationMode == .inline ? paneRow.trailingText : nil,
                presentationMode: panePresentation.presentationMode,
                lineCount: 1
            )
            panePrimaryRows[index].setShimmerPhaseOffset(panePhaseOffset)

            paneDetailLabels[index].stringValue = paneRow.detailText ?? ""

            paneStatusRows[index].configure(
                text: panePresentation.statusDisplayText,
                symbolName: panePresentation.statusSymbolName,
                taskProgress: paneRow.taskProgress,
                trailingText: panePresentation.statusTrailingLayout.isVisible ? paneRow.trailingText : nil,
                trailingWidth: panePresentation.statusTrailingLayout.width,
                lineCount: panePresentation.statusLineCount,
                animated: animated
            )
            paneStatusRows[index].setShimmerPhaseOffset(panePhaseOffset)

            let button = paneRowButtons[index]
            button.paneID = paneRow.paneID
            button.isLastPaneInWorklane = panePresentations.count == 1
            button.currentWorklaneColor = worklaneColor
            button.setAccessibilityLabel(paneRow.primaryText)
            button.onPaneClicked = callbacks.onPaneSelected
            button.onCloseWorklane = callbacks.onCloseWorklaneRequested
            button.onClosePane = callbacks.onClosePaneRequested
            button.onSplitHorizontal = callbacks.onSplitHorizontalRequested
            button.onSplitVertical = callbacks.onSplitVerticalRequested
            button.onPickWorklaneColor = { _, color in
                callbacks.onWorklaneColorChanged?(color)
            }
            button.onHoverChanged = callbacks.onHoverChanged
        }
    }

    private func ensureCapacity(_ count: Int, referenceWidthView: NSView) {
        while panePrimaryRows.count < count {
            panePrimaryRows.append(SidebarPanePrimaryRowView())
        }

        while paneDetailLabels.count < count {
            let label = SidebarStaticLabel()
            configureLabel(
                label,
                font: ShellMetrics.sidebarDetailFont(),
                lineBreakMode: .byTruncatingMiddle
            )
            paneDetailLabels.append(label)
        }

        while paneStatusRows.count < count {
            paneStatusRows.append(
                SidebarPaneTextRowView(
                    font: ShellMetrics.sidebarStatusFont(),
                    lineHeight: ShellMetrics.sidebarStatusLineHeight
                )
            )
        }

        while paneRowButtons.count < count {
            let button = SidebarPaneRowButton()
            paneRowButtons.append(button)
            paneRowContainers.append(
                SidebarInsetContainerView(
                    contentView: button,
                    horizontalInset: paneWrapperInset,
                    referenceWidthView: referenceWidthView
                )
            )
        }
    }

    private func configureLabel(
        _ label: NSTextField,
        font: NSFont,
        lineBreakMode: NSLineBreakMode
    ) {
        label.font = font
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = lineBreakMode
        label.maximumNumberOfLines = 1
        label.cell?.truncatesLastVisibleLine = true
        label.cell?.usesSingleLineMode = true
        label.translatesAutoresizingMaskIntoConstraints = false
    }
}
