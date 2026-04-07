import Darwin
import Foundation
import os

private let worklaneStoreLogger = Logger(subsystem: "be.zenjoy.zentty", category: "WorklaneStore")
@MainActor private var loggedUnclassifiedCodexDesktopNotifications: Set<String> = []

extension WorklaneStore {
    func handleTerminalEvent(paneID: PaneID, event: TerminalEvent) {
        guard let worklaneIndex = worklanes.firstIndex(where: { worklane in
            worklane.paneStripState.panes.contains(where: { $0.id == paneID })
        }) else {
            return
        }

        var worklane = worklanes[worklaneIndex]
        let previousWorklane = worklane
        switch event {
        case .progressReport(let report):
            let now = Date()
            if report.state == .remove {
                worklane.auxiliaryStateByPaneID[paneID]?.terminalProgress = nil
            } else {
                let existingStatus = worklane.auxiliaryStateByPaneID[paneID]?.agentStatus
                let showsReadyStatus = worklane.auxiliaryStateByPaneID[paneID]?.raw.showsReadyStatus == true
                worklane.auxiliaryStateByPaneID[paneID, default: PaneAuxiliaryState()].terminalProgress = report
                if report.state.indicatesActivity {
                    if shouldClearReadyStatusForProgressReport(
                        existingStatus: existingStatus,
                        showsReadyStatus: showsReadyStatus
                    ) {
                        clearReadyStatusIfNeeded(for: paneID, in: &worklane)
                    }
                    promoteCodexAgentStateFromUserInput(
                        paneID: paneID,
                        now: now,
                        in: &worklane
                    )
                    resumeBlockedAgentStateIfWorkResumed(
                        paneID: paneID,
                        now: now,
                        in: &worklane
                    )
                }
            }
        case .userSubmittedInput:
            let now = Date()
            clearReadyStatusIfNeeded(for: paneID, in: &worklane)
            promoteCodexAgentStateFromUserInput(
                paneID: paneID,
                now: now,
                in: &worklane
            )
            resumeBlockedAgentStateIfWorkResumed(
                paneID: paneID,
                now: now,
                in: &worklane
            )
        case .commandFinished:
            worklane.auxiliaryStateByPaneID[paneID]?.terminalProgress = nil
            let existingStatus = worklane.auxiliaryStateByPaneID[paneID]?.agentStatus
            if let trackedPID = existingStatus?.trackedPID,
               Self.isProcessAlive(pid: trackedPID) {
                break
            }
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
        case .surfaceClosed:
            return
        case .desktopNotification(let notification):
            let title = AgentInteractionClassifier.trimmed(notification.title)
            let body = AgentInteractionClassifier.trimmed(notification.body)
            let combined = [title, body].compactMap { $0 }.joined(separator: ": ")
            let notificationText: String? = combined.isEmpty ? nil : combined
            let recognizedTool = worklane.auxiliaryStateByPaneID[paneID]?.agentStatus?.tool
                ?? AgentToolRecognizer.recognize(metadata: worklane.auxiliaryStateByPaneID[paneID]?.metadata)
                ?? AgentTool.resolveKnown(named: title)

            if let notificationText {
                var auxiliaryState = worklane.auxiliaryStateByPaneID[paneID, default: PaneAuxiliaryState()]
                auxiliaryState.raw.lastDesktopNotificationText = notificationText
                auxiliaryState.raw.lastDesktopNotificationDate = Date()
                worklane.auxiliaryStateByPaneID[paneID] = auxiliaryState
                if completionNotificationIndicatesReady(notificationText) {
                    requestReadyStatusIfNeeded(for: paneID, in: &worklane)
                }
            }

            let payload = terminalDesktopNotificationPayload(
                paneID: paneID,
                notification: notification,
                in: worklane
            )
            logCodexDesktopNotificationIfNeeded(
                paneID: paneID,
                worklane: worklane,
                recognizedTool: recognizedTool,
                notificationText: notificationText,
                interactionKind: payload?.interactionKind
            )

            if let payload {
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
        let impacts = auxiliaryInvalidation(for: paneID, previousWorklane: previousWorklane, nextWorklane: worklane)
        if !impacts.isEmpty {
            notify(.auxiliaryStateUpdated(worklane.id, paneID, impacts))
        }
    }

    func applyAgentStatusPayload(_ payload: AgentStatusPayload) {
        let worklaneIndex: Int
        if let exact = worklanes.firstIndex(where: { worklane in
            worklane.id == payload.worklaneID
                && worklane.paneStripState.panes.contains(where: { $0.id == payload.paneID })
        }) {
            worklaneIndex = exact
        } else if let fallback = worklanes.firstIndex(where: { worklane in
            worklane.paneStripState.panes.contains(where: { $0.id == payload.paneID })
        }) {
            worklaneStoreLogger.debug(
                "Agent status fallback routing payload pane=\(payload.paneID.rawValue, privacy: .public) payloadWorklane=\(payload.worklaneID.rawValue, privacy: .public) actualWorklane=\(self.worklanes[fallback].id.rawValue, privacy: .public)"
            )
            worklaneIndex = fallback
        } else {
            return
        }

        var worklane = worklanes[worklaneIndex]
        let previousWorklane = worklane

        if payload.clearsStatus {
            var auxiliaryState = worklane.auxiliaryStateByPaneID[payload.paneID, default: PaneAuxiliaryState()]
            auxiliaryState.agentReducerState = Self.seededReducerState(auxiliaryState.agentReducerState, from: auxiliaryState.agentStatus)
            auxiliaryState.agentReducerState.apply(payload)
            auxiliaryState.agentStatus = auxiliaryState.agentReducerState.reducedStatus()
            auxiliaryState.raw.wantsReadyStatus = false
            auxiliaryState.raw.showsReadyStatus = false
            auxiliaryState.terminalProgress = nil
            worklane.auxiliaryStateByPaneID[payload.paneID] = auxiliaryState
            cancelPendingReadyStatus(for: PaneReference(worklaneID: worklane.id, paneID: payload.paneID))
            recomputePresentation(for: payload.paneID, in: &worklane)
            worklanes[worklaneIndex] = worklane
            let impacts = auxiliaryInvalidation(for: payload.paneID, previousWorklane: previousWorklane, nextWorklane: worklane)
            if !impacts.isEmpty {
                notify(.auxiliaryStateUpdated(worklane.id, payload.paneID, impacts))
            }
            return
        }

        if payload.clearsPaneContext {
            worklane.auxiliaryStateByPaneID[payload.paneID]?.shellContext = nil
            invalidateGitContextIfNeeded(for: payload.paneID, in: &worklane)
            recomputePresentation(for: payload.paneID, in: &worklane)
            worklanes[worklaneIndex] = worklane
            refreshLastFocusedLocalWorkingDirectoryIfNeeded(worklane: worklane, paneID: payload.paneID)
            let impacts = auxiliaryInvalidation(for: payload.paneID, previousWorklane: previousWorklane, nextWorklane: worklane)
            if !impacts.isEmpty {
                notify(.auxiliaryStateUpdated(worklane.id, payload.paneID, impacts))
            }
            if auxiliaryUpdateRequiresGitContextRefresh(for: payload.paneID, previousWorklane: previousWorklane, nextWorklane: worklane) {
                refreshGitContextIfNeeded(for: PaneReference(worklaneID: worklane.id, paneID: payload.paneID))
            }
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
            reconcileReadyStatus(
                existingStatus: existingStatus,
                payload: payload,
                paneID: payload.paneID,
                in: &worklane
            )
        case .shellState:
            guard let shellActivityState = payload.shellActivityState else {
                return
            }

            // Pane-level state: always persisted, independent of agent status.
            auxiliaryState.shellActivityState = shellActivityState
            if shellActivityState == .commandRunning {
                auxiliaryState.hasCommandHistory = true
            }

            if var existingStatus {
                existingStatus.shellActivityState = shellActivityState
                existingStatus.updatedAt = Date()

                if existingStatus.origin == .shell, existingStatus.trackedPID == nil {
                    switch shellActivityState {
                    case .commandRunning:
                        break
                    case .promptIdle:
                        auxiliaryState.terminalProgress = nil
                        auxiliaryState.agentStatus = nil
                        worklane.auxiliaryStateByPaneID[payload.paneID] = auxiliaryState
                        recomputePresentation(for: payload.paneID, in: &worklane)
                        worklanes[worklaneIndex] = worklane
                        let impacts = auxiliaryInvalidation(for: payload.paneID, previousWorklane: previousWorklane, nextWorklane: worklane)
                        if !impacts.isEmpty {
                            notify(.auxiliaryStateUpdated(worklane.id, payload.paneID, impacts))
                        }
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
            }

            worklane.auxiliaryStateByPaneID[payload.paneID] = auxiliaryState
            reconcileReadyStatus(
                existingStatus: existingStatus,
                payload: payload,
                paneID: payload.paneID,
                in: &worklane
            )
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
                reconcileReadyStatus(
                    existingStatus: existingStatus,
                    payload: payload,
                    paneID: payload.paneID,
                    in: &worklane
                )
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
                reconcileReadyStatus(
                    existingStatus: existingStatus,
                    payload: payload,
                    paneID: payload.paneID,
                    in: &worklane
                )
            }
        case .paneContext:
            guard let paneContext = payload.paneContext else {
                return
            }

            let previousAuxiliaryState = worklane.auxiliaryStateByPaneID[payload.paneID]
            let requestWorkingDirectory = nonInheritedSessionWorkingDirectory(for: payload.paneID, in: worklane)
            worklane.auxiliaryStateByPaneID[payload.paneID, default: PaneAuxiliaryState()].shellContext = paneContext
            if paneContextChangesBranchContext(
                previous: previousAuxiliaryState,
                next: paneContext,
                metadata: worklane.auxiliaryStateByPaneID[payload.paneID]?.metadata,
                requestWorkingDirectory: requestWorkingDirectory
            ) {
                clearBranchDerivedState(for: payload.paneID, in: &worklane)
                worklane.auxiliaryStateByPaneID[payload.paneID]?.gitContext = nil
                invalidateCachedGitContext(path: PaneTerminalLocationResolver.snapshot(
                    metadata: worklane.auxiliaryStateByPaneID[payload.paneID]?.metadata,
                    shellContext: paneContext,
                    requestWorkingDirectory: requestWorkingDirectory
                ).workingDirectory)
            } else {
                invalidateGitContextIfNeeded(for: payload.paneID, in: &worklane)
            }
        }

        promoteCodexRunningIfCurrentTitleIndicatesRunning(
            paneID: payload.paneID,
            in: &worklane
        )

        recomputePresentation(for: payload.paneID, in: &worklane)
        worklanes[worklaneIndex] = worklane
        refreshLastFocusedLocalWorkingDirectoryIfNeeded(worklane: worklane, paneID: payload.paneID)
        let impacts = auxiliaryInvalidation(for: payload.paneID, previousWorklane: previousWorklane, nextWorklane: worklane)
        if !impacts.isEmpty {
            notify(.auxiliaryStateUpdated(worklane.id, payload.paneID, impacts))
        }
        if auxiliaryUpdateRequiresGitContextRefresh(for: payload.paneID, previousWorklane: previousWorklane, nextWorklane: worklane) {
            refreshGitContextIfNeeded(for: PaneReference(worklaneID: worklane.id, paneID: payload.paneID))
        }
    }

    private func paneContextChangesBranchContext(
        previous: PaneAuxiliaryState?,
        next: PaneShellContext,
        metadata: TerminalMetadata?,
        requestWorkingDirectory: String?
    ) -> Bool {
        let previousScope = previous?.shellContext?.scope
        if previousScope != next.scope {
            return true
        }

        guard next.scope == .local else {
            return false
        }

        let previousWorkingDirectory = PaneTerminalLocationResolver.snapshot(
            metadata: previous?.metadata,
            shellContext: previous?.shellContext,
            requestWorkingDirectory: requestWorkingDirectory
        ).workingDirectory
        let nextWorkingDirectory = PaneTerminalLocationResolver.snapshot(
            metadata: metadata,
            shellContext: next,
            requestWorkingDirectory: requestWorkingDirectory
        ).workingDirectory
        if previousWorkingDirectory != nextWorkingDirectory {
            return true
        }

        let previousBranchDisplay = WorklaneContextFormatter.trimmed(previous?.presentation.branchDisplayText)
        let nextBranchDisplay = WorklaneContextFormatter.displayBranch(next.gitBranch)
        return previousBranchDisplay != nextBranchDisplay
    }

    private func reconcileReadyStatus(
        existingStatus: PaneAgentStatus?,
        payload: AgentStatusPayload,
        paneID: PaneID,
        in worklane: inout WorklaneState
    ) {
        let nextStatus = worklane.auxiliaryStateByPaneID[paneID]?.agentStatus

        if shouldEnterReadyStatus(from: existingStatus, to: nextStatus) {
            requestReadyStatusIfNeeded(for: paneID, in: &worklane)
            return
        }

        if shouldClearReadyStatus(for: nextStatus, payload: payload) {
            clearReadyStatusIfNeeded(for: paneID, in: &worklane)
        }
    }

    private func shouldEnterReadyStatus(
        from existingStatus: PaneAgentStatus?,
        to nextStatus: PaneAgentStatus?
    ) -> Bool {
        guard let nextStatus,
              nextStatus.state == .idle,
              nextStatus.hasObservedRunning,
              let existingStatus,
              existingStatus.state != .idle else {
            return false
        }

        return true
    }

    private func shouldClearReadyStatus(
        for nextStatus: PaneAgentStatus?,
        payload: AgentStatusPayload
    ) -> Bool {
        if payload.clearsStatus {
            return true
        }

        guard let nextStatus else {
            return false
        }

        return nextStatus.state != .idle
    }

    private func shouldClearReadyStatusForProgressReport(
        existingStatus: PaneAgentStatus?,
        showsReadyStatus: Bool
    ) -> Bool {
        guard showsReadyStatus,
              existingStatus?.state == .idle else {
            return true
        }

        return false
    }

    private func completionNotificationIndicatesReady(_ notificationText: String?) -> Bool {
        guard let notificationText = AgentInteractionClassifier.trimmed(notificationText)?.lowercased() else {
            return false
        }

        return notificationText.contains("agent run complete")
            || notificationText.contains("agent ready")
            || notificationText.contains("agent turn complete")
    }

    func invalidateCachedGitContext(path: String?) {
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

    static func seededReducerState(
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

    static func hydratedStatus(
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
            ?? AgentTool.resolveKnown(named: title)
        guard let tool else {
            return nil
        }

        let interactionKind = AgentInteractionClassifier.interactionKind(forWaitingMessage: combinedMessage)
            ?? .genericInput

        return AgentStatusPayload(
            worklaneID: worklane.id,
            paneID: paneID,
            signalKind: .lifecycle,
            state: .needsInput,
            origin: .heuristic,
            toolName: tool.displayName,
            text: body ?? combinedMessage,
            interactionKind: interactionKind,
            confidence: .strong,
            sessionID: existingStatus?.sessionID,
            parentSessionID: existingStatus?.parentSessionID,
            artifactKind: nil,
            artifactLabel: nil,
            artifactURL: nil
        )
    }

    private func logCodexDesktopNotificationIfNeeded(
        paneID: PaneID,
        worklane: WorklaneState,
        recognizedTool: AgentTool?,
        notificationText: String?,
        interactionKind: PaneAgentInteractionKind?
    ) {
        guard recognizedTool == .codex else {
            return
        }

        let isActivelyViewed = worklane.id == activeWorklaneID
            && worklane.paneStripState.focusedPaneID == paneID
        let shellActivity = worklane.auxiliaryStateByPaneID[paneID]?.agentStatus?.shellActivityState.rawValue ?? "unknown"
        let progressState = worklane.auxiliaryStateByPaneID[paneID]?.terminalProgress?.state
        let progressLabel = progressState.map(String.init(describing:)) ?? "none"
        let interactionLabel = interactionKind?.rawValue ?? "none"

        worklaneStoreLogger.debug(
            "Codex desktop notification pane=\(paneID.rawValue, privacy: .public) activelyViewed=\(isActivelyViewed, privacy: .public) shellActivity=\(shellActivity, privacy: .public) progress=\(progressLabel, privacy: .public) interaction=\(interactionLabel, privacy: .public)"
        )

        guard
            interactionKind == .genericInput,
            let notificationText = AgentInteractionClassifier.trimmed(notificationText),
            !AgentInteractionClassifier.isGenericNeedsInputMessage(notificationText),
            !AgentInteractionClassifier.isGenericNeedsInputContent(notificationText),
            !loggedUnclassifiedCodexDesktopNotifications.contains(notificationText)
        else {
            return
        }

        loggedUnclassifiedCodexDesktopNotifications.insert(notificationText)
        worklaneStoreLogger.notice(
            "Unclassified Codex desktop notification text=\(notificationText, privacy: .public)"
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

    private func promoteCodexAgentStateFromUserInput(
        paneID: PaneID,
        now: Date,
        in worklane: inout WorklaneState
    ) {
        guard var auxiliaryState = worklane.auxiliaryStateByPaneID[paneID],
              auxiliaryState.agentStatus?.tool == .codex,
              auxiliaryState.agentStatus?.source == .explicit
        else {
            return
        }

        auxiliaryState.agentReducerState = Self.seededReducerState(
            auxiliaryState.agentReducerState,
            from: auxiliaryState.agentStatus
        )
        guard auxiliaryState.agentReducerState.promoteExplicitCodexSessionFromUserInput(now: now) else {
            return
        }

        auxiliaryState.agentStatus = Self.hydratedStatus(
            auxiliaryState.agentReducerState.reducedStatus(now: now),
            existingStatus: auxiliaryState.agentStatus
        )
        worklane.auxiliaryStateByPaneID[paneID] = auxiliaryState
    }

    private func promoteCodexRunningIfCurrentTitleIndicatesRunning(
        paneID: PaneID,
        in worklane: inout WorklaneState
    ) {
        guard var auxiliaryState = worklane.auxiliaryStateByPaneID[paneID],
              auxiliaryState.agentStatus?.tool == .codex,
              auxiliaryState.agentStatus?.source == .explicit,
              let signature = TerminalMetadataChangeClassifier.volatileAgentStatusTitleSignature(
                  auxiliaryState.metadata?.title,
                  recognizedTool: .codex
              ),
              signature.phase == .running else {
            return
        }

        let now = Date()
        auxiliaryState.agentReducerState = Self.seededReducerState(
            auxiliaryState.agentReducerState,
            from: auxiliaryState.agentStatus
        )
        let didPromoteStarting = auxiliaryState.agentReducerState.promoteExplicitStartingSessionToRunning(now: now)
        let didResumeBlocked = auxiliaryState.agentReducerState.resumeBlockedSessionFromActivity(now: now)
        guard didPromoteStarting || didResumeBlocked else {
            return
        }

        auxiliaryState.agentStatus = Self.hydratedStatus(
            auxiliaryState.agentReducerState.reducedStatus(now: now),
            existingStatus: auxiliaryState.agentStatus
        )
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
