import AppKit

enum WorklaneSidebarDetailEmphasis: Equatable {
    case primary
    case secondary
}

struct WorklaneSidebarDetailLine: Equatable {
    let text: String
    let emphasis: WorklaneSidebarDetailEmphasis
}

struct WorklaneSidebarServerPort: Equatable {
    let serverID: String
    let port: Int
}

struct WorklaneSidebarPaneRow: Equatable {
    let paneID: PaneID
    let primaryText: String
    let trailingText: String?
    let detailText: String?
    let statusText: String?
    let statusSymbolName: String?
    let attentionState: WorklaneAttentionState?
    let interactionKind: PaneInteractionKind?
    let interactionLabel: String?
    let interactionSymbolName: String?
    let isFocused: Bool
    let isWorking: Bool
    let taskProgress: PaneAgentTaskProgress?
    let serverPorts: [WorklaneSidebarServerPort]

    init(
        paneID: PaneID,
        primaryText: String,
        trailingText: String?,
        detailText: String?,
        statusText: String?,
        statusSymbolName: String? = nil,
        attentionState: WorklaneAttentionState?,
        interactionKind: PaneInteractionKind? = nil,
        interactionLabel: String? = nil,
        interactionSymbolName: String? = nil,
        isFocused: Bool,
        isWorking: Bool,
        taskProgress: PaneAgentTaskProgress? = nil,
        serverPorts: [WorklaneSidebarServerPort] = []
    ) {
        self.paneID = paneID
        self.primaryText = primaryText
        self.trailingText = trailingText
        self.detailText = detailText
        self.statusText = statusText
        self.statusSymbolName = statusSymbolName
        self.attentionState = attentionState
        self.interactionKind = interactionKind
        self.interactionLabel = interactionLabel
        self.interactionSymbolName = interactionSymbolName
        self.isFocused = isFocused
        self.isWorking = isWorking
        self.taskProgress = taskProgress
        self.serverPorts = serverPorts
    }
}

struct WorklaneSidebarSummary: Equatable {
    let worklaneID: WorklaneID
    let badgeText: String
    let topLabel: String?
    let primaryText: String
    let contextPrefixText: String?
    let focusedPaneLineIndex: Int
    let statusText: String?
    let statusSymbolName: String?
    let detailLines: [WorklaneSidebarDetailLine]
    let paneRows: [WorklaneSidebarPaneRow]
    let overflowText: String?
    let attentionState: WorklaneAttentionState?
    let interactionKind: PaneInteractionKind?
    let interactionLabel: String?
    let interactionSymbolName: String?
    let taskProgress: PaneAgentTaskProgress?
    let isWorking: Bool
    let isActive: Bool
    let color: WorklaneColor?
    let bookmarkOriginID: UUID?

    var title: String { topLabel ?? "" }
    var contextText: String {
        if let paneRow = paneRows.first(where: \.isFocused) ?? paneRows.first {
            return [paneRow.trailingText, paneRow.detailText]
                .compactMap(WorklaneContextFormatter.trimmed)
                .joined(separator: " · ")
        }

        return detailLines.first?.text ?? ""
    }
    var showsGeneratedTitle: Bool { topLabel != nil }

    init(
        worklaneID: WorklaneID,
        badgeText: String,
        topLabel: String? = nil,
        primaryText: String,
        contextPrefixText: String? = nil,
        focusedPaneLineIndex: Int = 0,
        statusText: String? = nil,
        statusSymbolName: String? = nil,
        detailLines: [WorklaneSidebarDetailLine] = [],
        paneRows: [WorklaneSidebarPaneRow] = [],
        overflowText: String? = nil,
        attentionState: WorklaneAttentionState? = nil,
        interactionKind: PaneInteractionKind? = nil,
        interactionLabel: String? = nil,
        interactionSymbolName: String? = nil,
        taskProgress: PaneAgentTaskProgress? = nil,
        isWorking: Bool = false,
        isActive: Bool,
        color: WorklaneColor? = nil,
        bookmarkOriginID: UUID? = nil
    ) {
        self.worklaneID = worklaneID
        self.badgeText = badgeText
        self.topLabel = topLabel
        self.primaryText = primaryText
        self.contextPrefixText = contextPrefixText
        self.focusedPaneLineIndex = focusedPaneLineIndex
        self.statusText = statusText
        self.statusSymbolName = statusSymbolName
        self.detailLines = detailLines
        self.paneRows = paneRows
        self.overflowText = overflowText
        self.attentionState = attentionState
        self.interactionKind = interactionKind
        self.interactionLabel = interactionLabel
        self.interactionSymbolName = interactionSymbolName
        self.taskProgress = taskProgress
        self.isWorking = isWorking
        self.isActive = isActive
        self.color = color
        self.bookmarkOriginID = bookmarkOriginID
    }
}
