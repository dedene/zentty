import AppKit

struct WorkspaceSidebarSummary: Equatable {
    let workspaceID: WorkspaceID
    let title: String
    let badgeText: String
    let primaryText: String
    let statusText: String?
    let contextText: String
    let attentionState: WorkspaceAttentionState?
    let artifactLink: WorkspaceArtifactLink?
    let isActive: Bool
    let showsGeneratedTitle: Bool
}

enum WorkspaceSidebarSummaryBuilder {
    static func summaries(
        for workspaces: [WorkspaceState],
        activeWorkspaceID: WorkspaceID
    ) -> [WorkspaceSidebarSummary] {
        workspaces.map { workspace in
            summary(for: workspace, isActive: workspace.id == activeWorkspaceID)
        }
    }

    static func summary(
        for workspace: WorkspaceState,
        isActive: Bool
    ) -> WorkspaceSidebarSummary {
        let focusedPane = workspace.paneStripState.focusedPane
        let metadata = workspace.paneStripState.focusedPaneID.flatMap { workspace.metadataByPaneID[$0] }
        let attention = WorkspaceAttentionSummaryBuilder.summary(for: workspace)
        let isGeneratedTitle = isGeneratedWorkspaceTitle(workspace.title)

        return WorkspaceSidebarSummary(
            workspaceID: workspace.id,
            title: workspace.title,
            badgeText: badge(for: workspace.title),
            primaryText: attention?.primaryText ?? firstNonEmpty(
                metadata?.title,
                metadata?.processName,
                focusedPane?.title
            ) ?? "shell",
            statusText: attention?.statusText,
            contextText: attention?.contextText ?? WorkspaceContextFormatter.contextText(for: metadata),
            attentionState: attention?.state,
            artifactLink: attention?.artifactLink,
            isActive: isActive,
            showsGeneratedTitle: !isGeneratedTitle
        )
    }

    private static func badge(for title: String) -> String {
        let words = title
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)

        if words.count >= 2 {
            return words
                .prefix(2)
                .compactMap { $0.first.map { String($0).uppercased() } }
                .joined()
        }

        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let firstCharacter = trimmedTitle.first else {
            return "?"
        }

        return String(firstCharacter).uppercased()
    }

    private static func firstNonEmpty(_ values: String?...) -> String? {
        values.compactMap(WorkspaceContextFormatter.trimmed).first
    }

    private static func isGeneratedWorkspaceTitle(_ title: String) -> Bool {
        let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.uppercased() == "MAIN" {
            return true
        }

        return normalized.range(
            of: #"^WS \d+$"#,
            options: .regularExpression
        ) != nil
    }
}
