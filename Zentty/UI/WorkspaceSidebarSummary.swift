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
    private struct WorkspaceSidebarIdentity {
        let paneID: PaneID?
        let primaryText: String
        let cwdPath: String?
        let isCwdDerived: Bool
    }

    private struct PaneDetailCandidate {
        let paneID: PaneID
        let metadata: TerminalMetadata?
        let fallbackTitle: String?
        let cwdPath: String?
        let maxPathSegments: Int
    }

    static func summaries(
        for workspaces: [WorkspaceState],
        activeWorkspaceID: WorkspaceID
    ) -> [WorkspaceSidebarSummary] {
        let identitiesByWorkspaceID = Dictionary(
            uniqueKeysWithValues: workspaces.map { workspace in
                (workspace.id, workspaceIdentity(for: workspace))
            }
        )
        let baseSummaries = workspaces.map { workspace in
            summary(
                for: workspace,
                isActive: workspace.id == activeWorkspaceID,
                identity: identitiesByWorkspaceID[workspace.id]
            )
        }

        return disambiguatedSummaries(
            baseSummaries,
            identitiesByWorkspaceID: identitiesByWorkspaceID,
            workspaces: workspaces
        )
    }

    static func summary(
        for workspace: WorkspaceState,
        isActive: Bool
    ) -> WorkspaceSidebarSummary {
        summary(
            for: workspace,
            isActive: isActive,
            identity: workspaceIdentity(for: workspace)
        )
    }

    private static func summary(
        for workspace: WorkspaceState,
        isActive: Bool,
        identity: WorkspaceSidebarIdentity?
    ) -> WorkspaceSidebarSummary {
        let attention = WorkspaceAttentionSummaryBuilder.summary(for: workspace)
        let badgeText = badge(for: workspace.title)
        let identity = identity ?? workspaceIdentity(for: workspace)
        let primaryText = identity.primaryText
        let topLabel = visibleTopLabel(
            workspace.title,
            primaryText: primaryText
        )
        let sidebarDetailLines = detailLines(
            for: workspace,
            primaryText: primaryText
        )

        if let attention {
            return WorkspaceSidebarSummary(
                workspaceID: workspace.id,
                badgeText: badgeText,
                topLabel: topLabel,
                primaryText: primaryText,
                statusText: attention.statusText,
                detailLines: sidebarDetailLines,
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
            detailLines: sidebarDetailLines,
            overflowText: nil,
            leadingAccessory: leadingAccessory(for: identity.cwdPath),
            attentionState: nil,
            artifactLink: nil,
            isActive: isActive
        )
    }

    private static func workspaceIdentity(for workspace: WorkspaceState) -> WorkspaceSidebarIdentity {
        let orderedPanes = orderedPanesForSidebar(workspace)

        for pane in orderedPanes {
            guard let metadata = workspace.metadataByPaneID[pane.id],
                  let path = metadata.currentWorkingDirectory,
                  let compactPath = WorkspaceContextFormatter.compactSidebarPath(path) else {
                continue
            }

            return WorkspaceSidebarIdentity(
                paneID: pane.id,
                primaryText: compactPath,
                cwdPath: path,
                isCwdDerived: true
            )
        }

        guard let identityPane = orderedPanes.first else {
            return WorkspaceSidebarIdentity(
                paneID: workspace.paneStripState.focusedPaneID,
                primaryText: "Shell",
                cwdPath: nil,
                isCwdDerived: false
            )
        }

        let identityMetadata = workspace.metadataByPaneID[identityPane.id]

        if let recognized = AgentToolRecognizer.recognize(metadata: identityMetadata) {
            return WorkspaceSidebarIdentity(
                paneID: identityPane.id,
                primaryText: recognized.displayName,
                cwdPath: nil,
                isCwdDerived: false
            )
        }

        if let processName = WorkspaceContextFormatter.normalizeSidebarFallbackTitle(
            identityMetadata?.processName
        ) {
            return WorkspaceSidebarIdentity(
                paneID: identityPane.id,
                primaryText: processName,
                cwdPath: nil,
                isCwdDerived: false
            )
        }

        if let title = WorkspaceContextFormatter.normalizeSidebarFallbackTitle(
            identityMetadata?.title
        ) ?? WorkspaceContextFormatter.normalizeSidebarFallbackTitle(
            identityPane.title
        ) {
            return WorkspaceSidebarIdentity(
                paneID: identityPane.id,
                primaryText: title,
                cwdPath: nil,
                isCwdDerived: false
            )
        }

        return WorkspaceSidebarIdentity(
            paneID: identityPane.id,
            primaryText: "Shell",
            cwdPath: nil,
            isCwdDerived: false
        )
    }

    private static func paneDetailTexts(
        for workspace: WorkspaceState,
        primaryText: String
    ) -> [String] {
        let panes = orderedPanesForSidebar(workspace)
        if panes.count == 1 {
            guard let pane = panes.first else {
                return []
            }

            let metadata = workspace.metadataByPaneID[pane.id]
            guard let detailText = WorkspaceContextFormatter.singlePaneSidebarDetailLine(
                metadata: metadata
            ) else {
                return []
            }

            return detailTextRepeatsPrimary(detailText, primaryText: primaryText)
                ? []
                : [detailText]
        }

        let candidates = panes.dropFirst().compactMap { pane in
            paneDetailCandidate(
                for: pane,
                in: workspace
            )
        }

        return resolvedMultiPaneDetailTexts(
            candidates,
            primaryText: primaryText
        )
    }

    private static func detailLines(
        for workspace: WorkspaceState,
        primaryText: String
    ) -> [WorkspaceSidebarDetailLine] {
        paneDetailTexts(
            for: workspace,
            primaryText: primaryText
        ).enumerated().map { index, text in
            WorkspaceSidebarDetailLine(
                text: text,
                emphasis: index == 0 ? .primary : .secondary
            )
        }
    }

    private static func orderedPanesForSidebar(_ workspace: WorkspaceState) -> [PaneState] {
        workspace.paneStripState.panes
    }

    private static func paneDetailCandidate(
        for pane: PaneState,
        in workspace: WorkspaceState
    ) -> PaneDetailCandidate? {
        let metadata = workspace.metadataByPaneID[pane.id]
        let cwdPath = metadata?.currentWorkingDirectory
        let maxPathSegments = cwdPath.flatMap {
            WorkspaceContextFormatter.maxSidebarPathSegments($0)
        } ?? 1

        guard WorkspaceContextFormatter.paneDetailLine(
            metadata: metadata,
            fallbackTitle: pane.title
        ) != nil else {
            return nil
        }

        return PaneDetailCandidate(
            paneID: pane.id,
            metadata: metadata,
            fallbackTitle: pane.title,
            cwdPath: cwdPath,
            maxPathSegments: maxPathSegments
        )
    }

    private static func resolvedMultiPaneDetailTexts(
        _ candidates: [PaneDetailCandidate],
        primaryText: String
    ) -> [String] {
        guard candidates.isEmpty == false else {
            return []
        }

        let candidatesByPaneID = Dictionary(
            uniqueKeysWithValues: candidates.map { ($0.paneID, $0) }
        )
        var minimumPathSegmentsByPaneID = Dictionary(
            uniqueKeysWithValues: candidates.map { ($0.paneID, 1) }
        )

        while true {
            let renderedDetails = candidates.compactMap { candidate -> (PaneID, String)? in
                guard let text = renderedDetailText(
                    for: candidate,
                    minimumPathSegments: minimumPathSegmentsByPaneID[candidate.paneID] ?? 1
                ) else {
                    return nil
                }

                return (candidate.paneID, text)
            }

            var paneIDsToExpand = Set<PaneID>()

            for (paneID, detailText) in renderedDetails {
                guard detailTextRepeatsPrimary(detailText, primaryText: primaryText),
                      canExpandPath(
                        for: candidatesByPaneID[paneID],
                        minimumPathSegments: minimumPathSegmentsByPaneID[paneID] ?? 1
                      ) else {
                    continue
                }

                paneIDsToExpand.insert(paneID)
            }

            let detailTextsByLowercasedValue = Dictionary(
                grouping: renderedDetails,
                by: { $0.1.lowercased() }
            )
            for renderedGroup in detailTextsByLowercasedValue.values where renderedGroup.count > 1 {
                for (paneID, _) in renderedGroup where canExpandPath(
                    for: candidatesByPaneID[paneID],
                    minimumPathSegments: minimumPathSegmentsByPaneID[paneID] ?? 1
                ) {
                    paneIDsToExpand.insert(paneID)
                }
            }

            guard paneIDsToExpand.isEmpty == false else {
                return renderedDetails.map(\.1)
            }

            for paneID in paneIDsToExpand {
                minimumPathSegmentsByPaneID[paneID, default: 1] += 1
            }
        }
    }

    private static func renderedDetailText(
        for candidate: PaneDetailCandidate,
        minimumPathSegments: Int
    ) -> String? {
        WorkspaceContextFormatter.paneDetailLine(
            metadata: candidate.metadata,
            fallbackTitle: candidate.fallbackTitle,
            minimumPathSegments: minimumPathSegments
        )
    }

    private static func canExpandPath(
        for candidate: PaneDetailCandidate?,
        minimumPathSegments: Int
    ) -> Bool {
        guard let candidate, candidate.cwdPath != nil else {
            return false
        }

        return minimumPathSegments < candidate.maxPathSegments
    }

    private static func leadingAccessory(for path: String?) -> WorkspaceSidebarLeadingAccessory? {
        guard let path else {
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
        identitiesByWorkspaceID: [WorkspaceID: WorkspaceSidebarIdentity],
        workspaces: [WorkspaceState]
    ) -> [WorkspaceSidebarSummary] {
        let cwdDerivedPaths: [(WorkspaceID, String)] = identitiesByWorkspaceID.compactMap { workspaceID, identity in
                guard identity.isCwdDerived, let cwdPath = identity.cwdPath else {
                    return nil
                }

                return (workspaceID, cwdPath)
            }
        let pathsByWorkspaceID = Dictionary(uniqueKeysWithValues: cwdDerivedPaths)

        var requiredSegmentCountByWorkspaceID = Dictionary(
            uniqueKeysWithValues: Array(pathsByWorkspaceID.keys).map { ($0, 1) }
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

    private static func detailTextRepeatsPrimary(
        _ detailText: String,
        primaryText: String
    ) -> Bool {
        let normalizedDetailText = detailText.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedPrimaryText = primaryText.trimmingCharacters(in: .whitespacesAndNewlines)
        let primaryLeaf = normalizedPrimaryText
            .split(separator: "/")
            .last
            .map(String.init) ?? normalizedPrimaryText

        return normalizedDetailText.caseInsensitiveCompare(normalizedPrimaryText) == .orderedSame
            || normalizedDetailText.caseInsensitiveCompare(primaryLeaf) == .orderedSame
    }
}
