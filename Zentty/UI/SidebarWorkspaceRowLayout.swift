import CoreGraphics
import Foundation

enum WorkspaceRowMode: Equatable {
    case compact
    case expanded
}

enum WorkspaceRowTextRow: Equatable {
    case title
    case primary
    case status
    case context
}

struct WorkspaceRowLayoutMetrics: Equatable {
    let verticalPadding: CGFloat
    let interlineSpacing: CGFloat
    let titleLineHeight: CGFloat
    let primaryLineHeight: CGFloat
    let statusLineHeight: CGFloat
    let contextLineHeight: CGFloat

    static let sidebar = WorkspaceRowLayoutMetrics(
        verticalPadding: ShellMetrics.sidebarRowVerticalPadding,
        interlineSpacing: ShellMetrics.sidebarRowInterlineSpacing,
        titleLineHeight: ShellMetrics.sidebarTitleLineHeightBudget,
        primaryLineHeight: ShellMetrics.sidebarPrimaryLineHeightBudget,
        statusLineHeight: ShellMetrics.sidebarStatusLineHeightBudget,
        contextLineHeight: ShellMetrics.sidebarContextLineHeightBudget
    )

    var compactHeight: CGFloat {
        verticalPadding + primaryLineHeight
    }

    var expandedHeight: CGFloat {
        verticalPadding
            + titleLineHeight
            + primaryLineHeight
            + statusLineHeight
            + contextLineHeight
            + (3 * interlineSpacing)
    }

    func height(for mode: WorkspaceRowMode) -> CGFloat {
        switch mode {
        case .compact:
            compactHeight
        case .expanded:
            expandedHeight
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

        self.mode = mode
        self.visibleTextRows = visibleTextRows
        self.rowHeight = metrics.height(for: mode)
    }

    static func mode(for summary: WorkspaceSidebarSummary) -> WorkspaceRowMode {
        let hasVisibleTitle = showsVisibleGeneratedTitle(summary)
        let hasVisibleStatus = hasVisibleText(summary.statusText)
        let hasVisibleContext = hasVisibleText(summary.contextText)
        let hasArtifact = summary.artifactLink != nil

        return hasVisibleTitle || hasVisibleStatus || hasVisibleContext || hasArtifact
            ? .expanded
            : .compact
    }

    static func visibleTextRows(for summary: WorkspaceSidebarSummary) -> [WorkspaceRowTextRow] {
        var rows: [WorkspaceRowTextRow] = []

        if showsVisibleGeneratedTitle(summary) {
            rows.append(.title)
        }

        rows.append(.primary)

        if hasVisibleText(summary.statusText) {
            rows.append(.status)
        }

        if hasVisibleText(summary.contextText) {
            rows.append(.context)
        }

        return rows
    }

    private static func showsVisibleGeneratedTitle(_ summary: WorkspaceSidebarSummary) -> Bool {
        summary.showsGeneratedTitle && hasVisibleText(summary.title)
    }

    private static func hasVisibleText(_ text: String?) -> Bool {
        guard let text else {
            return false
        }

        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
