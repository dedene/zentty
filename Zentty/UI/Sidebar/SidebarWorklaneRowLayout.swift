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
        var total = verticalPadding
        for row in visibleRows {
            total += lineHeight(for: row)
        }
        if visibleRows.count > 1 {
            total += CGFloat(visibleRows.count - 1) * interlineSpacing
        }
        var paneIndices = Set<Int>()
        for row in visibleRows {
            switch row {
            case .panePrimary(let i), .paneDetail(let i), .paneStatus(let i):
                paneIndices.insert(i)
            default:
                break
            }
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
        metrics: WorklaneRowLayoutMetrics = .sidebar
    ) {
        let visibleTextRows = Self.visibleTextRows(for: summary)
        let mode = Self.mode(for: summary)

        self.mode = mode
        self.visibleTextRows = visibleTextRows
        let computedHeight = metrics.height(for: visibleTextRows)
        self.rowHeight = mode == .compact && summary.paneRows.isEmpty
            ? metrics.compactHeight
            : computedHeight
    }

    static func mode(for summary: WorklaneSidebarSummary) -> WorklaneRowMode {
        if summary.paneRows.isEmpty == false {
            return summary.paneRows.count > 1
                || hasVisibleText(summary.topLabel)
                || summary.paneRows.contains(where: { hasVisibleText($0.detailText) || hasVisibleText($0.statusText) })
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
        if summary.paneRows.isEmpty == false {
            var rows: [WorklaneRowTextRow] = []

            if hasVisibleText(summary.topLabel) {
                rows.append(.topLabel)
            }

            for index in summary.paneRows.indices {
                rows.append(.panePrimary(index))

                if hasVisibleText(summary.paneRows[index].detailText) {
                    rows.append(.paneDetail(index))
                }

                if hasVisibleText(summary.paneRows[index].statusText) {
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
}
