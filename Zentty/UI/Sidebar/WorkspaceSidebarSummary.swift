import AppKit

enum WorkspaceSidebarDetailEmphasis: Equatable {
    case primary
    case secondary
}

struct WorkspaceSidebarDetailLine: Equatable {
    let text: String
    let emphasis: WorkspaceSidebarDetailEmphasis
}

struct WorkspaceSidebarPaneRow: Equatable {
    let paneID: PaneID
    let primaryText: String
    let trailingText: String?
    let detailText: String?
    let statusText: String?
    let attentionState: WorkspaceAttentionState?
    let isFocused: Bool
    let isWorking: Bool
}

struct WorkspaceSidebarSummary: Equatable {
    let workspaceID: WorkspaceID
    let badgeText: String
    let topLabel: String?
    let primaryText: String
    let focusedPaneLineIndex: Int
    let statusText: String?
    let detailLines: [WorkspaceSidebarDetailLine]
    let paneRows: [WorkspaceSidebarPaneRow]
    let overflowText: String?
    let attentionState: WorkspaceAttentionState?
    let isWorking: Bool
    let isActive: Bool

    var title: String { topLabel ?? "" }
    var contextText: String {
        if let paneRow = paneRows.first(where: \.isFocused) ?? paneRows.first {
            return [paneRow.trailingText, paneRow.detailText]
                .compactMap(WorkspaceContextFormatter.trimmed)
                .joined(separator: " · ")
        }

        return detailLines.first?.text ?? ""
    }
    var showsGeneratedTitle: Bool { topLabel != nil }

    init(
        workspaceID: WorkspaceID,
        badgeText: String,
        topLabel: String? = nil,
        primaryText: String,
        focusedPaneLineIndex: Int = 0,
        statusText: String? = nil,
        detailLines: [WorkspaceSidebarDetailLine] = [],
        paneRows: [WorkspaceSidebarPaneRow] = [],
        overflowText: String? = nil,
        attentionState: WorkspaceAttentionState? = nil,
        isWorking: Bool = false,
        isActive: Bool
    ) {
        self.workspaceID = workspaceID
        self.badgeText = badgeText
        self.topLabel = topLabel
        self.primaryText = primaryText
        self.focusedPaneLineIndex = focusedPaneLineIndex
        self.statusText = statusText
        self.detailLines = detailLines
        self.paneRows = paneRows
        self.overflowText = overflowText
        self.attentionState = attentionState
        self.isWorking = isWorking
        self.isActive = isActive
    }
}
