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
    case status
    case panePrimary(Int)
    case paneDetail(Int)
    case paneStatus(Int)
    case context
    case detail(Int)
    case overflow
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
        let computedHeight = metrics.height(
            for: visibleTextRows,
            summary: summary,
            availableWidth: availableWidth
        )
        self.rowHeight = mode == .compact && summary.paneRows.isEmpty
            ? metrics.compactHeight
            : computedHeight
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
                || hasVisibleText(summary.overflowText)
                ? .expanded
                : .compact
        }

        let hasVisibleTitle = hasVisibleText(summary.topLabel)
        let hasVisibleStatus = hasVisibleText(summary.statusText)
        let hasVisibleDetailLines = summary.detailLines.isEmpty == false
        let hasOverflow = hasVisibleText(summary.overflowText)

        return hasVisibleTitle || hasVisibleStatus || hasVisibleDetailLines || hasOverflow
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

            for index in summary.paneRows.indices {
                let paneRow = summary.paneRows[index]
                rows.append(.panePrimary(index))

                if hasVisibleText(paneRow.detailText) {
                    rows.append(.paneDetail(index))
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

    static func paneRowPrimaryLineCount(
        for paneRow: WorklaneSidebarPaneRow,
        availableWidth: CGFloat?,
        metrics: WorklaneRowLayoutMetrics = .sidebar
    ) -> Int {
        guard paneRowPresentationMode(for: paneRow, availableWidth: availableWidth) == .adaptive,
              let availableWidth else {
            return 1
        }

        let contentWidth = paneRowContentWidth(for: availableWidth)
        guard contentWidth > 0 else {
            return 1
        }

        return max(
            1,
            min(
                2,
                measuredLineCount(
                    for: paneRow.primaryText,
                    font: ShellMetrics.sidebarPrimaryFont(),
                    lineHeight: metrics.primaryLineHeight,
                    width: contentWidth
                )
            )
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

    private static func paneRowContentWidth(for availableWidth: CGFloat) -> CGFloat {
        availableWidth
            - (ShellMetrics.sidebarPaneRowHorizontalInset * 2)
            - (ShellMetrics.sidebarPaneButtonHorizontalInset * 2)
    }

    private static func measuredWidth(for text: String?, font: NSFont) -> CGFloat {
        guard let text, hasVisibleText(text) else {
            return 0
        }

        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: attributes)
        )
        return ceil(CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)))
    }

    private static func measuredLineCount(
        for text: String,
        font: NSFont,
        lineHeight: CGFloat,
        width: CGFloat
    ) -> Int {
        guard width > 0, text.isEmpty == false else {
            return 1
        }

        let boundingRect = (text as NSString).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
        return Int(ceil(boundingRect.height / lineHeight))
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
        case .panePrimary(let index):
            guard summary.paneRows.indices.contains(index) else {
                return primaryLineHeight
            }
            return primaryLineHeight * CGFloat(
                SidebarWorklaneRowLayout.paneRowPrimaryLineCount(
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
