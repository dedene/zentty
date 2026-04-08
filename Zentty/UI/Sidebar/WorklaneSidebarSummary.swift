import AppKit

enum WorklaneSidebarDetailEmphasis: Equatable {
    case primary
    case secondary
}

struct WorklaneSidebarDetailLine: Equatable {
    let text: String
    let emphasis: WorklaneSidebarDetailEmphasis
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
        isWorking: Bool
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
    let isWorking: Bool
    let isActive: Bool

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
        isWorking: Bool = false,
        isActive: Bool
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
        self.isWorking = isWorking
        self.isActive = isActive
    }
}
