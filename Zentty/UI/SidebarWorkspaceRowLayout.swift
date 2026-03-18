import CoreGraphics
import Foundation

enum WorkspaceRowTextRow: Equatable {
    case primary
    case status
    case context
}

struct WorkspaceRowLayoutMetrics: Equatable {
    let verticalPadding: CGFloat
    let interlineSpacing: CGFloat
    let primaryLineHeight: CGFloat
    let statusLineHeight: CGFloat
    let contextLineHeight: CGFloat

    static let sidebar = WorkspaceRowLayoutMetrics(
        verticalPadding: ShellMetrics.sidebarRowVerticalPadding,
        interlineSpacing: ShellMetrics.sidebarRowInterlineSpacing,
        primaryLineHeight: ShellMetrics.sidebarPrimaryLineHeightBudget,
        statusLineHeight: ShellMetrics.sidebarStatusLineHeightBudget,
        contextLineHeight: ShellMetrics.sidebarContextLineHeightBudget
    )

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
        case .primary:
            return primaryLineHeight
        case .status:
            return statusLineHeight
        case .context:
            return contextLineHeight
        }
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
        if SidebarWorkspaceGroupLayout.hasVisibleText(headerStatusText) {
            rows.append(.status)
        }
        if SidebarWorkspaceGroupLayout.hasVisibleText(headerContextText) {
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
