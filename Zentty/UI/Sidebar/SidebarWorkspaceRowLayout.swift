import CoreGraphics
import Foundation

enum WorkspaceRowMode: Equatable {
    case compact
    case expanded
}

enum WorkspaceRowTextRow: Equatable {
    case topLabel
    case primary
    case status
    case stateBadge
    case context
    case detail(Int)
    case overflow
}

struct WorkspaceRowLayoutMetrics: Equatable {
    let topInset: CGFloat
    let bottomInset: CGFloat
    let interlineSpacing: CGFloat
    let titleLineHeight: CGFloat
    let primaryLineHeight: CGFloat
    let statusLineHeight: CGFloat
    let detailLineHeight: CGFloat
    let overflowLineHeight: CGFloat

    static let sidebar = WorkspaceRowLayoutMetrics(
        topInset: ShellMetrics.sidebarRowTopInset,
        bottomInset: ShellMetrics.sidebarRowBottomInset,
        interlineSpacing: ShellMetrics.sidebarRowInterlineSpacing,
        titleLineHeight: ShellMetrics.sidebarTitleLineHeight,
        primaryLineHeight: ShellMetrics.sidebarPrimaryLineHeight,
        statusLineHeight: ShellMetrics.sidebarStatusLineHeight,
        detailLineHeight: ShellMetrics.sidebarDetailLineHeight,
        overflowLineHeight: ShellMetrics.sidebarOverflowLineHeight
    )

    var compactHeight: CGFloat {
        topInset + bottomInset + primaryLineHeight
    }

    var expandedHeight: CGFloat {
        rowHeight(
            includesTopLabel: true,
            includesStatus: true,
            detailLineCount: 1,
            includesOverflow: false,
            includesArtifact: false
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
        includesOverflow: Bool,
        includesArtifact: Bool
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
        let computedHeight = topInset + bottomInset + textHeight + spacingHeight

        guard includesArtifact else {
            return computedHeight
        }

        return max(computedHeight, expandedHeight)
    }

    func height(for visibleRows: [WorkspaceRowTextRow]) -> CGFloat {
        var total = verticalPadding
        for row in visibleRows {
            total += lineHeight(for: row)
        }
        if visibleRows.count > 1 {
            total += CGFloat(visibleRows.count - 1) * interlineSpacing
        }
        return total
    }

    private func lineHeight(for row: WorkspaceRowTextRow) -> CGFloat {
        switch row {
        case .topLabel:
            return titleLineHeight
        case .primary:
            return primaryLineHeight
        case .status:
            return statusLineHeight
        case .stateBadge:
            return detailLineHeight
        case .context:
            return contextLineHeight
        case .detail:
            return detailLineHeight
        case .overflow:
            return overflowLineHeight
        }
    }
}

struct SidebarWorkspaceRowLayout: Equatable {
    let mode: WorkspaceRowMode
    let visibleTextRows: [WorkspaceRowTextRow]
    let rowHeight: CGFloat

    init(
        summary: WorkspaceSidebarSummary,
        metrics: WorkspaceRowLayoutMetrics = .sidebar
    ) {
        let visibleTextRows = Self.visibleTextRows(for: summary)
        let mode = Self.mode(for: summary)
        let includesArtifact = summary.artifactLink != nil

        self.mode = mode
        self.visibleTextRows = visibleTextRows
        let computedHeight = metrics.height(for: visibleTextRows)
        self.rowHeight = mode == .compact
            ? metrics.compactHeight
            : (includesArtifact ? max(computedHeight, metrics.expandedHeight) : computedHeight)
    }

    static func mode(for summary: WorkspaceSidebarSummary) -> WorkspaceRowMode {
        let hasVisibleTitle = hasVisibleText(summary.topLabel)
        let hasVisibleStatus = hasVisibleText(summary.statusText)
        let hasVisibleStateBadge = hasVisibleText(summary.stateBadgeText)
        let hasVisibleDetailLines = summary.detailLines.isEmpty == false
        let hasOverflow = hasVisibleText(summary.overflowText)
        let hasArtifact = summary.artifactLink != nil

        return hasVisibleTitle || hasVisibleStatus || hasVisibleStateBadge || hasVisibleDetailLines || hasOverflow || hasArtifact
            ? .expanded
            : .compact
    }

    static func visibleTextRows(for summary: WorkspaceSidebarSummary) -> [WorkspaceRowTextRow] {
        var rows: [WorkspaceRowTextRow] = []

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

        if hasVisibleText(summary.stateBadgeText) {
            rows.append(.stateBadge)
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

struct SidebarWorkspaceGroupLayout: Equatable {
    let headerVisibleRows: [WorkspaceRowTextRow]
    let headerHeight: CGFloat
    let paneSubRowHeight: CGFloat
    let expandedPaneCount: Int
    let totalHeight: CGFloat

    init(
        headerStatusText: String?,
        headerContextText: String,
        paneCount: Int,
        isExpanded: Bool,
        metrics: WorkspaceRowLayoutMetrics = .sidebar
    ) {
        var rows: [WorkspaceRowTextRow] = [.primary]
        if Self.hasVisibleText(headerStatusText) {
            rows.append(.status)
        }
        if Self.hasVisibleText(headerContextText) {
            rows.append(.context)
        }
        self.headerVisibleRows = rows
        self.headerHeight = metrics.height(for: rows)
        self.paneSubRowHeight = ShellMetrics.paneSubRowHeight

        if paneCount <= 1 {
            self.expandedPaneCount = 0
        } else {
            self.expandedPaneCount = isExpanded ? paneCount : 0
        }

        self.totalHeight = headerHeight + CGFloat(expandedPaneCount) * paneSubRowHeight
    }

    private static func hasVisibleText(_ text: String?) -> Bool {
        guard let text else { return false }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
