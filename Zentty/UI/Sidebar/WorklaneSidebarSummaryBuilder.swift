import AppKit

struct WorklaneSidebarFocusOverride: Equatable {
    let worklaneID: WorklaneID
    let paneID: PaneID
}

enum WorklaneSidebarSummaryBuilder {
    private struct SidebarStatusPresentation {
        let statusText: String?
        let statusSymbolName: String?
        let attentionState: WorklaneAttentionState?
        let interactionKind: PaneInteractionKind?
        let interactionLabel: String?
        let interactionSymbolName: String?
        let taskProgress: PaneAgentTaskProgress?
    }

    private struct PaneSidebarStatusPresentation {
        let statusText: String?
        let statusSymbolName: String?
        let attentionState: WorklaneAttentionState?
        let interactionKind: PaneInteractionKind?
        let interactionLabel: String?
        let interactionSymbolName: String?
        let taskProgress: PaneAgentTaskProgress?
        let isWorking: Bool
    }

    private static let compactingStatusSymbolName = "square.stack.3d.down.right.fill"

    private struct WorklaneSidebarIdentity {
        let paneID: PaneID?
        let primaryText: String
        let cwdPath: String?
        let isCwdDerived: Bool
    }

    private struct PaneSidebarIdentity {
        let primaryText: String
        let trailingText: String?
        let detailText: String?
    }

    private enum PaneIdentityStyle {
        case worklaneSummary
        case paneRow
    }

    private struct PaneDetailCandidate {
        let paneID: PaneID
        let metadata: TerminalMetadata?
        let fallbackTitle: String?
        let cwdPath: String?
        let maxPathSegments: Int
    }

    static func summaries(
        for worklanes: [WorklaneState],
        activeWorklaneID: WorklaneID,
        focusOverride: WorklaneSidebarFocusOverride? = nil,
        serverContextsByWorklaneID: [WorklaneID: WorklaneServerContext] = [:]
    ) -> [WorklaneSidebarSummary] {
        let focusOverride = validFocusOverride(focusOverride, in: worklanes)
        let effectiveActiveWorklaneID = focusOverride?.worklaneID ?? activeWorklaneID
        let identitiesByWorklaneID = Dictionary(
            uniqueKeysWithValues: worklanes.map { worklane in
                (worklane.id, worklaneIdentity(for: worklane, focusOverride: focusOverride))
            }
        )
        let baseSummaries = worklanes.enumerated().map { index, worklane in
            summary(
                for: worklane,
                isActive: worklane.id == effectiveActiveWorklaneID,
                identity: identitiesByWorklaneID[worklane.id],
                displayOrder: index + 1,
                focusOverride: focusOverride,
                serverContext: serverContextsByWorklaneID[worklane.id]
            )
        }

        return disambiguatedSummaries(
            baseSummaries,
            identitiesByWorklaneID: identitiesByWorklaneID,
            worklanes: worklanes
        )
    }

    static func summary(
        for worklane: WorklaneState,
        isActive: Bool,
        serverContext: WorklaneServerContext? = nil
    ) -> WorklaneSidebarSummary {
        summary(
            for: worklane,
            isActive: isActive,
            identity: worklaneIdentity(for: worklane),
            displayOrder: 1,
            serverContext: serverContext
        )
    }

    private static func summary(
        for worklane: WorklaneState,
        isActive: Bool,
        identity: WorklaneSidebarIdentity?,
        displayOrder: Int,
        focusOverride: WorklaneSidebarFocusOverride? = nil,
        serverContext: WorklaneServerContext? = nil
    ) -> WorklaneSidebarSummary {
        let orderedPaneContexts = orderedPaneContexts(for: worklane)
        let focusedPaneID = effectiveFocusedPaneID(
            for: worklane,
            focusOverride: focusOverride
        )
        let paneRows = paneRows(
            for: worklane,
            orderedPaneContexts: orderedPaneContexts,
            focusedPaneID: focusedPaneID,
            serverContext: serverContext
        )
        let isWorking = paneRows.contains(where: \.isWorking) || worklaneIsWorking(for: worklane)
        let badgeText = badge(for: worklane.meaningfulTitle, displayOrder: displayOrder)
        let identity = identity ?? worklaneIdentity(
            for: worklane,
            orderedPaneContexts: orderedPaneContexts,
            focusOverride: focusOverride
        )
        let primaryText = identity.primaryText
        let focusedPaneLineIndex = focusedPaneLineIndex(
            orderedPaneContexts: orderedPaneContexts,
            focusedPaneID: focusedPaneID
        )
        let topLabel = visibleTopLabel(
            worklane.meaningfulTitle,
            primaryText: primaryText
        )
        let sidebarDetailLines = detailLines(
            for: worklane,
            primaryText: primaryText,
            orderedPaneContexts: orderedPaneContexts,
            focusedPaneID: focusedPaneID
        )
        let statusPresentation = paneRows.isEmpty
            ? sidebarStatusPresentation(
                for: worklane,
                attention: WorklaneAttentionSummaryBuilder.summary(for: worklane),
                isWorking: isWorking
            )
            : SidebarStatusPresentation(
                statusText: nil,
                statusSymbolName: nil,
                attentionState: nil,
                interactionKind: nil,
                interactionLabel: nil,
                interactionSymbolName: nil,
                taskProgress: nil
            )

        return WorklaneSidebarSummary(
            worklaneID: worklane.id,
            badgeText: badgeText,
            topLabel: topLabel,
            primaryText: primaryText,
            focusedPaneLineIndex: focusedPaneLineIndex,
            statusText: statusPresentation.statusText,
            statusSymbolName: statusPresentation.statusSymbolName,
            detailLines: sidebarDetailLines,
            paneRows: paneRows,
            overflowText: nil,
            attentionState: statusPresentation.attentionState,
            interactionKind: statusPresentation.interactionKind,
            interactionLabel: statusPresentation.interactionLabel,
            interactionSymbolName: statusPresentation.interactionSymbolName,
            taskProgress: statusPresentation.taskProgress,
            isWorking: isWorking,
            isActive: isActive,
            color: worklane.color,
            bookmarkOriginID: worklane.bookmarkOriginID
        )
    }

    private static func sidebarStatusPresentation(
        for worklane: WorklaneState,
        attention: WorklaneAttentionSummary?,
        isWorking: Bool
    ) -> SidebarStatusPresentation {
        if let attention {
            let progressPresentation = taskProgressPresentation(
                statusText: statusText(
                    for: attention.state,
                    interactionLabel: attention.interactionLabel,
                    interactionKind: attention.interactionKind,
                    fallback: attention.statusText
                ),
                taskProgress: attention.taskProgress
            )
            return SidebarStatusPresentation(
                statusText: progressPresentation.statusText,
                statusSymbolName: nil,
                attentionState: attention.state,
                interactionKind: attention.interactionKind,
                interactionLabel: attention.interactionLabel ?? attention.interactionKind?.defaultLabel,
                interactionSymbolName: attention.interactionSymbolName
                    ?? attention.interactionKind?.defaultSymbolName
                    ?? defaultSymbolName(for: attention.state, statusText: progressPresentation.statusText),
                taskProgress: progressPresentation.taskProgress
            )
        }

        if isWorking {
            return SidebarStatusPresentation(
                statusText: plainStatusText(for: .running),
                statusSymbolName: nil,
                attentionState: .running,
                interactionKind: nil,
                interactionLabel: nil,
                interactionSymbolName: defaultSymbolName(for: .running),
                taskProgress: nil
            )
        }

        if worklaneAgentTool(for: worklane) != nil {
            return SidebarStatusPresentation(
                statusText: nil,
                statusSymbolName: nil,
                attentionState: nil,
                interactionKind: nil,
                interactionLabel: nil,
                interactionSymbolName: nil,
                taskProgress: nil
            )
        }

        return SidebarStatusPresentation(
            statusText: nil,
            statusSymbolName: nil,
            attentionState: nil,
            interactionKind: nil,
            interactionLabel: nil,
            interactionSymbolName: nil,
            taskProgress: nil
        )
    }

    private static func paneRows(
        for worklane: WorklaneState,
        orderedPaneContexts: [WorklanePaneContext],
        focusedPaneID: PaneID?,
        serverContext: WorklaneServerContext?
    ) -> [WorklaneSidebarPaneRow] {
        let isSinglePane = orderedPaneContexts.count == 1

        return orderedPaneContexts.map { paneContext in
            let isFocused = focusedPaneID == paneContext.paneID
            let statusPresentation = paneSidebarStatusPresentation(for: paneContext.presentation)
            let paneIdentity = paneIdentity(
                metadata: paneContext.metadata,
                for: paneContext.presentation,
                isSinglePane: isSinglePane,
                style: .paneRow,
                fallbackTitle: paneContext.pane.title
            )

            return WorklaneSidebarPaneRow(
                paneID: paneContext.paneID,
                primaryText: paneIdentity.primaryText,
                trailingText: paneIdentity.trailingText,
                detailText: paneIdentity.detailText,
                statusText: statusPresentation.statusText,
                statusSymbolName: statusPresentation.statusSymbolName,
                attentionState: statusPresentation.attentionState,
                interactionKind: statusPresentation.interactionKind,
                interactionLabel: statusPresentation.interactionLabel,
                interactionSymbolName: statusPresentation.interactionSymbolName,
                isFocused: isFocused,
                isWorking: statusPresentation.isWorking,
                taskProgress: statusPresentation.taskProgress,
                serverPorts: serverPorts(for: paneContext.paneID, serverContext: serverContext)
            )
        }
    }

    private static func serverPorts(
        for paneID: PaneID,
        serverContext: WorklaneServerContext?
    ) -> [WorklaneSidebarServerPort] {
        guard let serverContext else {
            return []
        }

        return serverContext.servers
            .compactMap { server -> WorklaneSidebarServerPort? in
                guard server.paneID == paneID else {
                    return nil
                }

                let port = server.url.port ?? server.ports.first
                return port.map {
                    WorklaneSidebarServerPort(serverID: server.id, port: $0)
                }
            }
            .sorted { lhs, rhs in
                if lhs.port != rhs.port {
                    return lhs.port < rhs.port
                }
                return lhs.serverID < rhs.serverID
            }
    }

    private static func worklaneIsWorking(for worklane: WorklaneState) -> Bool {
        worklane.paneStripState.panes.contains { pane in
            paneIsWorkingInSidebar(paneID: pane.id, worklane: worklane)
        }
    }

    private static func paneIsWorkingInSidebar(
        paneID: PaneID,
        worklane: WorklaneState
    ) -> Bool {
        guard let paneContext = worklane.paneContext(for: paneID) else {
            return false
        }

        return paneContext.presentation.isWorking
    }

    private static func worklaneAgentTool(for worklane: WorklaneState) -> AgentTool? {
        for pane in worklane.paneStripState.panes {
            if let recognized = worklane.paneContext(for: pane.id)?.presentation.recognizedTool {
                return recognized
            }
        }

        return nil
    }

    private static func workingAgentTool(for worklane: WorklaneState) -> AgentTool? {
        for pane in worklane.paneStripState.panes {
            guard let presentation = worklane.paneContext(for: pane.id)?.presentation,
                  presentation.isWorking else {
                continue
            }
            if let recognized = presentation.recognizedTool { return recognized }
        }

        return nil
    }

    private static func worklaneIdentity(
        for worklane: WorklaneState,
        orderedPaneContexts candidatePaneContexts: [WorklanePaneContext]? = nil,
        focusOverride: WorklaneSidebarFocusOverride? = nil
    ) -> WorklaneSidebarIdentity {
        let orderedPaneContexts = candidatePaneContexts ?? self.orderedPaneContexts(for: worklane)
        let isSinglePane = orderedPaneContexts.count == 1

        if let focusedPaneContext = focusedPaneContext(
            orderedPaneContexts: orderedPaneContexts,
            focusedPaneID: effectiveFocusedPaneID(for: worklane, focusOverride: focusOverride)
        ) {
            return identity(for: focusedPaneContext, isSinglePane: isSinglePane)
                ?? fallbackIdentity(for: focusedPaneContext)
        }

        if let firstPaneContext = orderedPaneContexts.first {
            return identity(for: firstPaneContext, isSinglePane: isSinglePane)
                ?? fallbackIdentity(for: firstPaneContext)
        }

        return WorklaneSidebarIdentity(
            paneID: worklane.paneStripState.focusedPaneID,
            primaryText: "Shell",
            cwdPath: nil,
            isCwdDerived: false
        )
    }

    private static func paneDetailTexts(
        for worklane: WorklaneState,
        primaryText: String,
        orderedPaneContexts candidatePaneContexts: [WorklanePaneContext]? = nil,
        focusedPaneID candidateFocusedPaneID: PaneID? = nil
    ) -> [String] {
        let paneContexts = candidatePaneContexts ?? self.orderedPaneContexts(for: worklane)
        if paneContexts.count == 1 {
            return []
        }

        let focusedPaneID = candidateFocusedPaneID ?? worklane.paneStripState.focusedPaneID
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
        for worklane: WorklaneState,
        primaryText: String,
        orderedPaneContexts: [WorklanePaneContext]? = nil,
        focusedPaneID: PaneID? = nil
    ) -> [WorklaneSidebarDetailLine] {
        paneDetailTexts(
            for: worklane,
            primaryText: primaryText,
            orderedPaneContexts: orderedPaneContexts,
            focusedPaneID: focusedPaneID
        ).enumerated().map { index, text in
            WorklaneSidebarDetailLine(
                text: text,
                emphasis: .secondary
            )
        }
    }

    private static func paneDetailCandidate(
        for paneContext: WorklanePaneContext
    ) -> PaneDetailCandidate? {
        guard paneContext.presentation.hasInferredSSHConnection == false else {
            return nil
        }

        let metadata = paneContext.metadata
        let cwdPath = resolvedWorkingDirectory(for: paneContext)
        let maxPathSegments = cwdPath.flatMap {
            WorklaneContextFormatter.maxSidebarPathSegments($0)
        } ?? 1

        guard WorklaneContextFormatter.paneDetailLine(
            metadata: metadata,
            fallbackTitle: paneContext.pane.title,
            workingDirectory: cwdPath,
            fallbackToMetadataWorkingDirectory: false
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

    private static func identity(
        for paneContext: WorklanePaneContext,
        isSinglePane: Bool
    ) -> WorklaneSidebarIdentity? {
        let presentation = paneContext.presentation
        let paneIdentity = paneIdentity(
            metadata: paneContext.metadata,
            for: presentation,
            isSinglePane: isSinglePane,
            style: .worklaneSummary,
            fallbackTitle: paneContext.pane.title
        )
        let primaryText = paneIdentity.primaryText

        return WorklaneSidebarIdentity(
            paneID: paneContext.paneID,
            primaryText: primaryText,
            cwdPath: presentation.cwd,
            isCwdDerived: primaryText == compactSidebarContextText(for: presentation)
        )
    }

    private static func paneIdentity(
        metadata: TerminalMetadata?,
        for presentation: PanePresentationState,
        isSinglePane: Bool,
        style: PaneIdentityStyle,
        fallbackTitle: String?
    ) -> PaneSidebarIdentity {
        if presentation.isRemoteShell {
            return remotePaneIdentity(
                metadata: metadata,
                presentation: presentation,
                fallbackTitle: fallbackTitle
            )
        }

        if let sshConnectionLabel = WorklaneContextFormatter.trimmed(presentation.sshConnectionLabel) {
            return PaneSidebarIdentity(
                primaryText: sshConnectionLabel,
                trailingText: nil,
                detailText: nil
            )
        }

        let branch = presentation.branchDisplayText
        let workingDirectory = compactWorkingDirectory(for: presentation)
        let lastActivityDetail = lastActivityDetailText(for: presentation)

        if let recognizedTool = presentation.recognizedTool,
           let volatileTitle = WorklaneContextFormatter.trimmed(metadata?.title),
           TerminalMetadataChangeClassifier.isRealtimeAgentStatusTitle(
               volatileTitle,
               recognizedTool: recognizedTool
           ) {
            return PaneSidebarIdentity(
                primaryText: volatileTitle,
                trailingText: branch,
                detailText: workingDirectory
            )
        }

        if let rememberedTitle = WorklaneContextFormatter.trimmed(presentation.rememberedTitle) {
            if isSinglePane {
                return PaneSidebarIdentity(
                    primaryText: rememberedTitle,
                    trailingText: branch,
                    detailText: workingDirectory
                )
            }

            return PaneSidebarIdentity(
                primaryText: rememberedTitle,
                trailingText: branch,
                detailText: workingDirectory
            )
        }

        if let branch, let workingDirectory {
            if style == .paneRow {
                return PaneSidebarIdentity(
                    primaryText: workingDirectory,
                    trailingText: branch,
                    detailText: lastActivityDetail
                )
            }

            return PaneSidebarIdentity(
                primaryText: isSinglePane ? "\(branch) · \(workingDirectory)" : "\(branch) • \(workingDirectory)",
                trailingText: nil,
                detailText: nil
            )
        }

        if let branch {
            return PaneSidebarIdentity(
                primaryText: branch,
                trailingText: nil,
                detailText: style == .paneRow ? lastActivityDetail : nil
            )
        }

        if let workingDirectory {
            return PaneSidebarIdentity(
                primaryText: workingDirectory,
                trailingText: nil,
                detailText: style == .paneRow ? lastActivityDetail : nil
            )
        }

        return PaneSidebarIdentity(
            primaryText: WorklaneContextFormatter.normalizeSidebarFallbackTitle(fallbackTitle) ?? "Shell",
            trailingText: nil,
            detailText: style == .paneRow ? lastActivityDetail : nil
        )
    }

    private static func lastActivityDetailText(for presentation: PanePresentationState) -> String? {
        guard let lastActivityTitle = WorklaneContextFormatter.normalizeDisplayIdentity(presentation.lastActivityTitle) else {
            return nil
        }

        return "Last ran: \(lastActivityTitle)"
    }

    private static func remotePaneIdentity(
        metadata: TerminalMetadata?,
        presentation: PanePresentationState,
        fallbackTitle: String?
    ) -> PaneSidebarIdentity {
        let host = WorklaneContextFormatter.trimmed(presentation.remoteHostLabel)
        let path = WorklaneContextFormatter.trimmed(presentation.remotePathLabel)

        if let title = meaningfulRemoteTitle(
            metadata: metadata,
            presentation: presentation,
            fallbackTitle: fallbackTitle
        ) {
            let primaryText = [host, title].compactMap(WorklaneContextFormatter.trimmed).joined(separator: " · ")
            return PaneSidebarIdentity(
                primaryText: primaryText.isEmpty ? title : primaryText,
                trailingText: nil,
                detailText: path
            )
        }

        return PaneSidebarIdentity(
            primaryText: WorklaneContextFormatter.trimmed(presentation.remoteLocationLabel)
                ?? WorklaneContextFormatter.normalizeSidebarFallbackTitle(fallbackTitle)
                ?? "Shell",
            trailingText: nil,
            detailText: nil
        )
    }

    private static func meaningfulRemoteTitle(
        metadata: TerminalMetadata?,
        presentation: PanePresentationState,
        fallbackTitle: String?
    ) -> String? {
        if let recognizedTool = presentation.recognizedTool,
           let volatileTitle = WorklaneContextFormatter.trimmed(metadata?.title),
           TerminalMetadataChangeClassifier.isRealtimeAgentStatusTitle(
               volatileTitle,
               recognizedTool: recognizedTool
           ) {
            return volatileTitle
        }

        let candidates = [
            WorklaneContextFormatter.trimmed(presentation.rememberedTitle),
            WorklaneContextFormatter.displayMeaningfulTerminalIdentity(
                for: metadata,
                fallbackTitle: fallbackTitle
            ),
            WorklaneContextFormatter.trimmed(presentation.identityText),
        ]

        for candidate in candidates {
            guard let candidate else {
                continue
            }

            let lowered = candidate.lowercased()
            if lowered == "shell" {
                continue
            }
            if candidate.contains("/") || candidate.hasPrefix("~") {
                continue
            }
            if candidate == presentation.remoteHostLabel {
                continue
            }

            return candidate
        }

        return nil
    }

    private static func paneSidebarStatusPresentation(
        for presentation: PanePresentationState
    ) -> PaneSidebarStatusPresentation {
        let statusText = statusText(
            for: attentionState(for: presentation),
            interactionLabel: presentation.interactionLabel,
            interactionKind: presentation.interactionKind,
            fallback: presentation.statusText
        )
        let attentionState = attentionState(for: presentation)
        guard statusText != nil
            || attentionState != nil
            || presentation.interactionKind != nil
            || presentation.interactionLabel != nil
            || presentation.interactionSymbolName != nil else {
            return PaneSidebarStatusPresentation(
                statusText: nil,
                statusSymbolName: nil,
                attentionState: nil,
                interactionKind: nil,
                interactionLabel: nil,
                interactionSymbolName: nil,
                taskProgress: nil,
                isWorking: false
            )
        }
        let progressPresentation = taskProgressPresentation(
            statusText: statusText,
            taskProgress: presentation.taskProgress
        )

        return PaneSidebarStatusPresentation(
            statusText: progressPresentation.statusText,
            statusSymbolName: presentation.statusSymbolName,
            attentionState: attentionState,
            interactionKind: presentation.interactionKind,
            interactionLabel: presentation.interactionLabel ?? presentation.interactionKind?.defaultLabel,
            interactionSymbolName: presentation.interactionSymbolName
                ?? presentation.interactionKind?.defaultSymbolName
                ?? attentionState.map { defaultSymbolName(for: $0, statusText: progressPresentation.statusText) },
            taskProgress: progressPresentation.taskProgress,
            isWorking: presentation.isWorking
        )
    }

    private static func compactWorkingDirectory(for presentation: PanePresentationState) -> String? {
        guard let cwd = presentation.cwd else {
            return nil
        }

        return WorklaneContextFormatter.compactRepositorySidebarPath(cwd)
            ?? WorklaneContextFormatter.formattedWorkingDirectory(cwd, branch: nil)
    }

    private static func compactSidebarContextText(for presentation: PanePresentationState) -> String? {
        let branch = presentation.branchDisplayText
        let workingDirectory = compactWorkingDirectory(for: presentation)

        switch (branch, workingDirectory) {
        case let (branch?, workingDirectory?):
            return "\(branch) • \(workingDirectory)"
        case let (branch?, nil):
            return branch
        case let (nil, workingDirectory?):
            return workingDirectory
        case (nil, nil):
            return nil
        }
    }

    private static func attentionState(for presentation: PanePresentationState) -> WorklaneAttentionState? {
        if presentation.isReady {
            return .ready
        }

        switch presentation.runtimePhase {
        case .idle, .starting:
            return nil
        case .running:
            return .running
        case .needsInput:
            return .needsInput
        case .unresolvedStop:
            return .unresolvedStop
        }
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
        WorklaneContextFormatter.paneDetailLine(
            metadata: candidate.metadata,
            fallbackTitle: candidate.fallbackTitle,
            workingDirectory: candidate.cwdPath,
            fallbackToMetadataWorkingDirectory: false,
            minimumPathSegments: minimumPathSegments
        )
    }

    private static func resolvedWorkingDirectory(for paneContext: WorklanePaneContext) -> String? {
        paneContext.presentation.cwd
    }

    private static func orderedPaneContexts(for worklane: WorklaneState) -> [WorklanePaneContext] {
        worklane.paneStripState.panes.compactMap { pane in
            worklane.paneContext(for: pane.id)
        }
    }

    private static func validFocusOverride(
        _ focusOverride: WorklaneSidebarFocusOverride?,
        in worklanes: [WorklaneState]
    ) -> WorklaneSidebarFocusOverride? {
        guard let focusOverride,
              let worklane = worklanes.first(where: { $0.id == focusOverride.worklaneID }),
              worklane.paneStripState.panes.contains(where: { $0.id == focusOverride.paneID })
        else {
            return nil
        }

        return focusOverride
    }

    private static func effectiveFocusedPaneID(
        for worklane: WorklaneState,
        focusOverride: WorklaneSidebarFocusOverride?
    ) -> PaneID? {
        guard focusOverride?.worklaneID == worklane.id else {
            return worklane.paneStripState.focusedPaneID
        }

        return focusOverride?.paneID
    }

    private static func focusedPaneContext(
        orderedPaneContexts: [WorklanePaneContext],
        focusedPaneID: PaneID?
    ) -> WorklanePaneContext? {
        guard let focusedPaneID else {
            return orderedPaneContexts.first
        }

        return orderedPaneContexts.first { $0.paneID == focusedPaneID } ?? orderedPaneContexts.first
    }

    private static func fallbackIdentity(for paneContext: WorklanePaneContext) -> WorklaneSidebarIdentity {
        WorklaneSidebarIdentity(
            paneID: paneContext.paneID,
            primaryText: WorklaneContextFormatter.normalizeSidebarFallbackTitle(paneContext.pane.title) ?? "Shell",
            cwdPath: nil,
            isCwdDerived: false
        )
    }

    private static func focusedPaneLineIndex(
        orderedPaneContexts: [WorklanePaneContext],
        focusedPaneID: PaneID?
    ) -> Int {
        guard orderedPaneContexts.count > 1,
              let focusedPaneID else {
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

    private static func visibleTopLabel(
        _ title: String?,
        primaryText: String
    ) -> String? {
        guard let normalizedTitle = WorklaneContextFormatter.trimmed(title) else {
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
        _ summaries: [WorklaneSidebarSummary],
        identitiesByWorklaneID: [WorklaneID: WorklaneSidebarIdentity],
        worklanes: [WorklaneState]
    ) -> [WorklaneSidebarSummary] {
        let cwdDerivedPaths: [(WorklaneID, String)] = identitiesByWorklaneID.compactMap { worklaneID, identity in
                guard identity.isCwdDerived, let cwdPath = identity.cwdPath else {
                    return nil
                }

                return (worklaneID, cwdPath)
            }
        let pathsByWorklaneID = Dictionary(uniqueKeysWithValues: cwdDerivedPaths)

        var requiredSegmentCountByWorklaneID = Dictionary(
            uniqueKeysWithValues: Array(pathsByWorklaneID.keys).map { ($0, 1) }
        )

        while true {
            let labelsByWorklaneID = summaries.reduce(into: [String: [WorklaneID]]()) { result, summary in
                let label = disambiguatedPrimaryText(
                    for: summary,
                    pathsByWorklaneID: pathsByWorklaneID,
                    requiredSegmentCountByWorklaneID: requiredSegmentCountByWorklaneID
                ) ?? summary.primaryText

                result[label.lowercased(), default: []].append(summary.worklaneID)
            }

            var didExpandAnyPath = false

            for worklaneIDs in labelsByWorklaneID.values where worklaneIDs.count > 1 {
                for worklaneID in worklaneIDs {
                    guard let path = pathsByWorklaneID[worklaneID],
                          let maxSegmentCount = WorklaneContextFormatter.maxSidebarPathSegments(path) else {
                        continue
                    }

                    let currentSegmentCount = requiredSegmentCountByWorklaneID[worklaneID] ?? 1
                    guard currentSegmentCount < maxSegmentCount else {
                        continue
                    }

                    requiredSegmentCountByWorklaneID[worklaneID] = currentSegmentCount + 1
                    didExpandAnyPath = true
                }
            }

            guard didExpandAnyPath else {
                break
            }
        }

        return zip(worklanes, summaries).map { worklane, summary in
            let contextPrefixText = disambiguationContextPrefix(
                for: summary,
                pathsByWorklaneID: pathsByWorklaneID,
                requiredSegmentCountByWorklaneID: requiredSegmentCountByWorklaneID
            )

            // Keep the primary text un-expanded and surface the disambiguation
            // delta on a dedicated small-font `contextPrefixText` line so the
            // worklane row primary stays single-line — that's what allows the
            // shimmer overlay (`SidebarShimmerTextView`, single-line only) to
            // render when an agent is running. The `paneRows` array is
            // unchanged: the focused pane's inline rendering continues to use
            // the original (un-expanded) text, and the disambiguation prefix
            // is carried alongside it so the layout can surface it on its own
            // row between the pane primary and status.
            return WorklaneSidebarSummary(
                worklaneID: summary.worklaneID,
                badgeText: summary.badgeText,
                topLabel: visibleTopLabel(
                    worklane.meaningfulTitle,
                    primaryText: summary.primaryText
                ),
                primaryText: summary.primaryText,
                contextPrefixText: contextPrefixText,
                focusedPaneLineIndex: summary.focusedPaneLineIndex,
                statusText: summary.statusText,
                statusSymbolName: summary.statusSymbolName,
                detailLines: summary.detailLines,
                paneRows: summary.paneRows,
                overflowText: summary.overflowText,
                attentionState: summary.attentionState,
                interactionKind: summary.interactionKind,
                interactionLabel: summary.interactionLabel,
                interactionSymbolName: summary.interactionSymbolName,
                taskProgress: summary.taskProgress,
                isWorking: summary.isWorking,
                isActive: summary.isActive,
                color: summary.color,
                bookmarkOriginID: summary.bookmarkOriginID
            )
        }
    }

    private static func defaultSymbolName(for state: WorklaneAttentionState) -> String {
        defaultSymbolName(for: state, statusText: nil)
    }

    private static func defaultSymbolName(
        for state: WorklaneAttentionState,
        statusText: String?
    ) -> String {
        switch state {
        case .running:
            if statusText == PaneAgentReducerState.compactingStatusText {
                return compactingStatusSymbolName
            }
            return "bolt.fill"
        case .needsInput:
            return "ellipsis.circle"
        case .unresolvedStop:
            return "exclamationmark.circle"
        case .ready:
            return "checkmark.circle.fill"
        }
    }

    private static func statusText(
        for attentionState: WorklaneAttentionState?,
        interactionLabel: String?,
        interactionKind: PaneInteractionKind?,
        fallback: String? = nil
    ) -> String? {
        guard let attentionState else {
            return fallback
        }

        if attentionState == .needsInput {
            return interactionLabel ?? interactionKind?.defaultLabel ?? plainStatusText(for: attentionState)
        }

        return fallback ?? plainStatusText(for: attentionState)
    }

    private static func plainStatusText(for state: WorklaneAttentionState) -> String {
        switch state {
        case .needsInput:
            return "Needs input"
        case .unresolvedStop:
            return "Stopped early"
        case .ready:
            return "Agent ready"
        case .running:
            return "Running"
        }
    }

    private static func taskProgressPresentation(
        statusText: String?,
        taskProgress: PaneAgentTaskProgress?
    ) -> (statusText: String?, taskProgress: PaneAgentTaskProgress?) {
        guard
            let taskProgress,
            taskProgress.doneCount < taskProgress.totalCount,
            let statusText
        else {
            return (statusText, nil)
        }

        let suffix = " (\(taskProgress.doneCount)/\(taskProgress.totalCount))"
        guard statusText.hasSuffix(suffix) else {
            return (statusText, nil)
        }

        return (String(statusText.dropLast(suffix.count)), taskProgress)
    }

    private static func disambiguatedPrimaryText(
        for summary: WorklaneSidebarSummary,
        pathsByWorklaneID: [WorklaneID: String],
        requiredSegmentCountByWorklaneID: [WorklaneID: Int]
    ) -> String? {
        guard summary.attentionState == nil,
              let path = pathsByWorklaneID[summary.worklaneID] else {
            return nil
        }

        let requiredSegmentCount = requiredSegmentCountByWorklaneID[summary.worklaneID] ?? 1
        let compactPrimaryText = WorklaneContextFormatter.compactSidebarPath(path)
        let compactRepositoryPrimaryText = WorklaneContextFormatter.compactRepositorySidebarPath(path)
        let expandedCompactPrimaryText = WorklaneContextFormatter.compactSidebarPath(
            path,
            minimumSegments: requiredSegmentCount
        )
        let expandedCompactRepositoryPrimaryText = WorklaneContextFormatter.compactRepositorySidebarPath(
            path,
            minimumSegments: requiredSegmentCount
        )

        if let compactRepositoryPrimaryText,
           let expandedCompactRepositoryPrimaryText {
            if compactRepositoryPrimaryText.caseInsensitiveCompare(summary.primaryText) == .orderedSame {
                return expandedCompactRepositoryPrimaryText
            }

            if let range = summary.primaryText.range(
                of: compactRepositoryPrimaryText,
                options: [.caseInsensitive]
            ) {
                return summary.primaryText.replacingCharacters(in: range, with: expandedCompactRepositoryPrimaryText)
            }
        }

        guard let compactPrimaryText, let expandedCompactPrimaryText else {
            return nil
        }

        if compactPrimaryText.caseInsensitiveCompare(summary.primaryText) == .orderedSame {
            return expandedCompactPrimaryText
        }

        guard let range = summary.primaryText.range(
            of: compactPrimaryText,
            options: [.caseInsensitive]
        ) else {
            return nil
        }

        return summary.primaryText.replacingCharacters(in: range, with: expandedCompactPrimaryText)
    }

    /// Returns the disambiguation path prefix for a summary (e.g. `"…/Development"`),
    /// intended to be rendered on a dedicated small-font line above the status row.
    /// Returns `nil` when no disambiguation expansion was required.
    private static func disambiguationContextPrefix(
        for summary: WorklaneSidebarSummary,
        pathsByWorklaneID: [WorklaneID: String],
        requiredSegmentCountByWorklaneID: [WorklaneID: Int]
    ) -> String? {
        guard summary.attentionState == nil,
              let path = pathsByWorklaneID[summary.worklaneID] else {
            return nil
        }

        let requiredSegmentCount = requiredSegmentCountByWorklaneID[summary.worklaneID] ?? 1
        guard requiredSegmentCount > 1 else {
            return nil
        }

        let expandedPath =
            WorklaneContextFormatter.compactRepositorySidebarPath(
                path,
                minimumSegments: requiredSegmentCount
            )
            ?? WorklaneContextFormatter.compactSidebarPath(
                path,
                minimumSegments: requiredSegmentCount
            )
        guard let expandedPath else {
            return nil
        }

        return extractContextPrefix(fromExpandedPath: expandedPath)
    }

    /// Strips the trailing leaf path component from an expanded sidebar path and
    /// returns the head, normalized to the `"…/…"` ellipsis convention. Returns
    /// `nil` when the head is empty or carries no useful path information.
    private static func extractContextPrefix(fromExpandedPath expandedPath: String) -> String? {
        guard let slashIndex = expandedPath.lastIndex(of: "/") else {
            return nil
        }
        let head = String(expandedPath[..<slashIndex])
        let trimmed = head.trimmingCharacters(in: .whitespaces)
        guard trimmed.isEmpty == false, trimmed != "…" else {
            return nil
        }
        if trimmed.hasPrefix("…/") || trimmed == "~" || trimmed.hasPrefix("~/") {
            return trimmed
        }
        return "…/" + trimmed
    }

    private static func badge(for title: String?, displayOrder: Int) -> String {
        guard let title = WorklaneState.meaningfulTitle(from: title) else {
            return String(displayOrder)
        }

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

    private static func detailTextRepeatsSinglePanePrimary(
        _ detailText: String,
        primaryText: String,
        metadata: TerminalMetadata?,
        workingDirectory: String?
    ) -> Bool {
        if detailTextRepeatsPrimary(detailText, primaryText: primaryText) {
            return true
        }

        let normalizedPrimaryText = primaryText.trimmingCharacters(in: .whitespacesAndNewlines)
        let branch = WorklaneContextFormatter.displayBranch(metadata?.gitBranch)
        let formattedWorkingDirectory = WorklaneContextFormatter.formattedWorkingDirectory(
            workingDirectory,
            branch: branch
        )

        if let branch,
           detailText.caseInsensitiveCompare(branch) == .orderedSame,
           normalizedPrimaryText.range(of: branch, options: [.caseInsensitive]) != nil {
            return true
        }

        if let formattedWorkingDirectory,
           detailText.caseInsensitiveCompare(formattedWorkingDirectory) == .orderedSame,
           normalizedPrimaryText.range(
                of: formattedWorkingDirectory,
                options: [.caseInsensitive]
           ) != nil {
            return true
        }

        return false
    }
}
