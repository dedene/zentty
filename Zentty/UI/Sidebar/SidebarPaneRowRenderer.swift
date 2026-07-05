import AppKit

@MainActor
final class SidebarPaneRowRenderer {
    struct Callbacks {
        var onPaneSelected: ((PaneID) -> Void)?
        var onCloseWorklaneRequested: (() -> Void)?
        var onRenameWorklaneRequested: (() -> Void)?
        var onClosePaneRequested: ((PaneID) -> Void)?
        var onSplitHorizontalRequested: ((PaneID) -> Void)?
        var onSplitVerticalRequested: ((PaneID) -> Void)?
        var onAddPaneLeftRequested: ((PaneID) -> Void)?
        var onForceSplitRightRequested: ((PaneID) -> Void)?
        var onForceAddPaneRightRequested: ((PaneID) -> Void)?
        var onMovePaneToNewWindowRequested: ((PaneID) -> Void)?
        var onRunRestoredCommandRequested: ((PaneID) -> Void)?
        var onWorklaneColorChanged: ((WorklaneColor?) -> Void)?
        var onBookmarkAction: ((SidebarBookmarkRowAction) -> Void)?
        var bookmarkOriginID: UUID?
        var bookmarkNameLookup: ((UUID) -> String?)?
        var onWorklaneDragRequested: ((NSEvent) -> Bool)?
        var onHoverChanged: ((Bool) -> Void)?
        var isOnlyWorklane = false
        var worklaneMoveAvailability: SidebarWorklaneMoveAvailability = .none
        var onMoveWorklaneRequested: ((SidebarWorklaneMoveDirection) -> Void)?
        var rightPaneCommandPresentationProvider: (() -> PaneRightCommandPresentation)?
        var moveToWorklaneCatalogProvider: ((PaneID) -> WorklaneDestinationCatalog?)?
        var onServerPortSelected: ((String) -> Void)?
        var restoredRerunnableCommandProvider: ((PaneID) -> String?)?
    }

    private(set) var panePrimaryRows: [SidebarPanePrimaryRowView] = []
    private(set) var paneDetailLabels: [SidebarStaticLabel] = []
    private(set) var paneStatusRows: [SidebarPaneTextRowView] = []
    private(set) var paneServerRows: [SidebarPaneServerRowView] = []
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

    func setWorklaneMoveAvailability(_ availability: SidebarWorklaneMoveAvailability) {
        paneRowButtons.forEach { $0.worklaneMoveAvailability = availability }
    }

    func setOnlyWorklane(_ isOnlyWorklane: Bool) {
        paneRowButtons.forEach { button in
            button.isLastPaneInOnlyWorklane = isOnlyWorklane && button.isLastPaneInWorklane
        }
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
        panePresentations: [SidebarWorklaneRowRenderPlan.PaneRow],
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
            panePrimaryRows[index].configureRemoteIndicator(
                isRemote: panePresentation.isRemotePane,
                label: panePresentation.remotePaneLabel
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
            paneServerRows[index].configure(serverPorts: panePresentation.serverPorts)

            let button = paneRowButtons[index]
            button.paneID = paneRow.paneID
            button.isLastPaneInWorklane = panePresentations.count == 1
            button.isLastPaneInOnlyWorklane = callbacks.isOnlyWorklane && panePresentations.count == 1
            button.currentWorklaneColor = worklaneColor
            button.setAccessibilityLabel(paneRow.primaryText)
            button.onPaneClicked = callbacks.onPaneSelected
            button.onCloseWorklane = callbacks.onCloseWorklaneRequested
            button.onRenameWorklane = callbacks.onRenameWorklaneRequested
            button.onClosePane = callbacks.onClosePaneRequested
            button.onSplitHorizontal = callbacks.onSplitHorizontalRequested
            button.onSplitVertical = callbacks.onSplitVerticalRequested
            button.onAddPaneLeft = callbacks.onAddPaneLeftRequested
            button.onForceSplitRight = callbacks.onForceSplitRightRequested
            button.onForceAddPaneRight = callbacks.onForceAddPaneRightRequested
            button.onMovePaneToNewWindow = callbacks.onMovePaneToNewWindowRequested
            button.onRunRestoredCommand = callbacks.onRunRestoredCommandRequested
            button.onPickWorklaneColor = { _, color in
                callbacks.onWorklaneColorChanged?(color)
            }
            button.onBookmarkAction = callbacks.onBookmarkAction
            button.bookmarkOriginID = callbacks.bookmarkOriginID
            button.bookmarkNameLookup = callbacks.bookmarkNameLookup
            button.onWorklaneDragRequested = callbacks.onWorklaneDragRequested
            button.serverRowView = paneServerRows[index]
            button.onServerPortSelected = callbacks.onServerPortSelected
            button.onHoverChanged = callbacks.onHoverChanged
            button.worklaneMoveAvailability = callbacks.worklaneMoveAvailability
            button.onMoveWorklane = callbacks.onMoveWorklaneRequested
            button.rightPaneCommandPresentationProvider = callbacks.rightPaneCommandPresentationProvider
            button.moveToWorklaneCatalogProvider = callbacks.moveToWorklaneCatalogProvider
            button.restoredRerunnableCommandProvider = callbacks.restoredRerunnableCommandProvider
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

        while paneServerRows.count < count {
            paneServerRows.append(SidebarPaneServerRowView())
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

@MainActor
final class SidebarWorklaneRowContentRenderer {
    struct Labels {
        let topLabel: NSView
        let primaryTextContainer: NSView
        let contextPrefixLabel: NSView
        let statusContentStack: NSView
        let detailLabels: [NSView]
        let overflowLabel: NSView
    }

    struct PaneRows {
        let primaryRows: [NSView]
        let detailLabels: [NSView]
        let statusRows: [NSView]
        let serverRows: [NSView]
        let buttons: [SidebarPaneRowButton]
        let containers: [NSView]
    }

    private weak var textStack: NSStackView?
    private let textWrapperInset: CGFloat

    init(
        textStack: NSStackView,
        textWrapperInset: CGFloat
    ) {
        self.textStack = textStack
        self.textWrapperInset = textWrapperInset
    }

    func groupedViews(
        for renderPlan: SidebarWorklaneRowRenderPlan,
        labels: Labels,
        paneRows: PaneRows
    ) -> [NSView] {
        renderPlan.contentGroups.map { group in
            switch group {
            case .standalone(let row):
                return insetWrappedView(for: view(for: row, labels: labels, paneRows: paneRows))
            case .pane(let index, let rows):
                paneRows.buttons[index].setContent(
                    rows.map { view(for: $0, labels: labels, paneRows: paneRows) }
                )
                return paneRows.containers[index]
            }
        }
    }

    private func insetWrappedView(for view: NSView) -> NSView {
        guard let textStack else {
            return view
        }

        return SidebarInsetContainerView(
            contentView: view,
            horizontalInset: textWrapperInset,
            referenceWidthView: textStack
        )
    }

    private func view(
        for row: WorklaneRowTextRow,
        labels: Labels,
        paneRows: PaneRows
    ) -> NSView {
        switch row {
        case .topLabel:
            labels.topLabel
        case .primary:
            labels.primaryTextContainer
        case .contextPrefix:
            labels.contextPrefixLabel
        case .status:
            labels.statusContentStack
        case .panePrimary(let index):
            paneRows.primaryRows[index]
        case .paneDetail(let index):
            paneRows.detailLabels[index]
        case .paneStatus(let index):
            paneRows.statusRows[index]
        case .paneServer(let index):
            paneRows.serverRows[index]
        case .context:
            labels.detailLabels.first ?? labels.overflowLabel
        case .detail(let index):
            labels.detailLabels[index]
        case .overflow:
            labels.overflowLabel
        }
    }
}
