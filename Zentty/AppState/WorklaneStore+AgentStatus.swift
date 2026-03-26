import Darwin
import Foundation

extension WorklaneStore {
    func handleTerminalEvent(paneID: PaneID, event: TerminalEvent) {
        guard let worklaneIndex = worklanes.firstIndex(where: { worklane in
            worklane.paneStripState.panes.contains(where: { $0.id == paneID })
        }) else {
            return
        }

        var worklane = worklanes[worklaneIndex]
        switch event {
        case .progressReport(let report):
            if report.state == .remove {
                worklane.auxiliaryStateByPaneID[paneID]?.terminalProgress = nil
            } else {
                worklane.auxiliaryStateByPaneID[paneID, default: PaneAuxiliaryState()].terminalProgress = report
                if report.state.indicatesActivity {
                    resumeBlockedAgentStateIfWorkResumed(
                        paneID: paneID,
                        now: Date(),
                        in: &worklane
                    )
                }
            }
        case .userSubmittedInput:
            resumeBlockedAgentStateIfWorkResumed(
                paneID: paneID,
                now: Date(),
                in: &worklane
            )
        case .commandFinished:
            worklane.auxiliaryStateByPaneID[paneID]?.terminalProgress = nil
            let existingStatus = worklane.auxiliaryStateByPaneID[paneID]?.agentStatus
            if existingStatus?.state != .idle,
               existingStatus?.state != .needsInput,
               existingStatus?.state != .starting,
               existingStatus?.source == .explicit {
                var auxiliaryState = worklane.auxiliaryStateByPaneID[paneID, default: PaneAuxiliaryState()]
                auxiliaryState.agentReducerState = Self.seededReducerState(
                    auxiliaryState.agentReducerState,
                    from: existingStatus
                )
                auxiliaryState.agentReducerState.markUnresolvedStop(
                    sessionID: existingStatus?.sessionID,
                    now: Date()
                )
                auxiliaryState.agentStatus = auxiliaryState.agentReducerState.reducedStatus()
                worklane.auxiliaryStateByPaneID[paneID] = auxiliaryState
            }
        case .desktopNotification(let notification):
            let title = AgentInteractionClassifier.trimmed(notification.title)
            let body = AgentInteractionClassifier.trimmed(notification.body)
            let combined = [title, body].compactMap { $0 }.joined(separator: ": ")
            let notificationText: String? = combined.isEmpty ? nil : combined

            if let notificationText {
                var auxiliaryState = worklane.auxiliaryStateByPaneID[paneID, default: PaneAuxiliaryState()]
                auxiliaryState.raw.lastDesktopNotificationText = notificationText
                auxiliaryState.raw.lastDesktopNotificationDate = Date()
                worklane.auxiliaryStateByPaneID[paneID] = auxiliaryState
            }

            if let payload = terminalDesktopNotificationPayload(
                paneID: paneID,
                notification: notification,
                in: worklane
            ) {
                var auxiliaryState = worklane.auxiliaryStateByPaneID[paneID, default: PaneAuxiliaryState()]
                auxiliaryState.agentReducerState = Self.seededReducerState(
                    auxiliaryState.agentReducerState,
                    from: auxiliaryState.agentStatus
                )
                auxiliaryState.agentReducerState.apply(payload)
                auxiliaryState.agentStatus = auxiliaryState.agentReducerState.reducedStatus()
                worklane.auxiliaryStateByPaneID[paneID] = auxiliaryState
            }
        }

        recomputePresentation(for: paneID, in: &worklane)
        worklanes[worklaneIndex] = worklane
        notify(.auxiliaryStateUpdated(worklane.id, paneID))
    }

    func applyAgentStatusPayload(_ payload: AgentStatusPayload) {
        guard let worklaneIndex = worklanes.firstIndex(where: { worklane in
            worklane.id == payload.worklaneID
                && worklane.paneStripState.panes.contains(where: { $0.id == payload.paneID })
        }) else {
            return
        }

        var worklane = worklanes[worklaneIndex]

        if payload.clearsStatus {
            var auxiliaryState = worklane.auxiliaryStateByPaneID[payload.paneID, default: PaneAuxiliaryState()]
            auxiliaryState.agentReducerState = Self.seededReducerState(auxiliaryState.agentReducerState, from: auxiliaryState.agentStatus)
            auxiliaryState.agentReducerState.apply(payload)
            auxiliaryState.agentStatus = auxiliaryState.agentReducerState.reducedStatus()
            auxiliaryState.terminalProgress = nil
            worklane.auxiliaryStateByPaneID[payload.paneID] = auxiliaryState
            recomputePresentation(for: payload.paneID, in: &worklane)
            worklanes[worklaneIndex] = worklane
            notify(.auxiliaryStateUpdated(worklane.id, payload.paneID))
            return
        }

        if payload.clearsPaneContext {
            worklane.auxiliaryStateByPaneID[payload.paneID]?.shellContext = nil
            invalidateGitContextIfNeeded(for: payload.paneID, in: &worklane)
            recomputePresentation(for: payload.paneID, in: &worklane)
            worklanes[worklaneIndex] = worklane
            refreshLastFocusedLocalWorkingDirectoryIfNeeded(worklane: worklane, paneID: payload.paneID)
            notify(.auxiliaryStateUpdated(worklane.id, payload.paneID))
            refreshGitContextIfNeeded(for: PaneReference(worklaneID: worklane.id, paneID: payload.paneID))
            return
        }

        let existingStatus = worklane.auxiliaryStateByPaneID[payload.paneID]?.agentStatus
        let tool = AgentTool.resolve(named: payload.toolName)
            ?? existingStatus?.tool
            ?? AgentToolRecognizer.recognize(metadata: worklane.auxiliaryStateByPaneID[payload.paneID]?.metadata)
        var auxiliaryState = worklane.auxiliaryStateByPaneID[payload.paneID, default: PaneAuxiliaryState()]
        auxiliaryState.agentReducerState = Self.seededReducerState(auxiliaryState.agentReducerState, from: existingStatus)

        switch payload.signalKind {
        case .lifecycle:
            guard payload.state != nil, let tool else {
                return
            }
            auxiliaryState.agentReducerState.apply(
                AgentStatusPayload(
                    worklaneID: payload.worklaneID,
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
                    artifactURL: payload.artifactURL,
                    agentWorkingDirectory: payload.agentWorkingDirectory
                )
            )
            auxiliaryState.agentStatus = Self.hydratedStatus(
                auxiliaryState.agentReducerState.reducedStatus(),
                existingStatus: existingStatus,
                payloadWorkingDirectory: payload.agentWorkingDirectory
            )
            worklane.auxiliaryStateByPaneID[payload.paneID] = auxiliaryState
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
                        worklane.auxiliaryStateByPaneID[payload.paneID]?.terminalProgress = nil
                        worklane.auxiliaryStateByPaneID[payload.paneID]?.agentStatus = nil
                        recomputePresentation(for: payload.paneID, in: &worklane)
                        worklanes[worklaneIndex] = worklane
                        notify(.auxiliaryStateUpdated(worklane.id, payload.paneID))
                        return
                    case .unknown:
                        break
                    }
                }

                auxiliaryState.agentStatus = existingStatus
                auxiliaryState.agentReducerState.apply(payload)
                auxiliaryState.agentStatus = Self.hydratedStatus(
                    auxiliaryState.agentReducerState.reducedStatus() ?? existingStatus,
                    existingStatus: existingStatus,
                    payloadWorkingDirectory: payload.agentWorkingDirectory
                )
                worklane.auxiliaryStateByPaneID[payload.paneID] = auxiliaryState
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
                        worklaneID: payload.worklaneID,
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
                        artifactURL: nil,
                        agentWorkingDirectory: payload.agentWorkingDirectory
                    )
                )
                var status = Self.hydratedStatus(
                    auxiliaryState.agentReducerState.reducedStatus(),
                    existingStatus: existingStatus,
                    payloadWorkingDirectory: payload.agentWorkingDirectory
                )
                if status?.workingDirectory == nil,
                   let processCwd = ProcessCWDResolver.workingDirectory(for: pid),
                   WorklaneContextFormatter.trimmed(processCwd) != nil {
                    status?.workingDirectory = processCwd
                }
                if existingStatus?.trackedPID != pid {
                    auxiliaryState.presentation.rememberedTitle = nil
                }
                auxiliaryState.agentStatus = status
                worklane.auxiliaryStateByPaneID[payload.paneID] = auxiliaryState
            case .clear:
                guard existingStatus != nil else {
                    return
                }
                auxiliaryState.agentReducerState.apply(payload)
                auxiliaryState.agentStatus = Self.hydratedStatus(
                    auxiliaryState.agentReducerState.reducedStatus(),
                    existingStatus: existingStatus,
                    payloadWorkingDirectory: payload.agentWorkingDirectory
                )
                worklane.auxiliaryStateByPaneID[payload.paneID] = auxiliaryState
            }
        case .paneContext:
            guard let paneContext = payload.paneContext else {
                return
            }

            let previousAuxiliaryState = worklane.auxiliaryStateByPaneID[payload.paneID]
            worklane.auxiliaryStateByPaneID[payload.paneID, default: PaneAuxiliaryState()].shellContext = paneContext
            if paneContextChangesBranchContext(
                previous: previousAuxiliaryState,
                next: paneContext,
                metadata: worklane.auxiliaryStateByPaneID[payload.paneID]?.metadata
            ) {
                clearBranchDerivedState(for: payload.paneID, in: &worklane)
                worklane.auxiliaryStateByPaneID[payload.paneID]?.gitContext = nil
                invalidateCachedGitContext(
                    path: WorklaneContextFormatter.resolvedWorkingDirectory(
                        for: worklane.auxiliaryStateByPaneID[payload.paneID]?.metadata,
                        shellContext: paneContext
                    )
                )
            } else {
                invalidateGitContextIfNeeded(for: payload.paneID, in: &worklane)
            }
        }

        recomputePresentation(for: payload.paneID, in: &worklane)
        worklanes[worklaneIndex] = worklane
        refreshLastFocusedLocalWorkingDirectoryIfNeeded(worklane: worklane, paneID: payload.paneID)
        notify(.auxiliaryStateUpdated(worklane.id, payload.paneID))
        if payload.signalKind == .paneContext || payload.agentWorkingDirectory != nil {
            refreshGitContextIfNeeded(for: PaneReference(worklaneID: worklane.id, paneID: payload.paneID))
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
        let nextWorkingDirectory = WorklaneContextFormatter.resolvedWorkingDirectory(
            for: metadata,
            shellContext: next
        ) ?? WorklaneContextFormatter.trimmed(next.path)
        if previousWorkingDirectory != nextWorkingDirectory {
            return true
        }

        let previousBranchDisplay = WorklaneContextFormatter.trimmed(previous?.presentation.branchDisplayText)
        let nextBranchDisplay = WorklaneContextFormatter.displayBranch(next.gitBranch)
        return previousBranchDisplay != nextBranchDisplay
    }

    private func invalidateCachedGitContext(path: String?) {
        guard let path = WorklaneContextFormatter.trimmed(path) else {
            return
        }

        cachedGitContextByPath.removeValue(forKey: path)
        knownNonRepositoryPaths.remove(path)
    }

    func clearStaleAgentSessions() {
        var didChange = false

        for worklaneIndex in worklanes.indices {
            var worklane = worklanes[worklaneIndex]

            for (paneID, aux) in worklane.auxiliaryStateByPaneID {
                if !aux.agentReducerState.sessionsByID.isEmpty {
                    var reducerState = aux.agentReducerState
                    reducerState.sweep(now: Date(), isProcessAlive: Self.isProcessAlive(pid:))
                    var reducedStatus = Self.hydratedStatus(
                        reducerState.reducedStatus(),
                        existingStatus: aux.agentStatus
                    )
                    if let trackedPID = reducedStatus?.trackedPID,
                       (reducedStatus?.state == .starting || reducedStatus?.state == .running),
                       reducedStatus?.workingDirectory == nil,
                       let processCwd = ProcessCWDResolver.workingDirectory(for: trackedPID),
                       WorklaneContextFormatter.trimmed(processCwd) != nil {
                        reducedStatus?.workingDirectory = processCwd
                    }
                    if reducerState != aux.agentReducerState || reducedStatus != aux.agentStatus {
                        didChange = true
                        worklane.auxiliaryStateByPaneID[paneID]?.agentReducerState = reducerState
                        worklane.auxiliaryStateByPaneID[paneID]?.agentStatus = reducedStatus
                        if reducedStatus == nil {
                            worklane.auxiliaryStateByPaneID[paneID]?.terminalProgress = nil
                        }
                        recomputePresentation(for: paneID, in: &worklane)
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
                    worklane.auxiliaryStateByPaneID[paneID]?.agentStatus = nil
                    worklane.auxiliaryStateByPaneID[paneID]?.terminalProgress = nil
                } else {
                    var nextStatus = status
                    nextStatus.trackedPID = nil
                    worklane.auxiliaryStateByPaneID[paneID]?.agentStatus = nextStatus
                }
                recomputePresentation(for: paneID, in: &worklane)
            }

            worklanes[worklaneIndex] = worklane
        }

        if didChange {
            notify(.worklaneListChanged)
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

    private static func hydratedStatus(
        _ status: PaneAgentStatus?,
        existingStatus: PaneAgentStatus?,
        payloadWorkingDirectory: String? = nil
    ) -> PaneAgentStatus? {
        guard var status else {
            return nil
        }

        status.workingDirectory = WorklaneContextFormatter.trimmed(payloadWorkingDirectory)
            ?? existingStatus?.workingDirectory
        return status
    }

    private func terminalDesktopNotificationPayload(
        paneID: PaneID,
        notification: TerminalDesktopNotification,
        in worklane: WorklaneState
    ) -> AgentStatusPayload? {
        let title = AgentInteractionClassifier.trimmed(notification.title)
        let body = AgentInteractionClassifier.trimmed(notification.body)
        let combinedParts = [title, body].compactMap { $0 }
        let combinedMessage = combinedParts.isEmpty ? nil : combinedParts.joined(separator: "\n")

        guard AgentInteractionClassifier.requiresHumanInput(message: combinedMessage) else {
            return nil
        }

        let existingStatus = worklane.auxiliaryStateByPaneID[paneID]?.agentStatus
        let tool = existingStatus?.tool
            ?? AgentToolRecognizer.recognize(metadata: worklane.auxiliaryStateByPaneID[paneID]?.metadata)
        guard let tool else {
            return nil
        }

        return AgentStatusPayload(
            worklaneID: worklane.id,
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
        in worklane: inout WorklaneState
    ) {
        guard var auxiliaryState = worklane.auxiliaryStateByPaneID[paneID],
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
        worklane.auxiliaryStateByPaneID[paneID] = auxiliaryState
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
