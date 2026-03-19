import AppKit

// Compatibility model for the grouped-sidebar work that already exists on main.
// The live app now renders flat row summaries, but these types keep the older
// group view code buildable while that WIP remains in the tree.
struct WorkspaceSidebarNode: Equatable {
    let header: WorkspaceHeaderSummary
    let panes: [PaneSidebarSummary]
}

struct WorkspaceHeaderSummary: Equatable {
    let workspaceID: WorkspaceID
    let primaryText: String
    let paneCount: Int
    let attentionState: WorkspaceAttentionState?
    let statusText: String?
    let gitContext: String
    let artifactLink: WorkspaceArtifactLink?
    let isActive: Bool
}

struct PaneSidebarSummary: Equatable {
    let paneID: PaneID
    let workspaceID: WorkspaceID
    let primaryText: String
    let attentionState: WorkspaceAttentionState?
    let gitContext: String
    let isFocused: Bool
}

enum WorkspaceSidebarNodeBuilder {
    static func nodes(
        for workspaces: [WorkspaceState],
        activeWorkspaceID: WorkspaceID
    ) -> [WorkspaceSidebarNode] {
        workspaces.map { workspace in
            node(for: workspace, isActive: workspace.id == activeWorkspaceID)
        }
    }

    static func node(
        for workspace: WorkspaceState,
        isActive: Bool
    ) -> WorkspaceSidebarNode {
        let summary = WorkspaceSidebarSummaryBuilder.summary(for: workspace, isActive: isActive)
        let orderedPanes = workspace.paneStripState.panes

        let header = WorkspaceHeaderSummary(
            workspaceID: workspace.id,
            primaryText: summary.primaryText,
            paneCount: orderedPanes.count,
            attentionState: summary.attentionState,
            statusText: summary.statusText,
            gitContext: summary.contextText,
            artifactLink: summary.artifactLink,
            isActive: isActive
        )

        let detailTexts = summary.detailLines.map(\.text)
        let detailTextByPaneID = Dictionary(
            uniqueKeysWithValues: zip(orderedPanes.dropFirst().map(\.id), detailTexts)
        )

        let panes = orderedPanes.dropFirst().map { pane in
            PaneSidebarSummary(
                paneID: pane.id,
                workspaceID: workspace.id,
                primaryText: panePrimaryText(for: pane, in: workspace),
                attentionState: workspace.auxiliaryStateByPaneID[pane.id]?.agentStatus.map { mapAttentionState($0.state) },
                gitContext: detailTextByPaneID[pane.id] ?? "",
                isFocused: workspace.paneStripState.focusedPaneID == pane.id
            )
        }

        return WorkspaceSidebarNode(header: header, panes: panes)
    }

    private static func panePrimaryText(for pane: PaneState, in workspace: WorkspaceState) -> String {
        let metadata = workspace.auxiliaryStateByPaneID[pane.id]?.metadata
        if let tool = AgentToolRecognizer.recognize(metadata: metadata) {
            return tool.displayName
        }
        if let path = metadata?.currentWorkingDirectory,
           let compact = WorkspaceContextFormatter.compactSidebarPath(path) {
            return compact
        }
        if let processName = WorkspaceContextFormatter.normalizeSidebarFallbackTitle(metadata?.processName) {
            return processName
        }
        if let title = WorkspaceContextFormatter.normalizeSidebarFallbackTitle(metadata?.title)
            ?? WorkspaceContextFormatter.normalizeSidebarFallbackTitle(pane.title) {
            return title
        }
        return "Shell"
    }

    private static func mapAttentionState(_ state: PaneAgentState) -> WorkspaceAttentionState {
        switch state {
        case .needsInput:
            return .needsInput
        case .unresolvedStop:
            return .unresolvedStop
        case .running:
            return .running
        case .completed:
            return .completed
        }
    }
}
