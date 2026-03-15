import AppKit

enum WorkspaceAttentionState: String, Equatable {
    case needsInput
    case running
    case unread
}

struct WorkspaceSidebarSummary: Equatable {
    let workspaceID: WorkspaceID
    let title: String
    let badgeText: String
    let summaryText: String
    let detailText: String
    let paneCountText: String
    let attentionState: WorkspaceAttentionState?
    let attentionText: String?
    let unreadCount: Int?
    let isActive: Bool
    let showsGeneratedTitle: Bool
    let showsPaneCount: Bool
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

        let summaryText = firstNonEmpty(
            nil,
            metadata?.title,
            metadata?.processName,
            focusedPane?.title
        ) ?? "shell"

        let detailText = detailSummary(metadata: metadata)
        let isGeneratedTitle = isGeneratedWorkspaceTitle(workspace.title)

        return WorkspaceSidebarSummary(
            workspaceID: workspace.id,
            title: workspace.title,
            badgeText: badge(for: workspace.title),
            summaryText: summaryText,
            detailText: detailText,
            paneCountText: "",
            attentionState: nil,
            attentionText: nil,
            unreadCount: nil,
            isActive: isActive,
            showsGeneratedTitle: !isGeneratedTitle,
            showsPaneCount: false
        )
    }

    private static func detailSummary(
        metadata: TerminalMetadata?
    ) -> String {
        let compactDirectory = metadata?.currentWorkingDirectory.flatMap(compactDirectoryName)
        let branch = trimmed(metadata?.gitBranch)
        let components = [compactDirectory, branch].compactMap { $0 }

        return components.joined(separator: " • ")
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

    private static func compactDirectoryName(_ path: String) -> String? {
        let trimmedPath = trimmed(path)
        guard let trimmedPath else {
            return nil
        }

        let homePath = NSHomeDirectory()
        let normalizedPath = trimmedPath.hasPrefix(homePath)
            ? trimmedPath.replacingOccurrences(of: homePath, with: "~")
            : trimmedPath

        let components = normalizedPath.split(separator: "/").map(String.init)
        guard let lastComponent = components.last, !lastComponent.isEmpty else {
            return normalizedPath == "~" ? "~" : nil
        }

        return lastComponent == "~" ? "~" : lastComponent
    }

    private static func firstNonEmpty(_ values: String?...) -> String? {
        values.compactMap(trimmed).first
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }

        return value
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
