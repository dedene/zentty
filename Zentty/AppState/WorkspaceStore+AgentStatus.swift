import Darwin
import Foundation

extension WorkspaceStore {
    func handleTerminalEvent(paneID: PaneID, event: TerminalEvent) {
        guard let workspaceIndex = workspaces.firstIndex(where: { workspace in
            workspace.paneStripState.panes.contains(where: { $0.id == paneID })
        }) else {
            return
        }

        var workspace = workspaces[workspaceIndex]
        switch event {
        case .progressReport(let report):
            if report.state == .remove {
                workspace.auxiliaryStateByPaneID[paneID]?.terminalProgress = nil
            } else {
                workspace.auxiliaryStateByPaneID[paneID, default: PaneAuxiliaryState()].terminalProgress = report
                if report.state.indicatesActivity {
                    resumeBlockedAgentStateIfWorkResumed(
                        paneID: paneID,
                        now: Date(),
                        in: &workspace
                    )
                }
            }
        case .userSubmittedInput:
            resumeBlockedAgentStateIfWorkResumed(
                paneID: paneID,
                now: Date(),
                in: &workspace
            )
        case .commandFinished:
            workspace.auxiliaryStateByPaneID[paneID]?.terminalProgress = nil
            let existingStatus = workspace.auxiliaryStateByPaneID[paneID]?.agentStatus
            if existingStatus?.state != .idle,
               existingStatus?.state != .needsInput,
               existingStatus?.state != .starting,
               existingStatus?.source == .explicit {
                var auxiliaryState = workspace.auxiliaryStateByPaneID[paneID, default: PaneAuxiliaryState()]
                auxiliaryState.agentReducerState = Self.seededReducerState(
                    auxiliaryState.agentReducerState,
                    from: existingStatus
                )
                auxiliaryState.agentReducerState.markUnresolvedStop(
                    sessionID: existingStatus?.sessionID,
                    now: Date()
                )
                auxiliaryState.agentStatus = auxiliaryState.agentReducerState.reducedStatus()
                workspace.auxiliaryStateByPaneID[paneID] = auxiliaryState
            }
        case .desktopNotification(let notification):
            if let payload = terminalDesktopNotificationPayload(
                paneID: paneID,
                notification: notification,
                in: workspace
            ) {
                var auxiliaryState = workspace.auxiliaryStateByPaneID[paneID, default: PaneAuxiliaryState()]
                auxiliaryState.agentReducerState = Self.seededReducerState(
                    auxiliaryState.agentReducerState,
                    from: auxiliaryState.agentStatus
                )
                auxiliaryState.agentReducerState.apply(payload)
                auxiliaryState.agentStatus = auxiliaryState.agentReducerState.reducedStatus()
                workspace.auxiliaryStateByPaneID[paneID] = auxiliaryState
            }
        }

        recomputePresentation(for: paneID, in: &workspace)
        workspaces[workspaceIndex] = workspace
        notify(.auxiliaryStateUpdated(workspace.id, paneID))
    }

    func applyAgentStatusPayload(_ payload: AgentStatusPayload) {
        guard let workspaceIndex = workspaces.firstIndex(where: { workspace in
            workspace.id == payload.workspaceID
                && workspace.paneStripState.panes.contains(where: { $0.id == payload.paneID })
        }) else {
            return
        }

        var workspace = workspaces[workspaceIndex]

        if payload.clearsStatus {
            var auxiliaryState = workspace.auxiliaryStateByPaneID[payload.paneID, default: PaneAuxiliaryState()]
            auxiliaryState.agentReducerState = Self.seededReducerState(auxiliaryState.agentReducerState, from: auxiliaryState.agentStatus)
            auxiliaryState.agentReducerState.apply(payload)
            auxiliaryState.agentStatus = auxiliaryState.agentReducerState.reducedStatus()
            auxiliaryState.terminalProgress = nil
            workspace.auxiliaryStateByPaneID[payload.paneID] = auxiliaryState
            recomputePresentation(for: payload.paneID, in: &workspace)
            workspaces[workspaceIndex] = workspace
            notify(.auxiliaryStateUpdated(workspace.id, payload.paneID))
            return
        }

        if payload.clearsPaneContext {
            workspace.auxiliaryStateByPaneID[payload.paneID]?.shellContext = nil
            invalidateGitContextIfNeeded(for: payload.paneID, in: &workspace)
            recomputePresentation(for: payload.paneID, in: &workspace)
            workspaces[workspaceIndex] = workspace
            refreshLastFocusedLocalWorkingDirectoryIfNeeded(workspace: workspace, paneID: payload.paneID)
            notify(.auxiliaryStateUpdated(workspace.id, payload.paneID))
            refreshGitContextIfNeeded(for: PaneReference(workspaceID: workspace.id, paneID: payload.paneID))
            return
        }

        let existingStatus = workspace.auxiliaryStateByPaneID[payload.paneID]?.agentStatus
        let tool = AgentTool.resolve(named: payload.toolName)
            ?? existingStatus?.tool
            ?? AgentToolRecognizer.recognize(metadata: workspace.auxiliaryStateByPaneID[payload.paneID]?.metadata)
        var auxiliaryState = workspace.auxiliaryStateByPaneID[payload.paneID, default: PaneAuxiliaryState()]
        auxiliaryState.agentReducerState = Self.seededReducerState(auxiliaryState.agentReducerState, from: existingStatus)

        switch payload.signalKind {
        case .lifecycle:
            guard payload.state != nil, let tool else {
                return
            }
            auxiliaryState.agentReducerState.apply(
                AgentStatusPayload(
                    workspaceID: payload.workspaceID,
                    paneID: payload.paneID,
                    signalKind: payload.signalKind,
                    state: payload.state,
                    shellActivityState: payload.shellActivityState,
                    pid: payload.pid,
                    pidEvent: payload.pidEvent,
                    paneContext: payload.paneContext,
                    origin: payload.origin,
                    toolName: tool.displayName,
                    text: payload.text,
                    lifecycleEvent: payload.lifecycleEvent,
                    interactionKind: payload.interactionKind,
                    confidence: payload.confidence,
                    sessionID: payload.sessionID,
                    parentSessionID: payload.parentSessionID,
                    artifactKind: payload.artifactKind,
                    artifactLabel: payload.artifactLabel,
                    artifactURL: payload.artifactURL
                )
            )
            auxiliaryState.agentStatus = auxiliaryState.agentReducerState.reducedStatus()
            workspace.auxiliaryStateByPaneID[payload.paneID] = auxiliaryState
        case .shellState:
            guard let shellActivityState = payload.shellActivityState else {
                return
            }

            if var existingStatus {
                existingStatus.shellActivityState = shellActivityState
                existingStatus.updatedAt = Date()

                if existingStatus.origin == .shell, existingStatus.trackedPID == nil {
                    switch shellActivityState {
                    case .commandRunning:
                        break
                    case .promptIdle:
                        workspace.auxiliaryStateByPaneID[payload.paneID]?.terminalProgress = nil
                        workspace.auxiliaryStateByPaneID[payload.paneID]?.agentStatus = nil
                        recomputePresentation(for: payload.paneID, in: &workspace)
                        workspaces[workspaceIndex] = workspace
                        notify(.auxiliaryStateUpdated(workspace.id, payload.paneID))
                        return
                    case .unknown:
                        break
                    }
                }

                auxiliaryState.agentStatus = existingStatus
                auxiliaryState.agentReducerState.apply(payload)
                auxiliaryState.agentStatus = auxiliaryState.agentReducerState.reducedStatus() ?? existingStatus
                workspace.auxiliaryStateByPaneID[payload.paneID] = auxiliaryState
            } else {
                return
            }
        case .pid:
            guard let pidEvent = payload.pidEvent else {
                return
            }

            switch pidEvent {
            case .attach:
                guard let tool, let pid = payload.pid else {
                    return
                }
                auxiliaryState.agentReducerState.apply(
                    AgentStatusPayload(
                        workspaceID: payload.workspaceID,
                        paneID: payload.paneID,
                        signalKind: .pid,
                        state: nil,
                        pid: pid,
                        pidEvent: .attach,
                        origin: payload.origin,
                        toolName: tool.displayName,
                        text: nil,
                        confidence: payload.confidence,
                        sessionID: payload.sessionID,
                        parentSessionID: payload.parentSessionID,
                        artifactKind: nil,
                        artifactLabel: nil,
                        artifactURL: nil
                    )
                )
                let status = auxiliaryState.agentReducerState.reducedStatus()
                if existingStatus?.trackedPID != pid {
                    auxiliaryState.presentation.rememberedTitle = nil
                }
                auxiliaryState.agentStatus = status
                workspace.auxiliaryStateByPaneID[payload.paneID] = auxiliaryState
            case .clear:
                guard existingStatus != nil else {
                    return
                }
                auxiliaryState.agentReducerState.apply(payload)
                auxiliaryState.agentStatus = auxiliaryState.agentReducerState.reducedStatus()
                workspace.auxiliaryStateByPaneID[payload.paneID] = auxiliaryState
            }
        case .paneContext:
            guard let paneContext = payload.paneContext else {
                return
            }

            let previousAuxiliaryState = workspace.auxiliaryStateByPaneID[payload.paneID]
            workspace.auxiliaryStateByPaneID[payload.paneID, default: PaneAuxiliaryState()].shellContext = paneContext
            if paneContextChangesBranchContext(
                previous: previousAuxiliaryState,
                next: paneContext,
                metadata: workspace.auxiliaryStateByPaneID[payload.paneID]?.metadata
            ) {
                clearBranchDerivedState(for: payload.paneID, in: &workspace)
                workspace.auxiliaryStateByPaneID[payload.paneID]?.gitContext = nil
                invalidateCachedGitContext(
                    path: WorkspaceContextFormatter.resolvedWorkingDirectory(
                        for: workspace.auxiliaryStateByPaneID[payload.paneID]?.metadata,
                        shellContext: paneContext
                    )
                )
            } else {
                invalidateGitContextIfNeeded(for: payload.paneID, in: &workspace)
            }
        }

        recomputePresentation(for: payload.paneID, in: &workspace)
        workspaces[workspaceIndex] = workspace
        refreshLastFocusedLocalWorkingDirectoryIfNeeded(workspace: workspace, paneID: payload.paneID)
        notify(.auxiliaryStateUpdated(workspace.id, payload.paneID))
        if payload.signalKind == .paneContext {
            refreshGitContextIfNeeded(for: PaneReference(workspaceID: workspace.id, paneID: payload.paneID))
        }
    }

    private func paneContextChangesBranchContext(
        previous: PaneAuxiliaryState?,
        next: PaneShellContext,
        metadata: TerminalMetadata?
    ) -> Bool {
        let previousScope = previous?.shellContext?.scope
        if previousScope != next.scope {
            return true
        }

        guard next.scope == .local else {
            return false
        }

        let previousWorkingDirectory = previous?.localReviewWorkingDirectory
        let nextWorkingDirectory = WorkspaceContextFormatter.resolvedWorkingDirectory(
            for: metadata,
            shellContext: next
        ) ?? WorkspaceContextFormatter.trimmed(next.path)
        if previousWorkingDirectory != nextWorkingDirectory {
            return true
        }

        let previousBranchDisplay = WorkspaceContextFormatter.trimmed(previous?.presentation.branchDisplayText)
        let nextBranchDisplay = WorkspaceContextFormatter.displayBranch(next.gitBranch)
        return previousBranchDisplay != nextBranchDisplay
    }

    private func invalidateCachedGitContext(path: String?) {
        guard let path = WorkspaceContextFormatter.trimmed(path) else {
            return
        }

        cachedGitContextByPath.removeValue(forKey: path)
        knownNonRepositoryPaths.remove(path)
    }

    func clearStaleAgentSessions() {
        var didChange = false

        for workspaceIndex in workspaces.indices {
            var workspace = workspaces[workspaceIndex]

            for (paneID, aux) in workspace.auxiliaryStateByPaneID {
                if !aux.agentReducerState.sessionsByID.isEmpty {
                    var reducerState = aux.agentReducerState
                    reducerState.sweep(now: Date(), isProcessAlive: Self.isProcessAlive(pid:))
                    let reducedStatus = reducerState.reducedStatus()
                    if reducerState != aux.agentReducerState || reducedStatus != aux.agentStatus {
                        didChange = true
                        workspace.auxiliaryStateByPaneID[paneID]?.agentReducerState = reducerState
                        workspace.auxiliaryStateByPaneID[paneID]?.agentStatus = reducedStatus
                        if reducedStatus == nil {
                            workspace.auxiliaryStateByPaneID[paneID]?.terminalProgress = nil
                        }
                        recomputePresentation(for: paneID, in: &workspace)
                    }
                    continue
                }

                guard let status = aux.agentStatus else {
                    continue
                }

                guard let trackedPID = status.trackedPID, !Self.isProcessAlive(pid: trackedPID) else {
                    continue
                }

                didChange = true
                if status.state == .starting || status.state == .running || status.requiresHumanAttention {
                    workspace.auxiliaryStateByPaneID[paneID]?.agentStatus = nil
                    workspace.auxiliaryStateByPaneID[paneID]?.terminalProgress = nil
                } else {
                    var nextStatus = status
                    nextStatus.trackedPID = nil
                    workspace.auxiliaryStateByPaneID[paneID]?.agentStatus = nextStatus
                }
                recomputePresentation(for: paneID, in: &workspace)
            }

            workspaces[workspaceIndex] = workspace
        }

        if didChange {
            notify(.workspaceListChanged)
        }
    }

    private static func seededReducerState(
        _ reducerState: PaneAgentReducerState,
        from existingStatus: PaneAgentStatus?
    ) -> PaneAgentReducerState {
        guard reducerState.sessionsByID.isEmpty, let existingStatus else {
            return reducerState
        }

        var seededReducerState = reducerState
        let sessionID = existingStatus.sessionID ?? "pane-\(existingStatus.tool.displayName.lowercased())"
        seededReducerState.sessionsByID[sessionID] = PaneAgentSessionState(
            sessionID: sessionID,
            parentSessionID: existingStatus.parentSessionID,
            tool: existingStatus.tool,
            state: existingStatus.state,
            text: existingStatus.text,
            artifactLink: existingStatus.artifactLink,
            updatedAt: existingStatus.updatedAt,
            source: existingStatus.source,
            origin: existingStatus.origin,
            interactionKind: existingStatus.interactionKind,
            confidence: existingStatus.confidence,
            shellActivityState: existingStatus.shellActivityState,
            trackedPID: existingStatus.trackedPID,
            hasObservedRunning: existingStatus.hasObservedRunning,
            completionCandidateDeadline: nil,
            idleVisibleUntil: existingStatus.state == .idle
                ? existingStatus.updatedAt.addingTimeInterval(PaneAgentReducerState.idleVisibilityWindow)
                : nil,
            unresolvedStopVisibleUntil: existingStatus.state == .unresolvedStop
                ? existingStatus.updatedAt.addingTimeInterval(PaneAgentReducerState.unresolvedStopVisibilityWindow)
                : nil
        )
        return seededReducerState
    }

    private func terminalDesktopNotificationPayload(
        paneID: PaneID,
        notification: TerminalDesktopNotification,
        in workspace: WorkspaceState
    ) -> AgentStatusPayload? {
        let title = AgentInteractionClassifier.trimmed(notification.title)
        let body = AgentInteractionClassifier.trimmed(notification.body)
        let combinedParts = [title, body].compactMap { $0 }
        let combinedMessage = combinedParts.isEmpty ? nil : combinedParts.joined(separator: "\n")

        guard AgentInteractionClassifier.requiresHumanInput(message: combinedMessage) else {
            return nil
        }

        let existingStatus = workspace.auxiliaryStateByPaneID[paneID]?.agentStatus
        let tool = existingStatus?.tool
            ?? AgentToolRecognizer.recognize(metadata: workspace.auxiliaryStateByPaneID[paneID]?.metadata)
        guard let tool else {
            return nil
        }

        return AgentStatusPayload(
            workspaceID: workspace.id,
            paneID: paneID,
            signalKind: .lifecycle,
            state: .needsInput,
            origin: .heuristic,
            toolName: tool.displayName,
            text: body ?? combinedMessage,
            interactionKind: .genericInput,
            confidence: .strong,
            sessionID: existingStatus?.sessionID,
            parentSessionID: existingStatus?.parentSessionID,
            artifactKind: nil,
            artifactLabel: nil,
            artifactURL: nil
        )
    }

    private func resumeBlockedAgentStateIfWorkResumed(
        paneID: PaneID,
        now: Date,
        in workspace: inout WorkspaceState
    ) {
        guard var auxiliaryState = workspace.auxiliaryStateByPaneID[paneID],
              auxiliaryState.agentStatus?.state == .needsInput
        else {
            return
        }

        auxiliaryState.agentReducerState = Self.seededReducerState(
            auxiliaryState.agentReducerState,
            from: auxiliaryState.agentStatus
        )
        guard auxiliaryState.agentReducerState.resumeBlockedSessionFromActivity(now: now) else {
            return
        }

        auxiliaryState.agentStatus = auxiliaryState.agentReducerState.reducedStatus(now: now)
        workspace.auxiliaryStateByPaneID[paneID] = auxiliaryState
    }

    private static func isProcessAlive(pid: Int32) -> Bool {
        guard pid > 0 else {
            return false
        }

        if kill(pid, 0) == 0 {
            return true
        }

        return errno == EPERM
    }
}
