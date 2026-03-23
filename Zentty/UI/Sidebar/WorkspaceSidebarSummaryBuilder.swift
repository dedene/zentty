import AppKit

enum WorkspaceSidebarSummaryBuilder {
    private struct SidebarStatusPresentation {
        let statusText: String?
        let stateBadgeText: String?
        let leadingAccessory: WorkspaceSidebarLeadingAccessory?
        let attentionState: WorkspaceAttentionState?
        let artifactLink: WorkspaceArtifactLink?
    }

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
        let orderedPaneContexts = orderedPaneContexts(for: workspace)
        let attention = WorkspaceAttentionSummaryBuilder.summary(for: workspace)
        let isWorking = workspaceIsWorking(for: workspace)
        let badgeText = badge(for: workspace.title)
        let identity = identity ?? workspaceIdentity(
            for: workspace,
            orderedPaneContexts: orderedPaneContexts
        )
        let primaryText = identity.primaryText
        let focusedPaneLineIndex = focusedPaneLineIndex(
            for: workspace,
            orderedPaneContexts: orderedPaneContexts
        )
        let topLabel = visibleTopLabel(
            workspace.title,
            primaryText: primaryText
        )
        let sidebarDetailLines = detailLines(
            for: workspace,
            primaryText: primaryText,
            orderedPaneContexts: orderedPaneContexts
        )
        let statusPresentation = sidebarStatusPresentation(
            for: workspace,
            attention: attention,
            isWorking: isWorking,
            primaryText: primaryText,
            fallbackLeadingAccessory: leadingAccessory(for: identity.cwdPath)
        )

        return WorkspaceSidebarSummary(
            workspaceID: workspace.id,
            badgeText: badgeText,
            topLabel: topLabel,
            primaryText: primaryText,
            focusedPaneLineIndex: focusedPaneLineIndex,
            statusText: statusPresentation.statusText,
            stateBadgeText: statusPresentation.stateBadgeText,
            detailLines: sidebarDetailLines,
            overflowText: nil,
            leadingAccessory: statusPresentation.leadingAccessory,
            attentionState: statusPresentation.attentionState,
            artifactLink: statusPresentation.artifactLink,
            isWorking: isWorking,
            isActive: isActive
        )
    }

    private static func sidebarStatusPresentation(
        for workspace: WorkspaceState,
        attention: WorkspaceAttentionSummary?,
        isWorking: Bool,
        primaryText: String,
        fallbackLeadingAccessory: WorkspaceSidebarLeadingAccessory?
    ) -> SidebarStatusPresentation {
        if let attention {
            let effectiveAttentionState: WorkspaceAttentionState = isWorking && attention.state == .completed
                ? .running
                : attention.state
            let statusText = explicitStatusText(
                for: effectiveAttentionState,
                actorName: attention.primaryText
            )
            return SidebarStatusPresentation(
                statusText: statusText,
                stateBadgeText: effectiveAttentionState.defaultSidebarStateBadgeText,
                leadingAccessory: .agent(attention.tool),
                attentionState: effectiveAttentionState,
                artifactLink: attention.artifactLink
            )
        }

        if isWorking {
            let tool = workingAgentTool(for: workspace)
            return SidebarStatusPresentation(
                statusText: explicitStatusText(
                    for: .running,
                    actorName: tool?.displayName ?? primaryText
                ),
                stateBadgeText: WorkspaceAttentionState.running.defaultSidebarStateBadgeText,
                leadingAccessory: tool.map(WorkspaceSidebarLeadingAccessory.agent) ?? fallbackLeadingAccessory,
                attentionState: .running,
                artifactLink: nil
            )
        }

        if let tool = workspaceAgentTool(for: workspace) {
            return SidebarStatusPresentation(
                statusText: "\(tool.displayName) is idle",
                stateBadgeText: "Idle",
                leadingAccessory: .agent(tool),
                attentionState: nil,
                artifactLink: nil
            )
        }

        return SidebarStatusPresentation(
            statusText: nil,
            stateBadgeText: nil,
            leadingAccessory: fallbackLeadingAccessory,
            attentionState: nil,
            artifactLink: nil
        )
    }

    private static func workspaceIsWorking(for workspace: WorkspaceState) -> Bool {
        workspace.paneStripState.panes.contains { pane in
            workspace.auxiliaryStateByPaneID[pane.id]?.isWorking ?? false
        }
    }

    private static func workspaceAgentTool(for workspace: WorkspaceState) -> AgentTool? {
        for pane in workspace.paneStripState.panes {
            let auxiliaryState = workspace.auxiliaryStateByPaneID[pane.id]
            if let tool = auxiliaryState?.agentStatus?.tool {
                return tool
            }
            if let recognized = AgentToolRecognizer.recognize(metadata: auxiliaryState?.metadata) {
                return recognized
            }
        }

        return nil
    }

    private static func workingAgentTool(for workspace: WorkspaceState) -> AgentTool? {
        for pane in workspace.paneStripState.panes {
            guard workspace.auxiliaryStateByPaneID[pane.id]?.isWorking == true else {
                continue
            }

            let auxiliaryState = workspace.auxiliaryStateByPaneID[pane.id]
            if let tool = auxiliaryState?.agentStatus?.tool {
                return tool
            }
            if let recognized = AgentToolRecognizer.recognize(metadata: auxiliaryState?.metadata) {
                return recognized
            }
        }

        return nil
    }

    private static func workspaceIdentity(
        for workspace: WorkspaceState,
        orderedPaneContexts candidatePaneContexts: [WorkspacePaneContext]? = nil
    ) -> WorkspaceSidebarIdentity {
        let orderedPaneContexts = candidatePaneContexts ?? self.orderedPaneContexts(for: workspace)

        if let focusedPaneContext = focusedPaneContext(
            for: workspace,
            orderedPaneContexts: orderedPaneContexts
        ) {
            return identity(for: focusedPaneContext)
                ?? fallbackIdentity(for: focusedPaneContext)
        }

        if let firstPaneContext = orderedPaneContexts.first {
            return identity(for: firstPaneContext)
                ?? fallbackIdentity(for: firstPaneContext)
        }

        return WorkspaceSidebarIdentity(
            paneID: workspace.paneStripState.focusedPaneID,
            primaryText: "Shell",
            cwdPath: nil,
            isCwdDerived: false
        )
    }

    private static func paneDetailTexts(
        for workspace: WorkspaceState,
        primaryText: String,
        orderedPaneContexts candidatePaneContexts: [WorkspacePaneContext]? = nil
    ) -> [String] {
        let paneContexts = candidatePaneContexts ?? self.orderedPaneContexts(for: workspace)
        if paneContexts.count == 1 {
            guard let paneContext = paneContexts.first else {
                return []
            }

            let metadata = paneContext.metadata
            guard let detailText = WorkspaceContextFormatter.singlePaneSidebarDetailLine(
                metadata: metadata,
                workingDirectory: resolvedWorkingDirectory(for: paneContext)
            ) else {
                return []
            }

            return detailTextRepeatsPrimary(detailText, primaryText: primaryText)
                ? []
                : [detailText]
        }

        let focusedPaneID = workspace.paneStripState.focusedPaneID
        let candidates = paneContexts.compactMap { paneContext -> PaneDetailCandidate? in
            guard paneContext.paneID != focusedPaneID else {
                return nil
            }
            return paneDetailCandidate(
                for: paneContext
            )
        }

        return resolvedMultiPaneDetailTexts(
            candidates,
            primaryText: primaryText
        )
    }

    private static func detailLines(
        for workspace: WorkspaceState,
        primaryText: String,
        orderedPaneContexts: [WorkspacePaneContext]? = nil
    ) -> [WorkspaceSidebarDetailLine] {
        paneDetailTexts(
            for: workspace,
            primaryText: primaryText,
            orderedPaneContexts: orderedPaneContexts
        ).enumerated().map { index, text in
            WorkspaceSidebarDetailLine(
                text: text,
                emphasis: .secondary
            )
        }
    }

    private static func paneDetailCandidate(
        for paneContext: WorkspacePaneContext
    ) -> PaneDetailCandidate? {
        let metadata = paneContext.metadata
        let cwdPath = resolvedWorkingDirectory(for: paneContext)
        let maxPathSegments = cwdPath.flatMap {
            WorkspaceContextFormatter.maxSidebarPathSegments($0)
        } ?? 1

        guard WorkspaceContextFormatter.paneDetailLine(
            metadata: metadata,
            fallbackTitle: paneContext.pane.title,
            workingDirectory: cwdPath
        ) != nil else {
            return nil
        }

        return PaneDetailCandidate(
            paneID: paneContext.paneID,
            metadata: metadata,
            fallbackTitle: paneContext.pane.title,
            cwdPath: cwdPath,
            maxPathSegments: maxPathSegments
        )
    }

    private static func identity(for paneContext: WorkspacePaneContext) -> WorkspaceSidebarIdentity? {
        let metadata = paneContext.metadata

        if let recognized = AgentToolRecognizer.recognize(metadata: metadata) {
            return WorkspaceSidebarIdentity(
                paneID: paneContext.paneID,
                primaryText: recognized.displayName,
                cwdPath: nil,
                isCwdDerived: false
            )
        }

        let resolvedWorkingDirectory = resolvedWorkingDirectory(for: paneContext)
        let branch = WorkspaceContextFormatter.displayBranch(metadata?.gitBranch)
        let formattedWorkingDirectory = WorkspaceContextFormatter.formattedWorkingDirectory(
            resolvedWorkingDirectory,
            branch: branch
        )
        let focusedPrimaryText = focusedPrimaryText(
            metadata: metadata,
            fallbackTitle: paneContext.pane.title,
            workingDirectory: resolvedWorkingDirectory,
            formattedWorkingDirectory: formattedWorkingDirectory,
            branch: branch
        )

        if let focusedPrimaryText {
            return WorkspaceSidebarIdentity(
                paneID: paneContext.paneID,
                primaryText: focusedPrimaryText.label,
                cwdPath: focusedPrimaryText.isCwdDerived ? resolvedWorkingDirectory : nil,
                isCwdDerived: focusedPrimaryText.isCwdDerived
            )
        }

        if let terminalIdentity = WorkspaceContextFormatter.displayStablePaneIdentity(
            for: metadata,
            fallbackTitle: paneContext.pane.title,
            workingDirectory: resolvedWorkingDirectory,
            branch: branch
        ) {
            return WorkspaceSidebarIdentity(
                paneID: paneContext.paneID,
                primaryText: terminalIdentity,
                cwdPath: terminalIdentity == formattedWorkingDirectory ? resolvedWorkingDirectory : nil,
                isCwdDerived: terminalIdentity == formattedWorkingDirectory
            )
        }

        return nil
    }

    private static func focusedPrimaryText(
        metadata: TerminalMetadata?,
        fallbackTitle: String?,
        workingDirectory: String?,
        formattedWorkingDirectory: String?,
        branch: String?
    ) -> (label: String, isCwdDerived: Bool)? {
        let stableIdentity = WorkspaceContextFormatter.displayStablePaneIdentity(
            for: metadata,
            fallbackTitle: fallbackTitle,
            workingDirectory: workingDirectory,
            branch: branch
        )

        guard let stableIdentity else {
            return nil
        }

        let isCwdDerived = stableIdentity == formattedWorkingDirectory
        guard branch != nil, isCwdDerived else {
            return (stableIdentity, isCwdDerived)
        }

        let branchPrefixedIdentity = WorkspaceContextFormatter.paneDetailLine(
            metadata: metadata,
            fallbackTitle: fallbackTitle,
            workingDirectory: workingDirectory
        ) ?? stableIdentity
        return (branchPrefixedIdentity, true)
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
            workingDirectory: candidate.cwdPath,
            minimumPathSegments: minimumPathSegments
        )
    }

    private static func resolvedWorkingDirectory(for paneContext: WorkspacePaneContext) -> String? {
        WorkspaceContextFormatter.resolvedWorkingDirectory(
            for: paneContext.metadata,
            shellContext: paneContext.auxiliaryState?.shellContext
        )
    }

    private static func orderedPaneContexts(for workspace: WorkspaceState) -> [WorkspacePaneContext] {
        workspace.paneStripState.panes.compactMap { pane in
            workspace.paneContext(for: pane.id)
        }
    }

    private static func focusedPaneContext(
        for workspace: WorkspaceState,
        orderedPaneContexts: [WorkspacePaneContext]
    ) -> WorkspacePaneContext? {
        guard let focusedPaneID = workspace.paneStripState.focusedPaneID else {
            return orderedPaneContexts.first
        }

        return orderedPaneContexts.first { $0.paneID == focusedPaneID } ?? orderedPaneContexts.first
    }

    private static func fallbackIdentity(for paneContext: WorkspacePaneContext) -> WorkspaceSidebarIdentity {
        WorkspaceSidebarIdentity(
            paneID: paneContext.paneID,
            primaryText: WorkspaceContextFormatter.normalizeSidebarFallbackTitle(paneContext.pane.title) ?? "Shell",
            cwdPath: nil,
            isCwdDerived: false
        )
    }

    private static func focusedPaneLineIndex(
        for workspace: WorkspaceState,
        orderedPaneContexts: [WorkspacePaneContext]
    ) -> Int {
        guard orderedPaneContexts.count > 1,
              let focusedPaneID = workspace.paneStripState.focusedPaneID else {
            return 0
        }

        var visibleNonFocusedLinesBeforeFocus = 0
        for paneContext in orderedPaneContexts {
            if paneContext.paneID == focusedPaneID {
                return visibleNonFocusedLinesBeforeFocus
            }

            if paneDetailCandidate(for: paneContext) != nil {
                visibleNonFocusedLinesBeforeFocus += 1
            }
        }

        return 0
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
                focusedPaneLineIndex: summary.focusedPaneLineIndex,
                statusText: summary.statusText,
                stateBadgeText: summary.stateBadgeText,
                detailLines: summary.detailLines,
                overflowText: summary.overflowText,
                leadingAccessory: summary.leadingAccessory,
                attentionState: summary.attentionState,
                artifactLink: summary.artifactLink,
                isWorking: summary.isWorking,
                isActive: summary.isActive
            )
        }
    }

    private static func explicitStatusText(
        for state: WorkspaceAttentionState,
        actorName: String
    ) -> String {
        switch state {
        case .needsInput:
            return "\(actorName) is waiting for your input"
        case .unresolvedStop:
            return "\(actorName) stopped before finishing"
        case .running:
            return "\(actorName) is working"
        case .completed:
            return "\(actorName) completed its latest run"
        }
    }

    private static func disambiguatedPrimaryText(
        for summary: WorkspaceSidebarSummary,
        pathsByWorkspaceID: [WorkspaceID: String],
        requiredSegmentCountByWorkspaceID: [WorkspaceID: Int]
    ) -> String? {
        guard summary.attentionState == nil,
              let path = pathsByWorkspaceID[summary.workspaceID] else {
            return nil
        }

        let requiredSegmentCount = requiredSegmentCountByWorkspaceID[summary.workspaceID] ?? 1
        let compactPrimaryText = WorkspaceContextFormatter.compactSidebarPath(path)
        let compactRepositoryPrimaryText = WorkspaceContextFormatter.compactRepositorySidebarPath(path)

        if let compactRepositoryPrimaryText,
           compactRepositoryPrimaryText.caseInsensitiveCompare(summary.primaryText) == .orderedSame {
            return WorkspaceContextFormatter.compactRepositorySidebarPath(
                path,
                minimumSegments: requiredSegmentCount
            )
        }

        guard let compactPrimaryText,
              compactPrimaryText.caseInsensitiveCompare(summary.primaryText) == .orderedSame else {
            return nil
        }

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
