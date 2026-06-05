import Foundation

@MainActor
enum MenuBarPaneSnapshotBuilder {
    static func snapshots(
        from sources: [MenuBarWorklaneSource]
    ) -> [MenuBarPaneSnapshot] {
        sources.flatMap { source in
            snapshots(for: source)
        }
        .sorted(by: Self.isOrderedBefore)
    }

    private static func snapshots(for source: MenuBarWorklaneSource) -> [MenuBarPaneSnapshot] {
        let store = source.worklaneStore
        let summaries = WorklaneSidebarSummaryBuilder.summaries(
            for: store.worklanes,
            activeWorklaneID: store.activeWorklaneID
        )
        let summariesByWorklaneID = Dictionary(uniqueKeysWithValues: summaries.map { ($0.worklaneID, $0) })

        return store.worklanes.enumerated().flatMap { index, worklane in
            let summary = summariesByWorklaneID[worklane.id]
            let paneRowsByID = Dictionary(
                uniqueKeysWithValues: (summary?.paneRows ?? []).map { ($0.paneID, $0) }
            )
            let worklaneTitle = displayTitle(for: worklane, displayOrder: index + 1)

            return worklane.paneStripState.panes.compactMap { pane in
                snapshot(
                    pane: pane,
                    paneRow: paneRowsByID[pane.id],
                    worklane: worklane,
                    source: source,
                    worklaneTitle: worklaneTitle
                )
            }
        }
    }

    private static func snapshot(
        pane: PaneState,
        paneRow: WorklaneSidebarPaneRow?,
        worklane: WorklaneState,
        source: MenuBarWorklaneSource,
        worklaneTitle: String
    ) -> MenuBarPaneSnapshot? {
        guard let auxiliary = worklane.auxiliaryStateByPaneID[pane.id] else {
            return nil
        }

        let agentTool = auxiliary.agentStatus?.tool
            ?? auxiliary.presentation.recognizedTool
            ?? AgentToolRecognizer.recognize(metadata: auxiliary.metadata)
            ?? AgentTool.resolveKnown(named: pane.title)
        guard let agentTool else {
            return nil
        }

        let explicitAgentStatus = auxiliary.agentStatus
        let agentStatus = explicitAgentStatus ?? PaneAgentStatus(
            tool: agentTool,
            state: .idle,
            text: nil,
            artifactLink: nil,
            updatedAt: auxiliary.presentation.updatedAt
        )
        let fleetState = MenuBarFleetState.resolve(
            paneRow: paneRow,
            presentation: auxiliary.presentation,
            agentStatus: explicitAgentStatus,
            metadata: auxiliary.metadata,
            paneTitle: pane.title
        )
        let statusLabel = statusLabel(
            paneRow: paneRow,
            agentStatus: agentStatus,
            fleetState: fleetState
        )
        let primaryText = primaryText(
            pane: pane,
            paneRow: paneRow,
            auxiliary: auxiliary,
            agentTool: agentTool
        )
        let contextText = contextText(auxiliary: auxiliary)

        return MenuBarPaneSnapshot(
            windowID: source.windowID,
            windowTitle: source.windowTitle,
            worklaneID: worklane.id,
            paneID: pane.id,
            agentTool: agentTool,
            primaryText: primaryText,
            contextText: contextText,
            statusLabel: statusLabel,
            attentionState: paneRow?.attentionState ?? fleetState.menuAttentionState,
            fleetState: fleetState,
            updatedAt: agentStatus.updatedAt,
            taskProgress: taskProgress(
                paneRow: paneRow,
                agentStatus: agentStatus,
                presentation: auxiliary.presentation
            ),
            sortPriority: fleetState.priority
        )
    }

    private static func taskProgress(
        paneRow: WorklaneSidebarPaneRow?,
        agentStatus: PaneAgentStatus,
        presentation: PanePresentationState
    ) -> PaneAgentTaskProgress? {
        visibleTaskProgress(paneRow?.taskProgress)
            ?? visibleTaskProgress(agentStatus.taskProgress)
            ?? visibleTaskProgress(presentation.taskProgress)
    }

    private static func visibleTaskProgress(
        _ taskProgress: PaneAgentTaskProgress?
    ) -> PaneAgentTaskProgress? {
        guard let taskProgress,
              taskProgress.doneCount < taskProgress.totalCount else {
            return nil
        }
        return taskProgress
    }

    private static func displayTitle(for worklane: WorklaneState, displayOrder: Int) -> String {
        worklane.title ?? "Worklane \(displayOrder)"
    }

    private static func statusLabel(
        paneRow: WorklaneSidebarPaneRow?,
        agentStatus: PaneAgentStatus,
        fleetState: MenuBarFleetState
    ) -> String {
        let rowStatusText = paneRowStatusText(paneRow, fleetState: fleetState)
        return rowStatusText
            ?? paneRow?.interactionLabel?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? fleetState.menuStatusLabel(interactionKind: agentStatus.interactionKind)
    }

    private static func paneRowStatusText(
        _ paneRow: WorklaneSidebarPaneRow?,
        fleetState: MenuBarFleetState
    ) -> String? {
        guard !(fleetState == .idle && paneRow?.attentionState == .running) else {
            return nil
        }
        return paneRow?.statusText?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    private static func isOrderedBefore(_ lhs: MenuBarPaneSnapshot, _ rhs: MenuBarPaneSnapshot) -> Bool {
        if lhs.sortPriority != rhs.sortPriority {
            return lhs.sortPriority < rhs.sortPriority
        }
        if lhs.updatedAt != rhs.updatedAt {
            return lhs.updatedAt > rhs.updatedAt
        }
        return lhs.primaryText.localizedCaseInsensitiveCompare(rhs.primaryText) == .orderedAscending
    }

    private static func primaryText(
        pane: PaneState,
        paneRow: WorklaneSidebarPaneRow?,
        auxiliary: PaneAuxiliaryState,
        agentTool: AgentTool
    ) -> String {
        if let paneTitle = WorklaneContextFormatter.normalizeDisplayIdentity(pane.title),
           AgentTool.resolveKnown(named: paneTitle) == nil {
            return paneTitle
        }
        if let rowTitle = WorklaneContextFormatter.normalizeDisplayIdentity(paneRow?.primaryText),
           isMeaningfulPrimaryCandidate(rowTitle, agentTool: agentTool) {
            return rowTitle
        }
        if let identityText = WorklaneContextFormatter.normalizeDisplayIdentity(auxiliary.presentation.identityText),
           isMeaningfulPrimaryCandidate(identityText, agentTool: agentTool) {
            return identityText
        }
        if let cwd = workingDirectory(auxiliary: auxiliary),
           let folder = URL(fileURLWithPath: cwd).standardizedFileURL.pathComponents.last,
           WorklaneContextFormatter.trimmed(folder) != nil {
            return folder
        }
        return agentTool.displayName
    }

    private static func isMeaningfulPrimaryCandidate(
        _ value: String,
        agentTool: AgentTool
    ) -> Bool {
        guard AgentTool.resolveKnown(named: value) == nil,
              value.caseInsensitiveCompare(agentTool.displayName) != .orderedSame,
              !WorklaneContextFormatter.looksCompactedForDisplay(value),
              !value.contains("/") else {
            return false
        }
        return true
    }

    private static func contextText(auxiliary: PaneAuxiliaryState) -> String? {
        let cwd = workingDirectory(auxiliary: auxiliary)
        let folder = cwd.flatMap { path -> String? in
            URL(fileURLWithPath: path).standardizedFileURL.pathComponents.last
        }.flatMap(WorklaneContextFormatter.trimmed)
        let branch = WorklaneContextFormatter.displayBranch(
            auxiliary.presentation.branchDisplayText
                ?? auxiliary.presentation.branch
                ?? auxiliary.gitContext?.branchDisplayText
                ?? auxiliary.metadata?.gitBranch
        )

        if let folder, let branch {
            return "\(folder) · \(branch)"
        }
        return folder ?? branch
    }

    private static func workingDirectory(auxiliary: PaneAuxiliaryState) -> String? {
        auxiliary.presentation.cwd
            ?? auxiliary.gitContext?.workingDirectory
            ?? auxiliary.agentStatus?.workingDirectory
            ?? auxiliary.metadata?.currentWorkingDirectory
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
