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

enum WorkspaceSidebarLeadingAccessory: Equatable {
    case home
    case agent(AgentTool)
}

struct WorkspaceSidebarSummary: Equatable {
    let workspaceID: WorkspaceID
    let badgeText: String
    let topLabel: String?
    let primaryText: String
    let focusedPaneLineIndex: Int
    let statusText: String?
    let stateBadgeText: String?
    let detailLines: [WorkspaceSidebarDetailLine]
    let paneRows: [WorkspaceSidebarPaneRow]
    let overflowText: String?
    let leadingAccessory: WorkspaceSidebarLeadingAccessory?
    let attentionState: WorkspaceAttentionState?
    let artifactLink: WorkspaceArtifactLink?
    let isWorking: Bool
    let isActive: Bool

    var title: String { topLabel ?? "" }
    var contextText: String { paneRows.first?.detailText ?? detailLines.first?.text ?? "" }
    var showsGeneratedTitle: Bool { topLabel != nil }

    init(
        workspaceID: WorkspaceID,
        badgeText: String,
        topLabel: String? = nil,
        primaryText: String,
        focusedPaneLineIndex: Int = 0,
        statusText: String? = nil,
        stateBadgeText: String? = nil,
        detailLines: [WorkspaceSidebarDetailLine] = [],
        paneRows: [WorkspaceSidebarPaneRow] = [],
        overflowText: String? = nil,
        leadingAccessory: WorkspaceSidebarLeadingAccessory? = nil,
        attentionState: WorkspaceAttentionState? = nil,
        artifactLink: WorkspaceArtifactLink? = nil,
        isWorking: Bool = false,
        isActive: Bool
    ) {
        self.workspaceID = workspaceID
        self.badgeText = badgeText
        self.topLabel = topLabel
        self.primaryText = primaryText
        self.focusedPaneLineIndex = focusedPaneLineIndex
        self.statusText = statusText
        self.stateBadgeText = stateBadgeText
        self.detailLines = detailLines
        self.paneRows = paneRows
        self.overflowText = overflowText
        self.leadingAccessory = leadingAccessory
        self.attentionState = attentionState
        self.artifactLink = artifactLink
        self.isWorking = isWorking
        self.isActive = isActive
    }

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
        leadingAccessory: WorkspaceSidebarLeadingAccessory? = nil,
        attentionState: WorkspaceAttentionState? = nil,
        artifactLink: WorkspaceArtifactLink? = nil,
        isWorking: Bool = false,
        isActive: Bool
    ) {
        self.init(
            workspaceID: workspaceID,
            badgeText: badgeText,
            topLabel: topLabel,
            primaryText: primaryText,
            focusedPaneLineIndex: focusedPaneLineIndex,
            statusText: statusText,
            stateBadgeText: attentionState.map(\.defaultSidebarStateBadgeText),
            detailLines: detailLines,
            paneRows: paneRows,
            overflowText: overflowText,
            leadingAccessory: leadingAccessory,
            attentionState: attentionState,
            artifactLink: artifactLink,
            isWorking: isWorking,
            isActive: isActive
        )
    }

    init(
        workspaceID: WorkspaceID,
        title: String,
        badgeText: String,
        primaryText: String,
        statusText: String?,
        contextText: String,
        attentionState: WorkspaceAttentionState?,
        artifactLink: WorkspaceArtifactLink?,
        isActive: Bool,
        showsGeneratedTitle: Bool
    ) {
        self.init(
            workspaceID: workspaceID,
            badgeText: badgeText,
            topLabel: showsGeneratedTitle ? title : nil,
            primaryText: primaryText,
            focusedPaneLineIndex: 0,
            statusText: statusText,
            stateBadgeText: attentionState.map(\.defaultSidebarStateBadgeText),
            detailLines: WorkspaceContextFormatter.trimmed(contextText).map {
                [WorkspaceSidebarDetailLine(text: $0, emphasis: .secondary)]
            } ?? [],
            paneRows: [],
            overflowText: nil,
            leadingAccessory: nil,
            attentionState: attentionState,
            artifactLink: artifactLink,
            isWorking: attentionState == .running,
            isActive: isActive
        )
    }
}

extension WorkspaceAttentionState {
    var defaultSidebarStateBadgeText: String {
        switch self {
        case .needsInput:
            return "Needs input"
        case .unresolvedStop:
            return "Stopped early"
        case .running:
            return "Running"
        case .completed:
            return "Completed"
        }
    }
}
