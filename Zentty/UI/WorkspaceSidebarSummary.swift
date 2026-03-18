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

enum WorkspaceSidebarSummaryBuilder {
    static func summaries(
        for workspaces: [WorkspaceState],
        activeWorkspaceID: WorkspaceID
    ) -> [WorkspaceSidebarSummary] {
        let baseSummaries = workspaces.map { workspace in
            summary(for: workspace, isActive: workspace.id == activeWorkspaceID)
        }

        return disambiguatedSummaries(
            baseSummaries,
            for: workspaces
        )
    }

    static func summary(
        for workspace: WorkspaceState,
        isActive: Bool
    ) -> WorkspaceSidebarSummary {
        let focusedPane = workspace.paneStripState.focusedPane
        let focusedPaneID = workspace.paneStripState.focusedPaneID
        let focusedMetadata = focusedPaneID.flatMap { workspace.metadataByPaneID[$0] }
        let attention = WorkspaceAttentionSummaryBuilder.summary(for: workspace)
        let badgeText = badge(for: workspace.title)
        let primaryText = workspacePrimaryText(
            focusedMetadata: focusedMetadata,
            focusedPaneTitle: focusedPane?.title
        )
        let topLabel = visibleTopLabel(
            workspace.title,
            primaryText: primaryText
        )
        let allDetailTexts = paneDetailTexts(
            for: workspace,
            primaryText: primaryText
        )
        let detailLines = Array(allDetailTexts.prefix(3)).enumerated().map { index, text in
            WorkspaceSidebarDetailLine(
                text: text,
                emphasis: index == 0 ? .primary : .secondary
            )
        }
        let overflowText = paneOverflowText(
            detailTextCount: allDetailTexts.count,
            visibleLineCount: detailLines.count
        )

        if let attention {
            return WorkspaceSidebarSummary(
                workspaceID: workspace.id,
                badgeText: badgeText,
                topLabel: topLabel,
                primaryText: attention.primaryText,
                statusText: attention.statusText,
                detailLines: WorkspaceContextFormatter.trimmed(attention.contextText).map {
                    [WorkspaceSidebarDetailLine(text: $0, emphasis: .primary)]
                } ?? [],
                overflowText: nil,
                leadingAccessory: .agent(attention.tool),
                attentionState: attention.state,
                artifactLink: attention.artifactLink,
                isActive: isActive
            )
        }

        return WorkspaceSidebarSummary(
            workspaceID: workspace.id,
            badgeText: badgeText,
            topLabel: topLabel,
            primaryText: primaryText,
            statusText: nil,
            detailLines: detailLines,
            overflowText: overflowText,
            leadingAccessory: leadingAccessory(for: focusedMetadata),
            attentionState: nil,
            artifactLink: nil,
            isActive: isActive
        )
    }

    private static func workspacePrimaryText(
        focusedMetadata: TerminalMetadata?,
        focusedPaneTitle: String?
    ) -> String {
        if let path = focusedMetadata?.currentWorkingDirectory,
           let compactPath = WorkspaceContextFormatter.compactSidebarPath(path) {
            return compactPath
        }

        if let recognized = AgentToolRecognizer.recognize(metadata: focusedMetadata) {
            return recognized.displayName
        }

        if let processName = WorkspaceContextFormatter.trimmed(focusedMetadata?.processName) {
            return WorkspaceContextFormatter.normalizeSidebarFallbackTitle(processName)
        }

        if let title = WorkspaceContextFormatter.trimmed(focusedPaneTitle) {
            return WorkspaceContextFormatter.normalizeSidebarFallbackTitle(title)
        }

        return "Shell"
    }

    private static func paneDetailTexts(
        for workspace: WorkspaceState,
        primaryText: String
    ) -> [String] {
        let panes = orderedPanesForSidebar(workspace)
        var seen = Set<String>()
        var detailTexts: [String] = []

        for pane in panes {
            let metadata = workspace.metadataByPaneID[pane.id]
            guard metadata != nil else {
                continue
            }

            guard let detailText = WorkspaceContextFormatter.paneDetailLine(
                metadata: metadata,
                fallbackTitle: pane.title
            ) else {
                continue
            }

            if detailText.caseInsensitiveCompare(primaryText) == .orderedSame {
                continue
            }

            guard seen.insert(detailText).inserted else {
                continue
            }

            detailTexts.append(detailText)
        }

        return detailTexts
    }

    private static func paneOverflowText(
        detailTextCount: Int,
        visibleLineCount: Int
    ) -> String? {
        let overflowCount = detailTextCount - visibleLineCount
        guard overflowCount > 0 else {
            return nil
        }

        return overflowCount == 1 ? "+1 more pane" : "+\(overflowCount) more panes"
    }

    private static func orderedPanesForSidebar(_ workspace: WorkspaceState) -> [PaneState] {
        let focusedPaneID = workspace.paneStripState.focusedPaneID

        return workspace.paneStripState.panes.sorted { lhs, rhs in
            switch (lhs.id == focusedPaneID, rhs.id == focusedPaneID) {
            case (true, false):
                return true
            case (false, true):
                return false
            default:
                return lhs.id.rawValue < rhs.id.rawValue
            }
        }
    }

    private static func leadingAccessory(for metadata: TerminalMetadata?) -> WorkspaceSidebarLeadingAccessory? {
        guard let path = metadata?.currentWorkingDirectory else {
            return nil
        }

        return WorkspaceContextFormatter.compactSidebarPath(path) == "~" ? .home : nil
    }

    private static func visibleTopLabel(
        _ title: String,
        primaryText: String
    ) -> String? {
        let normalizedTitle = WorkspaceContextFormatter.trimmed(title)
        guard let normalizedTitle, isGeneratedWorkspaceTitle(normalizedTitle) == false else {
            return nil
        }

        let normalizedPrimaryText = primaryText.trimmingCharacters(in: .whitespacesAndNewlines)
        let primaryLeaf = normalizedPrimaryText
            .split(separator: "/")
            .last
            .map(String.init) ?? normalizedPrimaryText

        guard normalizedTitle.caseInsensitiveCompare(normalizedPrimaryText) != .orderedSame,
              normalizedTitle.caseInsensitiveCompare(primaryLeaf) != .orderedSame else {
            return nil
        }

        return normalizedTitle
    }

    private static func disambiguatedSummaries(
        _ summaries: [WorkspaceSidebarSummary],
        for workspaces: [WorkspaceState]
    ) -> [WorkspaceSidebarSummary] {
        let pathsByWorkspaceID = Dictionary(
            uniqueKeysWithValues: workspaces.compactMap { workspace in
                focusedSidebarPath(for: workspace).map { (workspace.id, $0) }
            }
        )

        var requiredSegmentCountByWorkspaceID = Dictionary(
            uniqueKeysWithValues: pathsByWorkspaceID.keys.map { ($0, 1) }
        )

        while true {
            let labelsByWorkspaceID = summaries.reduce(into: [String: [WorkspaceID]]()) { result, summary in
                let label = disambiguatedPrimaryText(
                    for: summary,
                    pathsByWorkspaceID: pathsByWorkspaceID,
                    requiredSegmentCountByWorkspaceID: requiredSegmentCountByWorkspaceID
                ) ?? summary.primaryText

                result[label.lowercased(), default: []].append(summary.workspaceID)
            }

            var didExpandAnyPath = false

            for workspaceIDs in labelsByWorkspaceID.values where workspaceIDs.count > 1 {
                for workspaceID in workspaceIDs {
                    guard let path = pathsByWorkspaceID[workspaceID],
                          let maxSegmentCount = WorkspaceContextFormatter.maxSidebarPathSegments(path) else {
                        continue
                    }

                    let currentSegmentCount = requiredSegmentCountByWorkspaceID[workspaceID] ?? 1
                    guard currentSegmentCount < maxSegmentCount else {
                        continue
                    }

                    requiredSegmentCountByWorkspaceID[workspaceID] = currentSegmentCount + 1
                    didExpandAnyPath = true
                }
            }

            guard didExpandAnyPath else {
                break
            }
        }

        return zip(workspaces, summaries).map { workspace, summary in
            let disambiguatedPrimaryText = disambiguatedPrimaryText(
                for: summary,
                pathsByWorkspaceID: pathsByWorkspaceID,
                requiredSegmentCountByWorkspaceID: requiredSegmentCountByWorkspaceID
            ) ?? summary.primaryText

            return WorkspaceSidebarSummary(
                workspaceID: summary.workspaceID,
                badgeText: summary.badgeText,
                topLabel: visibleTopLabel(
                    workspace.title,
                    primaryText: disambiguatedPrimaryText
                ),
                primaryText: disambiguatedPrimaryText,
                statusText: summary.statusText,
                detailLines: summary.detailLines,
                overflowText: summary.overflowText,
                leadingAccessory: summary.leadingAccessory,
                attentionState: summary.attentionState,
                artifactLink: summary.artifactLink,
                isActive: summary.isActive
            )
        }
    }

    private static func disambiguatedPrimaryText(
        for summary: WorkspaceSidebarSummary,
        pathsByWorkspaceID: [WorkspaceID: String],
        requiredSegmentCountByWorkspaceID: [WorkspaceID: Int]
    ) -> String? {
        guard summary.attentionState == nil,
              let path = pathsByWorkspaceID[summary.workspaceID],
              let compactPrimaryText = WorkspaceContextFormatter.compactSidebarPath(path),
              compactPrimaryText.caseInsensitiveCompare(summary.primaryText) == .orderedSame else {
            return nil
        }

        let requiredSegmentCount = requiredSegmentCountByWorkspaceID[summary.workspaceID] ?? 1
        return WorkspaceContextFormatter.compactSidebarPath(
            path,
            minimumSegments: requiredSegmentCount
        )
    }

    private static func focusedSidebarPath(for workspace: WorkspaceState) -> String? {
        guard let focusedPaneID = workspace.paneStripState.focusedPaneID else {
            return nil
        }

        return workspace.metadataByPaneID[focusedPaneID]?.currentWorkingDirectory
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
