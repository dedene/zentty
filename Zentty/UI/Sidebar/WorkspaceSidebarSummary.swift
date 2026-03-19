import AppKit

enum WorkspaceSidebarDetailEmphasis: Equatable {
    case primary
    case secondary
}

struct WorkspaceSidebarDetailLine: Equatable {
    let text: String
    let emphasis: WorkspaceSidebarDetailEmphasis
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
    let statusText: String?
    let detailLines: [WorkspaceSidebarDetailLine]
    let overflowText: String?
    let leadingAccessory: WorkspaceSidebarLeadingAccessory?
    let attentionState: WorkspaceAttentionState?
    let artifactLink: WorkspaceArtifactLink?
    let isActive: Bool

    var title: String { topLabel ?? "" }
    var contextText: String { detailLines.first?.text ?? "" }
    var showsGeneratedTitle: Bool { topLabel != nil }

    init(
        workspaceID: WorkspaceID,
        badgeText: String,
        topLabel: String? = nil,
        primaryText: String,
        statusText: String? = nil,
        detailLines: [WorkspaceSidebarDetailLine] = [],
        overflowText: String? = nil,
        leadingAccessory: WorkspaceSidebarLeadingAccessory? = nil,
        attentionState: WorkspaceAttentionState? = nil,
        artifactLink: WorkspaceArtifactLink? = nil,
        isActive: Bool
    ) {
        self.workspaceID = workspaceID
        self.badgeText = badgeText
        self.topLabel = topLabel
        self.primaryText = primaryText
        self.statusText = statusText
        self.detailLines = detailLines
        self.overflowText = overflowText
        self.leadingAccessory = leadingAccessory
        self.attentionState = attentionState
        self.artifactLink = artifactLink
        self.isActive = isActive
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
            statusText: statusText,
            detailLines: WorkspaceContextFormatter.trimmed(contextText).map {
                [WorkspaceSidebarDetailLine(text: $0, emphasis: .secondary)]
            } ?? [],
            overflowText: nil,
            leadingAccessory: nil,
            attentionState: attentionState,
            artifactLink: artifactLink,
            isActive: isActive
        )
    }
}
