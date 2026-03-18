import AppKit

// MARK: - Sidebar Node Tree Model

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
        let panes = workspace.paneStripState.panes
        let attention = WorkspaceAttentionSummaryBuilder.summary(for: workspace)

        // 1. Build per-pane data
        struct PaneData {
            let paneID: PaneID
            let primaryText: String
            let attentionState: WorkspaceAttentionState?
            let gitBranch: String?
            let prNumber: String?
            let isFocused: Bool
        }

        let paneDataList: [PaneData] = panes.map { pane in
            let metadata = workspace.metadataByPaneID[pane.id]
            let paneContext = workspace.paneContextByPaneID[pane.id]
            let agentStatus = workspace.agentStatusByPaneID[pane.id]

            // Resolve primaryText
            let primaryText: String
            if let agentStatus {
                primaryText = firstNonEmpty(
                    agentStatus.tool.displayName,
                    resolveDirectoryName(from: metadata, paneContext: paneContext),
                    metadata?.processName,
                    pane.title
                ) ?? "shell"
            } else {
                primaryText = firstNonEmpty(
                    resolveDirectoryName(from: metadata, paneContext: paneContext),
                    metadata?.processName,
                    pane.title
                ) ?? "shell"
            }

            // Map agent state to attention state
            let paneAttention: WorkspaceAttentionState? = agentStatus.map { mapAttentionState($0.state) }

            // Git branch
            let gitBranch = WorkspaceContextFormatter.trimmed(metadata?.gitBranch)

            // PR number from inferred artifact
            let prNumber: String?
            if let artifact = workspace.inferredArtifactByPaneID[pane.id],
               artifact.kind == .pullRequest {
                prNumber = extractPRNumber(from: artifact.label)
            } else {
                prNumber = nil
            }

            let isFocused = workspace.paneStripState.focusedPaneID == pane.id

            return PaneData(
                paneID: pane.id,
                primaryText: primaryText,
                attentionState: paneAttention,
                gitBranch: gitBranch,
                prNumber: prNumber,
                isFocused: isFocused
            )
        }

        // 2. Determine git context placement
        let nonNilBranches = paneDataList.compactMap(\.gitBranch)
        let uniqueBranches = Set(nonNilBranches)
        let isSharedBranch = uniqueBranches.count <= 1

        let sharedBranch: String?
        if isSharedBranch {
            sharedBranch = nonNilBranches.first
        } else {
            sharedBranch = nil
        }

        // If shared branch, collect PR numbers from all panes to append to header
        let sharedPRNumber: String?
        if isSharedBranch {
            sharedPRNumber = paneDataList.compactMap(\.prNumber).first
        } else {
            sharedPRNumber = nil
        }

        let headerGitContext: String
        if let branch = sharedBranch {
            if let pr = sharedPRNumber {
                headerGitContext = "\(branch) \u{2022} #\(pr)"
            } else {
                headerGitContext = branch
            }
        } else {
            headerGitContext = ""
        }

        // 3. Build header
        let header = WorkspaceHeaderSummary(
            workspaceID: workspace.id,
            primaryText: paneDataList.first?.primaryText ?? "shell",
            paneCount: panes.count,
            attentionState: attention?.state,
            statusText: attention?.statusText,
            gitContext: headerGitContext,
            artifactLink: attention?.artifactLink,
            isActive: isActive
        )

        // 4. Build pane summaries (empty for single-pane)
        let paneSummaries: [PaneSidebarSummary]
        if panes.count <= 1 {
            paneSummaries = []
        } else {
            paneSummaries = paneDataList.map { data in
                let paneGitContext: String
                if isSharedBranch {
                    paneGitContext = ""
                } else {
                    if let branch = data.gitBranch {
                        if let pr = data.prNumber {
                            paneGitContext = "\(branch) \u{2022} #\(pr)"
                        } else {
                            paneGitContext = branch
                        }
                    } else {
                        paneGitContext = ""
                    }
                }

                return PaneSidebarSummary(
                    paneID: data.paneID,
                    workspaceID: workspace.id,
                    primaryText: data.primaryText,
                    attentionState: data.attentionState,
                    gitContext: paneGitContext,
                    isFocused: data.isFocused
                )
            }
        }

        return WorkspaceSidebarNode(header: header, panes: paneSummaries)
    }

    // MARK: - Private Helpers

    private static func resolveDirectoryName(
        from metadata: TerminalMetadata?,
        paneContext: PaneShellContext?
    ) -> String? {
        if let cwd = metadata?.currentWorkingDirectory,
           let name = WorkspaceContextFormatter.compactDirectoryName(cwd),
           name != "~" {
            return name
        }

        if let title = metadata?.title,
           title.contains("/"),
           let name = WorkspaceContextFormatter.compactDirectoryName(title),
           name != "~" {
            return name
        }

        if let path = paneContext?.path,
           let name = WorkspaceContextFormatter.compactDirectoryName(path),
           name != "~" {
            return name
        }

        return nil
    }

    private static func firstNonEmpty(_ values: String?...) -> String? {
        values.compactMap(WorkspaceContextFormatter.trimmed).first
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

    private static func extractPRNumber(from label: String) -> String? {
        guard let range = label.range(of: #"#(\d+)"#, options: .regularExpression) else {
            return nil
        }

        let match = label[range]
        return String(match.dropFirst()) // drop the '#'
    }
}
