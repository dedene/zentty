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
        let includesTopLabel = Self.hasVisibleText(summary.topLabel)
        let includesStatus = Self.hasVisibleText(summary.statusText)
        let includesOverflow = Self.hasVisibleText(summary.overflowText)
        let detailLineCount = summary.detailLines.count
        let includesArtifact = summary.artifactLink != nil

        self.mode = mode
        self.visibleTextRows = visibleTextRows
        self.rowHeight = mode == .compact
            ? metrics.compactHeight
            : metrics.rowHeight(
                includesTopLabel: includesTopLabel,
                includesStatus: includesStatus,
                detailLineCount: detailLineCount,
                includesOverflow: includesOverflow,
                includesArtifact: includesArtifact
            )
    }

    static func mode(for summary: WorkspaceSidebarSummary) -> WorkspaceRowMode {
        let hasVisibleTitle = hasVisibleText(summary.topLabel)
        let hasVisibleStatus = hasVisibleText(summary.statusText)
        let hasVisibleDetailLines = summary.detailLines.isEmpty == false
        let hasOverflow = hasVisibleText(summary.overflowText)
        let hasArtifact = summary.artifactLink != nil

        return hasVisibleTitle || hasVisibleStatus || hasVisibleDetailLines || hasOverflow || hasArtifact
            ? .expanded
            : .compact
    }

    static func visibleTextRows(for summary: WorkspaceSidebarSummary) -> [WorkspaceRowTextRow] {
        var rows: [WorkspaceRowTextRow] = []

        if hasVisibleText(summary.topLabel) {
            rows.append(.topLabel)
        }

        rows.append(.primary)

        if hasVisibleText(summary.statusText) {
            rows.append(.status)
        }

        rows.append(contentsOf: summary.detailLines.indices.map(WorkspaceRowTextRow.detail))

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
