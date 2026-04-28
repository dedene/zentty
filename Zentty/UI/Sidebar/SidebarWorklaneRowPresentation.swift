import CoreGraphics

struct SidebarWorklaneRowPresentation: Equatable {
    struct PaneRow: Equatable {
        let row: WorklaneSidebarPaneRow
        let presentationMode: SidebarPaneRowPresentationMode
        let statusDisplayText: String
        let statusSymbolName: String
        let statusTrailingLayout: SidebarPaneStatusTrailingLayout
        let statusLineCount: Int
    }

    let summary: WorklaneSidebarSummary
    let layout: SidebarWorklaneRowLayout
    let statusDisplayText: String
    let statusSymbolName: String
    let statusLineCount: Int
    let paneRows: [PaneRow]

    init(summary: WorklaneSidebarSummary, availableWidth: CGFloat?) {
        self.summary = summary
        layout = SidebarWorklaneRowLayout(summary: summary, availableWidth: availableWidth)
        statusDisplayText = SidebarStatusResolver.resolveDisplayStatusText(
            statusText: summary.statusText,
            attentionState: summary.attentionState,
            interactionKind: summary.interactionKind,
            interactionLabel: summary.interactionLabel
        )
        statusSymbolName = SidebarStatusResolver.resolveStatusSymbolName(
            statusSymbolName: summary.statusSymbolName,
            attentionState: summary.attentionState,
            interactionKind: summary.interactionKind,
            interactionSymbolName: summary.interactionSymbolName
        )
        statusLineCount = SidebarWorklaneRowLayout.worklaneStatusLineCount(
            for: summary,
            availableWidth: availableWidth
        )
        paneRows = summary.paneRows.map { paneRow in
            let presentationMode = SidebarWorklaneRowLayout.paneRowPresentationMode(
                for: paneRow,
                availableWidth: availableWidth
            )
            let statusTrailingLayout = presentationMode == .adaptive
                ? SidebarWorklaneRowLayout.paneRowStatusTrailingLayout(
                    for: paneRow,
                    availableWidth: availableWidth
                )
                : .hidden

            return PaneRow(
                row: paneRow,
                presentationMode: presentationMode,
                statusDisplayText: SidebarStatusResolver.resolveDisplayStatusText(
                    statusText: paneRow.statusText,
                    attentionState: paneRow.attentionState,
                    interactionKind: paneRow.interactionKind,
                    interactionLabel: paneRow.interactionLabel
                ),
                statusSymbolName: SidebarStatusResolver.resolveStatusSymbolName(
                    statusSymbolName: paneRow.statusSymbolName,
                    attentionState: paneRow.attentionState,
                    interactionKind: paneRow.interactionKind,
                    interactionSymbolName: paneRow.interactionSymbolName
                ),
                statusTrailingLayout: statusTrailingLayout,
                statusLineCount: SidebarWorklaneRowLayout.paneRowStatusLineCount(
                    for: paneRow,
                    availableWidth: availableWidth
                )
            )
        }
    }
}
