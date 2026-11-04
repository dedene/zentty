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

/// How a floated pane is shown, for the small glyph on its sidebar row
/// (`rectangle.on.rectangle` family, UX spec §13).
enum WorklaneSidebarFloatMode: Equatable {
    case floating
    case pip
    case minimized

    init(_ mode: FloatingPaneMode) {
        switch mode {
        case .floating: self = .floating
        case .pip: self = .pip
        case .minimized: self = .minimized
        }
    }

    var symbolName: String {
        switch self {
        case .floating: "rectangle.on.rectangle"
        case .pip: "pip"
        case .minimized: "dock.rectangle"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .floating: "Floating pane"
        case .pip: "Picture in picture"
        case .minimized: "Minimized pane"
        }
    }
}

struct WorklaneSidebarPaneRow: Equatable {
    /// Set for a floated pane; nil for a tile.
    var floatMode: WorklaneSidebarFloatMode?
    /// An overlay (temporary) float: it never keeps its worklane alive, so
    /// the pane next to it still counts as the worklane's last pane.
    var isTemporaryFloat = false
    let paneID: PaneID
    let primaryText: String
    let usesCustomTitle: Bool
    let animatesLocalCodexSpinner: Bool
    let trailingText: String?
    let detailText: String?
    let statusText: String?
    let statusSymbolName: String?
    let attentionState: WorklaneAttentionState?
    let interactionKind: PaneInteractionKind?
    let interactionLabel: String?
    let interactionSymbolName: String?
    var isFocused: Bool
    let isWorking: Bool
    let taskProgress: PaneAgentTaskProgress?
    let subagents: PaneAgentSubagentSummary?
    let serverPorts: [WorklaneSidebarServerPort]
    let isRemotePane: Bool
    let remotePaneLabel: String?

    init(
        paneID: PaneID,
        primaryText: String,
        usesCustomTitle: Bool = false,
        animatesLocalCodexSpinner: Bool = false,
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
        subagents: PaneAgentSubagentSummary? = nil,
        serverPorts: [WorklaneSidebarServerPort] = [],
        isRemotePane: Bool = false,
        remotePaneLabel: String? = nil
    ) {
        self.paneID = paneID
        self.primaryText = primaryText
        self.usesCustomTitle = usesCustomTitle
        self.animatesLocalCodexSpinner = animatesLocalCodexSpinner
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
        self.subagents = subagents
        self.serverPorts = serverPorts
        self.isRemotePane = isRemotePane
        self.remotePaneLabel = remotePaneLabel
    }
}

struct WorklaneSidebarSummary: Equatable {
    /// The pane rows the card lists: tiles, then floats (each a normal row).
    var displayPaneRows: [WorklaneSidebarPaneRow] { paneRows }
    let worklaneID: WorklaneID
    let badgeText: String
    let topLabel: String?
    let primaryText: String
    let primaryAnimatesLocalCodexSpinner: Bool
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
        primaryAnimatesLocalCodexSpinner: Bool = false,
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
        self.primaryAnimatesLocalCodexSpinner = primaryAnimatesLocalCodexSpinner
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
