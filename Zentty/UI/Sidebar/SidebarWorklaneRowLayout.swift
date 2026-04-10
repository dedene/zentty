import AppKit
import CoreGraphics
import Foundation

enum WorklaneRowMode: Equatable {
    case compact
    case expanded
}

enum WorklaneRowTextRow: Equatable {
    case topLabel
    case primary
    case contextPrefix
    case status
    case panePrimary(Int)
    case paneDetail(Int)
    case paneStatus(Int)
    case context
    case detail(Int)
    case overflow
}

struct SidebarPaneStatusTrailingLayout: Equatable {
    let isVisible: Bool
    let width: CGFloat

    static let hidden = SidebarPaneStatusTrailingLayout(isVisible: false, width: 0)
}

struct WorklaneRowLayoutMetrics: Equatable {
    let topInset: CGFloat
    let bottomInset: CGFloat
    let paneTopInset: CGFloat
    let paneBottomInset: CGFloat
    let interlineSpacing: CGFloat
    let titleLineHeight: CGFloat
    let primaryLineHeight: CGFloat
    let statusLineHeight: CGFloat
    let detailLineHeight: CGFloat
    let overflowLineHeight: CGFloat
    let paneButtonVerticalPadding: CGFloat

    static let sidebar = WorklaneRowLayoutMetrics(
        topInset: ShellMetrics.sidebarRowTopInset,
        bottomInset: ShellMetrics.sidebarRowBottomInset,
        paneTopInset: ShellMetrics.sidebarPaneRowVerticalInset,
        paneBottomInset: ShellMetrics.sidebarPaneRowVerticalInset,
        interlineSpacing: ShellMetrics.sidebarRowInterlineSpacing,
        titleLineHeight: ShellMetrics.sidebarTitleLineHeight,
        primaryLineHeight: ShellMetrics.sidebarPrimaryLineHeight,
        statusLineHeight: ShellMetrics.sidebarStatusLineHeight,
        detailLineHeight: ShellMetrics.sidebarDetailLineHeight,
        overflowLineHeight: ShellMetrics.sidebarOverflowLineHeight,
        paneButtonVerticalPadding: ShellMetrics.sidebarPaneButtonVerticalInset * 2
    )

    var compactHeight: CGFloat {
        topInset + bottomInset + primaryLineHeight
    }

    var expandedHeight: CGFloat {
        rowHeight(
            includesTopLabel: true,
            includesStatus: true,
            detailLineCount: 1,
            includesOverflow: false
        )
    }

    var verticalPadding: CGFloat {
        topInset + bottomInset
    }

    var paneVerticalPadding: CGFloat {
        paneTopInset + paneBottomInset
    }

    var contextLineHeight: CGFloat {
        detailLineHeight
    }

    func rowHeight(
        includesTopLabel: Bool,
        includesStatus: Bool,
        detailLineCount: Int,
        includesOverflow: Bool
    ) -> CGFloat {
        let clampedDetailLineCount = max(0, detailLineCount)
        let visibleLineHeights: [CGFloat] = [
            includesTopLabel ? titleLineHeight : nil,
            primaryLineHeight,
            includesStatus ? statusLineHeight : nil,
        ]
            .compactMap { $0 }
            + Array(repeating: detailLineHeight, count: clampedDetailLineCount)
            + (includesOverflow ? [overflowLineHeight] : [])

        let textHeight = visibleLineHeights.reduce(0, +)
        let spacingHeight = CGFloat(max(0, visibleLineHeights.count - 1)) * interlineSpacing
        return topInset + bottomInset + textHeight + spacingHeight
    }

    func height(for visibleRows: [WorklaneRowTextRow]) -> CGFloat {
        var paneIndices = Set<Int>()
        for row in visibleRows {
            switch row {
            case .panePrimary(let i), .paneDetail(let i), .paneStatus(let i):
                paneIndices.insert(i)
            default:
                break
            }
        }

        var total = paneIndices.isEmpty ? verticalPadding : paneVerticalPadding
        for row in visibleRows {
            total += lineHeight(for: row)
        }
        if visibleRows.count > 1 {
            total += CGFloat(visibleRows.count - 1) * interlineSpacing
        }
        total += CGFloat(paneIndices.count) * paneButtonVerticalPadding
        return total
    }

    private func lineHeight(for row: WorklaneRowTextRow) -> CGFloat {
        switch row {
        case .topLabel:
            return titleLineHeight
        case .primary:
            return primaryLineHeight
        case .contextPrefix:
            return detailLineHeight
        case .status:
            return statusLineHeight
        case .panePrimary:
            return primaryLineHeight
        case .paneDetail:
            return detailLineHeight
        case .paneStatus:
            return statusLineHeight
        case .context:
            return contextLineHeight
        case .detail:
            return detailLineHeight
        case .overflow:
            return overflowLineHeight
        }
    }
}

struct SidebarWorklaneRowLayout: Equatable {
    let mode: WorklaneRowMode
    let visibleTextRows: [WorklaneRowTextRow]
    let rowHeight: CGFloat

    init(
        summary: WorklaneSidebarSummary,
        availableWidth: CGFloat? = nil,
        metrics: WorklaneRowLayoutMetrics = .sidebar
    ) {
        let visibleTextRows = Self.visibleTextRows(for: summary, availableWidth: availableWidth)
        let mode = Self.mode(for: summary, availableWidth: availableWidth)

        self.mode = mode
        self.visibleTextRows = visibleTextRows
        self.rowHeight = metrics.height(
            for: visibleTextRows,
            summary: summary,
            availableWidth: availableWidth
        )
    }

    static func mode(
        for summary: WorklaneSidebarSummary,
        availableWidth: CGFloat? = nil
    ) -> WorklaneRowMode {
        if summary.paneRows.isEmpty == false {
            return summary.paneRows.count > 1
                || hasVisibleText(summary.topLabel)
                || summary.paneRows.contains(where: { hasVisibleText($0.detailText) || hasVisibleText($0.statusText) })
                || summary.paneRows.contains(where: {
                    paneRowPresentationMode(for: $0, availableWidth: availableWidth) == .adaptive
                })
                || summary.paneRows.contains(where: {
                    paneRowStatusLineCount(for: $0, availableWidth: availableWidth) > 1
                })
                || hasVisibleText(summary.overflowText)
                ? .expanded
                : .compact
        }

        let hasVisibleTitle = hasVisibleText(summary.topLabel)
        let hasVisibleStatus = hasVisibleText(summary.statusText)
        let hasVisibleDetailLines = summary.detailLines.isEmpty == false
        let hasOverflow = hasVisibleText(summary.overflowText)
        let hasVisibleContextPrefix = hasVisibleText(summary.contextPrefixText)
        let wrapsStatus = worklaneStatusLineCount(for: summary, availableWidth: availableWidth) > 1

        return hasVisibleTitle || hasVisibleStatus || hasVisibleDetailLines || hasOverflow || hasVisibleContextPrefix || wrapsStatus
            ? .expanded
            : .compact
    }

    static func visibleTextRows(for summary: WorklaneSidebarSummary) -> [WorklaneRowTextRow] {
        visibleTextRows(for: summary, availableWidth: nil)
    }

    static func visibleTextRows(
        for summary: WorklaneSidebarSummary,
        availableWidth: CGFloat?
    ) -> [WorklaneRowTextRow] {
        if summary.paneRows.isEmpty == false {
            var rows: [WorklaneRowTextRow] = []

            if hasVisibleText(summary.topLabel) {
                rows.append(.topLabel)
            }

            // Surface the disambiguation context prefix as a small-font row
            // between the primary and the status of the (single) pane row.
            // For multi-pane worklanes the prefix is implied by the pane row
            // layout itself, so we skip it to avoid noise.
            let shouldShowContextPrefix =
                summary.paneRows.count == 1
                && hasVisibleText(summary.contextPrefixText)

            for index in summary.paneRows.indices {
                let paneRow = summary.paneRows[index]
                rows.append(.panePrimary(index))

                if hasVisibleText(paneRow.detailText) {
                    rows.append(.paneDetail(index))
                }

                if shouldShowContextPrefix && index == 0 {
                    rows.append(.contextPrefix)
                }

                if paneRowShowsMetadataRow(paneRow, availableWidth: availableWidth) {
                    rows.append(.paneStatus(index))
                }
            }

            if hasVisibleText(summary.overflowText) {
                rows.append(.overflow)
            }

            return rows
        }

        var rows: [WorklaneRowTextRow] = []

        if hasVisibleText(summary.topLabel) {
            rows.append(.topLabel)
        }

        let paneLineCount = max(1, summary.detailLines.count + 1)
        let focusedPaneLineIndex = min(
            max(0, summary.focusedPaneLineIndex),
            paneLineCount - 1
        )
        var detailIndex = 0
        for paneLineIndex in 0..<paneLineCount {
            if paneLineIndex == focusedPaneLineIndex {
                rows.append(.primary)
            } else {
                rows.append(.detail(detailIndex))
                detailIndex += 1
            }
        }

        if hasVisibleText(summary.contextPrefixText) {
            rows.append(.contextPrefix)
        }

        if hasVisibleText(summary.statusText) {
            rows.append(.status)
        }

        if hasVisibleText(summary.overflowText) {
            rows.append(.overflow)
        }

        return rows
    }

    private static func hasVisibleText(_ text: String?) -> Bool {
        guard let text else {
            return false
        }

        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func paneRowPresentationMode(
        for paneRow: WorklaneSidebarPaneRow,
        availableWidth: CGFloat?
    ) -> SidebarPaneRowPresentationMode {
        guard let availableWidth else {
            return .inline
        }

        let contentWidth = paneRowContentWidth(for: availableWidth)
        guard contentWidth > 0 else {
            return .inline
        }

        let titleWidth = measuredWidth(
            for: paneRow.primaryText,
            font: ShellMetrics.sidebarPrimaryFont()
        )
        let trailingWidth = measuredWidth(
            for: paneRow.trailingText,
            font: ShellMetrics.sidebarDetailFont()
        )

        let inlineRequiredWidth =
            titleWidth
            + (hasVisibleText(paneRow.trailingText) ? SidebarPaneRowPresentationMode.inlineSpacing : 0)
            + trailingWidth

        if titleWidth > contentWidth || inlineRequiredWidth > contentWidth {
            return .adaptive
        }

        return .inline
    }

    static func worklanePrimaryLineCount(
        for summary: WorklaneSidebarSummary,
        availableWidth: CGFloat?,
        metrics: WorklaneRowLayoutMetrics = .sidebar
    ) -> Int {
        guard let availableWidth else {
            return 1
        }

        return lineCount(
            for: summary.primaryText,
            font: ShellMetrics.sidebarPrimaryFont(),
            lineHeight: metrics.primaryLineHeight,
            width: worklaneTextContentWidth(for: availableWidth),
            maxLineCount: 2
        )
    }

    static func worklaneStatusLineCount(
        for summary: WorklaneSidebarSummary,
        availableWidth: CGFloat?,
        metrics: WorklaneRowLayoutMetrics = .sidebar
    ) -> Int {
        guard
            let availableWidth,
            let statusText = SidebarStatusResolver.resolveMeasurementStatusText(
                statusText: summary.statusText,
                attentionState: summary.attentionState,
                interactionKind: summary.interactionKind,
                interactionLabel: summary.interactionLabel
            )
        else {
            return 1
        }

        return lineCount(
            for: statusText,
            font: ShellMetrics.sidebarStatusFont(),
            lineHeight: metrics.statusLineHeight,
            width: worklaneStatusTextContentWidth(
                for: availableWidth,
                hasIcon: SidebarStatusResolver.resolveStatusSymbolName(
                    statusSymbolName: summary.statusSymbolName,
                    attentionState: summary.attentionState,
                    interactionKind: summary.interactionKind,
                    interactionSymbolName: summary.interactionSymbolName
                ).isEmpty == false
            ),
            maxLineCount: 2
        )
    }

    static func paneRowShowsMetadataRow(
        _ paneRow: WorklaneSidebarPaneRow,
        availableWidth: CGFloat?
    ) -> Bool {
        hasVisibleText(paneRow.statusText)
            || (
                paneRowPresentationMode(for: paneRow, availableWidth: availableWidth) == .adaptive
                    && hasVisibleText(paneRow.trailingText)
            )
    }

    static func paneRowStatusLineCount(
        for paneRow: WorklaneSidebarPaneRow,
        availableWidth: CGFloat?,
        metrics: WorklaneRowLayoutMetrics = .sidebar
    ) -> Int {
        guard
            let availableWidth,
            let statusText = SidebarStatusResolver.resolveMeasurementStatusText(
                statusText: paneRow.statusText,
                attentionState: paneRow.attentionState,
                interactionKind: paneRow.interactionKind,
                interactionLabel: paneRow.interactionLabel
            )
        else {
            return 1
        }

        let trailingLayout = paneRowPresentationMode(
            for: paneRow,
            availableWidth: availableWidth
        ) == .adaptive
            ? paneRowStatusTrailingLayout(
                for: paneRow,
                availableWidth: availableWidth,
                metrics: metrics
            )
            : .hidden

        return lineCount(
            for: statusText,
            font: ShellMetrics.sidebarStatusFont(),
            lineHeight: metrics.statusLineHeight,
            width: paneStatusTextContentWidth(
                for: availableWidth,
                trailingWidth: trailingLayout.isVisible ? trailingLayout.width : 0,
                hasIcon: SidebarStatusResolver.resolveStatusSymbolName(
                    statusSymbolName: paneRow.statusSymbolName,
                    attentionState: paneRow.attentionState,
                    interactionKind: paneRow.interactionKind,
                    interactionSymbolName: paneRow.interactionSymbolName
                ).isEmpty == false
            ),
            maxLineCount: 2
        )
    }

    static func paneRowStatusTrailingLayout(
        for paneRow: WorklaneSidebarPaneRow,
        availableWidth: CGFloat?,
        metrics: WorklaneRowLayoutMetrics = .sidebar
    ) -> SidebarPaneStatusTrailingLayout {
        guard
            let availableWidth,
            hasVisibleText(paneRow.trailingText)
        else {
            return .hidden
        }

        let intrinsicTrailingWidth = measuredWidth(
            for: paneRow.trailingText,
            font: ShellMetrics.sidebarDetailFont()
        )
        guard intrinsicTrailingWidth > 0 else {
            return .hidden
        }

        let contentWidth = paneRowContentWidth(for: availableWidth)
        guard contentWidth > 0 else {
            return .hidden
        }

        guard
            let statusText = SidebarStatusResolver.resolveMeasurementStatusText(
                statusText: paneRow.statusText,
                attentionState: paneRow.attentionState,
                interactionKind: paneRow.interactionKind,
                interactionLabel: paneRow.interactionLabel
            )
        else {
            return SidebarPaneStatusTrailingLayout(
                isVisible: true,
                width: min(intrinsicTrailingWidth, contentWidth)
            )
        }

        let hasIcon = SidebarStatusResolver.resolveStatusSymbolName(
            statusSymbolName: paneRow.statusSymbolName,
            attentionState: paneRow.attentionState,
            interactionKind: paneRow.interactionKind,
            interactionSymbolName: paneRow.interactionSymbolName
        ).isEmpty == false
        let iconWidth: CGFloat = hasIcon ? 11 + 4 : 0
        let maximumStatusTextWidth = max(1, contentWidth - iconWidth)
        let preferredStatusTextWidth = measuredWidth(
            for: statusText,
            font: ShellMetrics.sidebarStatusFont()
        )

        guard SidebarTextMetrics.measuredLineCount(
            for: statusText,
            font: ShellMetrics.sidebarStatusFont(),
            lineHeight: metrics.statusLineHeight,
            width: maximumStatusTextWidth
        ) == 1,
        preferredStatusTextWidth <= maximumStatusTextWidth + 0.5
        else {
            return .hidden
        }

        let availableTrailingWidth =
            contentWidth
            - iconWidth
            - preferredStatusTextWidth
            - 4
        let resolvedTrailingWidth = min(intrinsicTrailingWidth, max(0, availableTrailingWidth))
        let minimumVisibleTrailingWidth = min(
            intrinsicTrailingWidth,
            paneStatusTrailingMinimumVisibleWidth()
        )
        let minimumComfortableTrailingWidth = min(
            intrinsicTrailingWidth,
            minimumVisibleTrailingWidth + paneStatusTrailingVisibilityBuffer()
        )

        guard resolvedTrailingWidth + 0.5 >= minimumComfortableTrailingWidth else {
            return .hidden
        }

        let finalStatusTextWidth = paneStatusTextContentWidth(
            for: availableWidth,
            trailingWidth: resolvedTrailingWidth,
            hasIcon: hasIcon
        )
        guard
            preferredStatusTextWidth <= finalStatusTextWidth + 0.5,
            SidebarTextMetrics.measuredLineCount(
                for: statusText,
                font: ShellMetrics.sidebarStatusFont(),
                lineHeight: metrics.statusLineHeight,
                width: finalStatusTextWidth
            ) == 1
        else {
            return .hidden
        }

        return SidebarPaneStatusTrailingLayout(
            isVisible: true,
            width: resolvedTrailingWidth
        )
    }

    private static func paneRowContentWidth(for availableWidth: CGFloat) -> CGFloat {
        availableWidth
            - (ShellMetrics.sidebarPaneRowHorizontalInset * 2)
            - (ShellMetrics.sidebarPaneButtonHorizontalInset * 2)
    }

    private static func worklaneTextContentWidth(for availableWidth: CGFloat) -> CGFloat {
        availableWidth - (ShellMetrics.sidebarWorklaneTextHorizontalInset * 2)
    }

    private static func worklaneStatusTextContentWidth(
        for availableWidth: CGFloat,
        hasIcon: Bool
    ) -> CGFloat {
        let iconWidth = hasIcon ? (11 + 4) : 0
        return max(0, worklaneTextContentWidth(for: availableWidth) - CGFloat(iconWidth))
    }

    private static func paneStatusTextContentWidth(
        for availableWidth: CGFloat,
        trailingWidth: CGFloat,
        hasIcon: Bool
    ) -> CGFloat {
        var width = paneRowContentWidth(for: availableWidth)
        if hasIcon {
            width -= 11 + 4
        }
        if trailingWidth > 0 {
            width -= trailingWidth + 4
        }
        return max(0, width)
    }

    private static func measuredWidth(for text: String?, font: NSFont) -> CGFloat {
        guard hasVisibleText(text) else { return 0 }
        return SidebarTextMetrics.measuredWidth(for: text, font: font)
    }

    private static func lineCount(
        for text: String,
        font: NSFont,
        lineHeight: CGFloat,
        width: CGFloat,
        maxLineCount: Int
    ) -> Int {
        max(
            1,
            min(
                maxLineCount,
                SidebarTextMetrics.measuredLineCount(
                    for: text,
                    font: font,
                    lineHeight: lineHeight,
                    width: width
                )
            )
        )
    }

    private static func paneStatusTrailingMinimumVisibleWidth() -> CGFloat {
        max(44, measuredWidth(for: "…/tmp", font: ShellMetrics.sidebarDetailFont()))
    }

    private static func paneStatusTrailingVisibilityBuffer() -> CGFloat {
        8
    }

}

enum SidebarPaneRowPresentationMode: Equatable {
    case inline
    case adaptive

    static let inlineSpacing: CGFloat = 6
}

private extension WorklaneRowLayoutMetrics {
    func height(
        for visibleRows: [WorklaneRowTextRow],
        summary: WorklaneSidebarSummary,
        availableWidth: CGFloat?
    ) -> CGFloat {
        var paneIndices = Set<Int>()
        for row in visibleRows {
            switch row {
            case .panePrimary(let i), .paneDetail(let i), .paneStatus(let i):
                paneIndices.insert(i)
            default:
                break
            }
        }

        var total = paneIndices.isEmpty ? verticalPadding : paneVerticalPadding
        for row in visibleRows {
            total += lineHeight(for: row, summary: summary, availableWidth: availableWidth)
        }
        if visibleRows.count > 1 {
            total += CGFloat(visibleRows.count - 1) * interlineSpacing
        }
        total += CGFloat(paneIndices.count) * paneButtonVerticalPadding
        return total
    }

    func lineHeight(
        for row: WorklaneRowTextRow,
        summary: WorklaneSidebarSummary,
        availableWidth: CGFloat?
    ) -> CGFloat {
        switch row {
        case .primary:
            // Worklane primary is always single-line with tail truncation so the
            // shimmer overlay can render. Long titles surface their disambiguation
            // prefix on a dedicated `.contextPrefix` row instead of wrapping.
            return primaryLineHeight
        case .status:
            return statusLineHeight * CGFloat(
                SidebarWorklaneRowLayout.worklaneStatusLineCount(
                    for: summary,
                    availableWidth: availableWidth,
                    metrics: self
                )
            )
        case .panePrimary(let index):
            guard summary.paneRows.indices.contains(index) else {
                return primaryLineHeight
            }
            // Always 1 — pane primaries are single-line for shimmer compatibility.
            return primaryLineHeight
        case .paneStatus(let index):
            guard summary.paneRows.indices.contains(index) else {
                return statusLineHeight
            }
            return statusLineHeight * CGFloat(
                SidebarWorklaneRowLayout.paneRowStatusLineCount(
                    for: summary.paneRows[index],
                    availableWidth: availableWidth,
                    metrics: self
                )
            )
        default:
            return lineHeight(for: row)
        }
    }
}
