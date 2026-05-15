import Darwin
import Foundation
import os

private let worklaneStoreLogger = Logger(subsystem: "be.zenjoy.zentty", category: "WorklaneStore")
private let stopSignalLogger = Logger(subsystem: "be.zenjoy.zentty", category: "StopSignals")
private let codexRestartLogger = Logger(subsystem: "be.zenjoy.zentty", category: "CodexRestart")
@MainActor private var loggedUnclassifiedCodexDesktopNotifications: Set<String> = []

extension WorklaneStore {
    private static let codexInputSubmitStabilizationWindow: TimeInterval = 0.35
    private static let codexInterruptSuppressionWindow: TimeInterval = PaneAgentReducerState.stopGraceWindow + 1

    func handleTerminalEvent(paneID: PaneID, event: TerminalEvent) {
        guard let worklaneIndex = worklanes.firstIndex(where: { worklane in
            worklane.paneStripState.panes.contains(where: { $0.id == paneID })
        }) else {
            return
        }

        var worklane = worklanes[worklaneIndex]
        let previousWorklane = worklane
        var suppressReadyAfterRecompute = false
        logCodexRestartTerminalEvent(
            stage: "terminalEvent.begin",
            paneID: paneID,
            event: event,
            auxiliaryState: worklane.auxiliaryStateByPaneID[paneID]
        )
        switch event {
        case .shellReady:
            clearTransientAgentStateForFreshShellIfNeeded(paneID: paneID, in: &worklane)
        case .progressReport(let report):
            let now = currentDateProvider()
            if report.state == .remove {
                worklane.auxiliaryStateByPaneID[paneID]?.terminalProgress = nil
            } else {
                let existingStatus = worklane.auxiliaryStateByPaneID[paneID]?.agentStatus
                let showsReadyStatus = worklane.auxiliaryStateByPaneID[paneID]?.raw.showsReadyStatus == true
                worklane.auxiliaryStateByPaneID[paneID, default: PaneAuxiliaryState()].terminalProgress = report
                if report.state.indicatesActivity {
                    clearCodexTitleIdleSuppression(for: paneID, in: &worklane)
                    if shouldClearReadyStatusForProgressReport(
                        existingStatus: existingStatus,
                        showsReadyStatus: showsReadyStatus
                    ) {
                        clearReadyStatusIfNeeded(for: paneID, in: &worklane)
                    }
                    promoteCodexAgentStateFromUserInput(
                        paneID: paneID,
                        allowNeedsInputResume: false,
                        allowIdleResume: !codexInterruptSuppressionIsActive(for: paneID, in: worklane, now: now),
                        now: now,
                        in: &worklane
                    )
                    resumeBlockedAgentStateIfWorkResumed(
                        paneID: paneID,
                        now: now,
                        in: &worklane
                    )
                    promoteCodexRunningIfCurrentTitleAndProgressIndicateRunning(
                        paneID: paneID,
                        now: now,
                        in: &worklane
                    )
                }
            }
        case .userSubmittedInput:
            let now = currentDateProvider()
            let allowCodexNeedsInputResume = shouldAllowCodexNeedsInputResumeFromUserSubmittedInput(
                paneID: paneID,
                now: now,
                in: worklane
            )
            worklane.auxiliaryStateByPaneID[paneID]?.raw.codexInterruptSuppressionUntil = nil
            clearCodexTitleIdleSuppression(for: paneID, in: &worklane)
            clearReadyStatusIfNeeded(for: paneID, in: &worklane)
            promoteCodexAgentStateFromUserInput(
                paneID: paneID,
                allowNeedsInputResume: allowCodexNeedsInputResume,
                allowIdleResume: !codexInterruptSuppressionIsActive(for: paneID, in: worklane, now: now),
                now: now,
                in: &worklane
            )
            resumeBlockedAgentStateFromUserInput(
                paneID: paneID,
                allowCodexNeedsInputResume: allowCodexNeedsInputResume,
                now: now,
                in: &worklane
            )
        case .userEditedInput:
            // Typing alone (a letter, backspace, etc.) is not the same as
            // submitting an answer. For TUI-native agents like pi the user
            // is just composing their reply inside the app's input widget;
            // flipping "Needs decision" → "Running" on the first keystroke
            // loses the attention signal before they've actually replied.
            // Keep the lightweight UI-cleanup bookkeeping but do NOT resume
            // blocked state until the user submits.
            let now = currentDateProvider()
            clearCodexTitleIdleSuppression(for: paneID, in: &worklane)
            clearReadyStatusIfNeeded(for: paneID, in: &worklane)
            promoteCodexAgentStateFromUserInput(
                paneID: paneID,
                allowNeedsInputResume: false,
                allowIdleResume: false,
                now: now,
                in: &worklane
            )
        case .userInterrupted:
            let now = currentDateProvider()
            clearReadyStatusIfNeeded(for: paneID, in: &worklane)
            var auxiliaryState = worklane.auxiliaryStateByPaneID[paneID, default: PaneAuxiliaryState()]
            auxiliaryState.terminalProgress = nil
            auxiliaryState.agentReducerState = Self.seededReducerState(
                auxiliaryState.agentReducerState,
                from: auxiliaryState.agentStatus
            )
            let didMarkKimiIdle = auxiliaryState.agentReducerState.markExplicitKimiSessionIdleFromUserInterrupt(
                now: now
            )
            let hadCodexStatus = auxiliaryState.agentStatus?.tool == .codex
            let didClearCodex = auxiliaryState.agentReducerState.clearCodexSessionsFromUserInterrupt(
                now: now
            )
            if hadCodexStatus || didClearCodex {
                auxiliaryState.raw.codexInterruptSuppressionUntil = now.addingTimeInterval(Self.codexInterruptSuppressionWindow)
                auxiliaryState.raw.lastDesktopNotificationText = nil
                auxiliaryState.raw.lastDesktopNotificationDate = nil
                auxiliaryState.raw.codexTranscriptContext = nil
                auxiliaryState.raw.codexCurrentRunHasObservedActivity = false
                auxiliaryState.raw.wantsReadyStatus = false
                auxiliaryState.raw.showsReadyStatus = false
                auxiliaryState.agentStatus = Self.hydratedStatus(
                    auxiliaryState.agentReducerState.reducedStatus(),
                    existingStatus: auxiliaryState.agentStatus,
                    payloadWorkingDirectory: nil
                )
                worklane.auxiliaryStateByPaneID[paneID] = auxiliaryState
                suppressReadyAfterRecompute = true
            } else if didMarkKimiIdle {
                auxiliaryState.agentStatus = Self.hydratedStatus(
                    auxiliaryState.agentReducerState.reducedStatus(),
                    existingStatus: auxiliaryState.agentStatus,
                    payloadWorkingDirectory: nil
                )
                worklane.auxiliaryStateByPaneID[paneID] = auxiliaryState
                suppressReadyAfterRecompute = true
            }
        case .commandFinished:
            worklane.auxiliaryStateByPaneID[paneID]?.terminalProgress = nil
            if clearStaleCodexStateAfterShellReturnIfNeeded(
                paneID: paneID,
                metadata: worklane.auxiliaryStateByPaneID[paneID]?.metadata,
                in: &worklane
            ) {
                codexRestartLogger.notice(
                    "terminalEvent.commandFinished clearedShellReturn pane=\(paneID.rawValue, privacy: .public)"
                )
                break
            }

            let preFinishStatus = worklane.auxiliaryStateByPaneID[paneID]?.agentStatus
            if preFinishStatus?.tool == .openCode,
               preFinishStatus?.state == .idle,
               var auxiliaryState = worklane.auxiliaryStateByPaneID[paneID] {
                auxiliaryState.agentReducerState = Self.seededReducerState(
                    auxiliaryState.agentReducerState,
                    from: auxiliaryState.agentStatus
                )
                auxiliaryState.agentReducerState.sweep(now: Date(), isProcessAlive: Self.isProcessAlive(pid:))
                auxiliaryState.agentStatus = Self.hydratedStatus(
                    auxiliaryState.agentReducerState.reducedStatus(),
                    existingStatus: auxiliaryState.agentStatus
                )
                if auxiliaryState.agentStatus == nil {
                    auxiliaryState.terminalProgress = nil
                }
                worklane.auxiliaryStateByPaneID[paneID] = auxiliaryState
            }

            let existingStatus = worklane.auxiliaryStateByPaneID[paneID]?.agentStatus
            if let trackedPID = existingStatus?.trackedPID,
               Self.isProcessAlive(pid: trackedPID) {
                break
            }
            if shouldPromoteIdleStatusToReadyOnCommandFinished(existingStatus) {
                requestReadyStatusIfNeeded(for: paneID, in: &worklane)
                break
            }
            if shouldClearWeakCodexStatusOnCommandFinished(existingStatus) {
                clearTransientCodexState(
                    paneID: paneID,
                    in: &worklane,
                    reason: "commandFinished.weakCodex"
                )
                break
            }
            if existingStatus?.state != .idle,
               existingStatus?.state != .needsInput,
               existingStatus?.state != .starting,
               existingStatus?.state != .unresolvedStop,
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
            let suppressCodexNotification = recognizedTool == .codex
                && codexInterruptSuppressionIsActive(for: paneID, in: worklane, now: currentDateProvider())

            if let notificationText, !suppressCodexNotification {
                var auxiliaryState = worklane.auxiliaryStateByPaneID[paneID, default: PaneAuxiliaryState()]
                auxiliaryState.raw.lastDesktopNotificationText = notificationText
                auxiliaryState.raw.lastDesktopNotificationDate = currentDateProvider()
                worklane.auxiliaryStateByPaneID[paneID] = auxiliaryState
                if completionNotificationIndicatesReady(notificationText, recognizedTool: recognizedTool) {
                    if recognizedTool != .codex || codexReadyPromotionAllowed(in: auxiliaryState) {
                        requestReadyStatusIfNeeded(for: paneID, in: &worklane)
                    } else {
                        stopSignalLogger.debug(
                            "desktop.ready skip=noCurrentRunEvidence pane=\(paneID.rawValue, privacy: .public)"
                        )
                    }
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
                interactionKind: suppressCodexNotification ? nil : payload?.interactionKind
            )

            if let payload, !suppressCodexNotification {
                var auxiliaryState = worklane.auxiliaryStateByPaneID[paneID, default: PaneAuxiliaryState()]
                if recognizedTool == .codex,
                   payload.state == .running || payload.state == .needsInput {
                    auxiliaryState.raw.codexCurrentRunHasObservedActivity = true
                }
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
        if suppressReadyAfterRecompute {
            clearReadyStatusIfNeeded(for: paneID, in: &worklane)
        }
        logCodexRestartTerminalEvent(
            stage: "terminalEvent.end",
            paneID: paneID,
            event: event,
            auxiliaryState: worklane.auxiliaryStateByPaneID[paneID]
        )
        worklanes[worklaneIndex] = worklane
        let impacts = auxiliaryInvalidation(for: paneID, previousWorklane: previousWorklane, nextWorklane: worklane)
        if !impacts.isEmpty {
            notify(.auxiliaryStateUpdated(worklane.id, paneID, impacts))
        }
    }

    func applyAgentStatusPayload(_ payload: AgentStatusPayload) {
        let ownsPayloadPane = worklanes.contains { worklane in
            worklane.paneStripState.panes.contains(where: { $0.id == payload.paneID })
        }
        if let payloadWindowID = payload.windowID, payloadWindowID != windowID, !ownsPayloadPane {
            return
        }

        stopSignalLogger.debug(
            "applyPayload pane=\(payload.paneID.rawValue, privacy: .public) kind=\(payload.signalKind.rawValue, privacy: .public) state=\(payload.state?.rawValue ?? "<nil>", privacy: .public) origin=\(payload.origin.rawValue, privacy: .public) tool=\(payload.toolName ?? "<nil>", privacy: .public) lifecycle=\(payload.lifecycleEvent?.rawValue ?? "<nil>", privacy: .public) interaction=\(payload.interactionKind?.rawValue ?? "<nil>", privacy: .public) shellActivity=\(payload.shellActivityState?.rawValue ?? "<nil>", privacy: .public) session=\(payload.sessionID ?? "<nil>", privacy: .public)"
        )

        if payload.origin == .explicitAPI,
           payload.state == .needsInput,
           AgentTool.resolve(named: payload.toolName) == .codex {
            worklaneStoreLogger.debug(
                "Codex blocked signal pane=\(payload.paneID.rawValue, privacy: .public) interaction=\(payload.interactionKind?.rawValue ?? "none", privacy: .public)"
            )
        }

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
        let forceReviewRefreshOnStart = agentStartRequiresReviewRefresh(
            payload: payload,
            previousWorklane: previousWorklane,
            nextWorklane: worklane
        )

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

        if payload.signalKind == .paneRootPID {
            guard let pidEvent = payload.pidEvent else {
                return
            }

            switch pidEvent {
            case .attach:
                guard let pid = payload.pid, pid > 0 else {
                    return
                }
                worklane.auxiliaryStateByPaneID[payload.paneID, default: PaneAuxiliaryState()].raw.paneRootPID = pid
            case .clear:
                worklane.auxiliaryStateByPaneID[payload.paneID]?.raw.paneRootPID = nil
            }

            worklanes[worklaneIndex] = worklane
            let impacts = auxiliaryInvalidation(for: payload.paneID, previousWorklane: previousWorklane, nextWorklane: worklane)
            if !impacts.isEmpty {
                notify(.auxiliaryStateUpdated(worklane.id, payload.paneID, impacts))
            }
            return
        }

        let existingStatus = worklane.auxiliaryStateByPaneID[payload.paneID]?.agentStatus
        let tool = AgentTool.resolve(named: payload.toolName)
            ?? existingStatus?.tool
            ?? AgentToolRecognizer.recognize(metadata: worklane.auxiliaryStateByPaneID[payload.paneID]?.metadata)
        logCodexRestartPayload(
            stage: "payload.begin",
            payload: payload,
            resolvedTool: tool,
            auxiliaryState: worklane.auxiliaryStateByPaneID[payload.paneID]
        )
        if shouldClearReadyStatusForSupersededTool(
            existingStatus: existingStatus,
            incomingTool: tool,
            payload: payload
        ) {
            clearReadyStatusIfNeeded(for: payload.paneID, in: &worklane)
        }
        if shouldClearCodexTitleIdleSuppression(
            existingStatus: existingStatus,
            incomingTool: tool,
            payload: payload
        ) {
            clearCodexTitleIdleSuppression(for: payload.paneID, in: &worklane)
        }
        var auxiliaryState = worklane.auxiliaryStateByPaneID[payload.paneID, default: PaneAuxiliaryState()]
        updateCodexTranscriptContext(payload: payload, tool: tool, auxiliaryState: &auxiliaryState)
        if shouldSuppressCodexTurnCompleteForCurrentNeedsInputTitle(
            payload: payload,
            tool: tool,
            auxiliaryState: auxiliaryState
        ) {
            logCodexRestartPayload(
                stage: "payload.skip.currentNeedsInputTitle",
                payload: payload,
                resolvedTool: tool,
                auxiliaryState: auxiliaryState
            )
            stopSignalLogger.debug(
                "codex.turnComplete skip=currentNeedsInputTitle pane=\(payload.paneID.rawValue, privacy: .public)"
            )
            return
        }
        if shouldSuppressCodexPayloadDuringInterrupt(payload: payload, tool: tool, auxiliaryState: auxiliaryState) {
            logCodexRestartPayload(
                stage: "payload.skip.interruptSuppression",
                payload: payload,
                resolvedTool: tool,
                auxiliaryState: auxiliaryState
            )
            auxiliaryState.agentReducerState.clearCodexSessionsFromUserInterrupt()
            if auxiliaryState.agentStatus?.tool == .codex {
                auxiliaryState.agentStatus = nil
            }
            auxiliaryState.terminalProgress = nil
            auxiliaryState.raw.wantsReadyStatus = false
            auxiliaryState.raw.showsReadyStatus = false
            worklane.auxiliaryStateByPaneID[payload.paneID] = auxiliaryState
            recomputePresentation(for: payload.paneID, in: &worklane)
            worklanes[worklaneIndex] = worklane
            let impacts = auxiliaryInvalidation(for: payload.paneID, previousWorklane: previousWorklane, nextWorklane: worklane)
            if !impacts.isEmpty {
                notify(.auxiliaryStateUpdated(worklane.id, payload.paneID, impacts))
            }
            return
        }
        if shouldClearCodexInterruptSuppression(payload: payload, tool: tool) {
            codexRestartLogger.notice(
                "payload.clearSuppression pane=\(payload.paneID.rawValue, privacy: .public) state=\(payload.state?.rawValue ?? "<nil>", privacy: .public) origin=\(payload.origin.rawValue, privacy: .public) lifecycle=\(payload.lifecycleEvent?.rawValue ?? "<nil>", privacy: .public)"
            )
            auxiliaryState.raw.codexInterruptSuppressionUntil = nil
        }
        auxiliaryState.agentReducerState = Self.seededReducerState(auxiliaryState.agentReducerState, from: existingStatus)

        switch payload.signalKind {
        case .lifecycle:
            guard payload.state != nil, let tool else {
                if forceReviewRefreshOnStart {
                    notify(.auxiliaryStateUpdated(worklane.id, payload.paneID, [.reviewRefresh]))
                }
                return
            }
            if tool == .codex,
               payload.state == .running || payload.state == .needsInput {
                auxiliaryState.raw.codexCurrentRunHasObservedActivity = true
            }
            auxiliaryState.agentReducerState.apply(
                AgentStatusPayload(
                    windowID: payload.windowID ?? windowID,
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
                    taskProgress: payload.taskProgress,
                    artifactKind: payload.artifactKind,
                    artifactLabel: payload.artifactLabel,
                    artifactURL: payload.artifactURL,
                    agentWorkingDirectory: payload.agentWorkingDirectory,
                    agentTranscriptPath: payload.agentTranscriptPath,
                    agentLaunchSnapshot: payload.agentLaunchSnapshot
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
                auxiliaryState.raw.lastRunCommand = Self.trimmedShellCommand(payload.shellCommand)
                auxiliaryState.raw.restoredRerunnableCommand = nil
                auxiliaryState.presentation.lastActivityTitle = nil
                if auxiliaryState.raw.restoredAgentRestoreDraft != nil {
                    if auxiliaryState.raw.restoredAgentAutoResumePending {
                        auxiliaryState.raw.restoredAgentAutoResumePending = false
                    } else {
                        auxiliaryState.raw.restoredAgentRestoreDraft = nil
                        auxiliaryState.raw.restoredAgentAutoResumePending = false
                    }
                } else {
                    auxiliaryState.raw.restoredAgentAutoResumePending = false
                }
            }

            if shouldClearAmpStatusForNonAgentCommand(existingStatus, payload: payload) {
                auxiliaryState.agentStatus = nil
                auxiliaryState.agentReducerState = PaneAgentReducerState()
                auxiliaryState.terminalProgress = nil
                auxiliaryState.raw.wantsReadyStatus = false
                auxiliaryState.raw.showsReadyStatus = false
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

            if var existingStatus {
                existingStatus.shellActivityState = shellActivityState
                existingStatus.updatedAt = Date()

                if shouldClearCodexStatusFromShellPrompt(existingStatus) {
                    switch shellActivityState {
                    case .commandRunning:
                        break
                    case .promptIdle:
                        auxiliaryState.terminalProgress = nil
                        auxiliaryState.agentStatus = nil
                        if existingStatus.tool == .codex {
                            auxiliaryState.raw.codexCurrentRunHasObservedActivity = false
                        }
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
                        windowID: payload.windowID ?? windowID,
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
                        agentWorkingDirectory: payload.agentWorkingDirectory,
                        agentTranscriptPath: payload.agentTranscriptPath,
                        agentLaunchSnapshot: payload.agentLaunchSnapshot
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
        case .paneRootPID:
            break
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
        let forceGitContextRefreshOnCompletion = agentCompletionRequiresGitContextRefresh(
            previousWorklane: previousWorklane,
            nextWorklane: worklane,
            paneID: payload.paneID
        )
        worklanes[worklaneIndex] = worklane
        logCodexRestartPayload(
            stage: "payload.end",
            payload: payload,
            resolvedTool: tool,
            auxiliaryState: worklanes[worklaneIndex].auxiliaryStateByPaneID[payload.paneID]
        )
        refreshLastFocusedLocalWorkingDirectoryIfNeeded(worklane: worklane, paneID: payload.paneID)
        var impacts = auxiliaryInvalidation(for: payload.paneID, previousWorklane: previousWorklane, nextWorklane: worklane)
        if forceReviewRefreshOnStart {
            impacts.insert(.reviewRefresh)
        }
        if !impacts.isEmpty {
            notify(.auxiliaryStateUpdated(worklane.id, payload.paneID, impacts))
        }
        if let auxiliaryState = worklanes[worklaneIndex].auxiliaryStateByPaneID[payload.paneID] {
            scheduleCodexQuestionEnrichmentIfPossible(
                worklaneID: worklane.id,
                paneID: payload.paneID,
                auxiliaryState: auxiliaryState
            )
        }
        if auxiliaryUpdateRequiresGitContextRefresh(for: payload.paneID, previousWorklane: previousWorklane, nextWorklane: worklane) {
            refreshGitContextIfNeeded(for: PaneReference(worklaneID: worklane.id, paneID: payload.paneID))
        } else if forceGitContextRefreshOnCompletion {
            refreshGitContextIfNeeded(
                for: PaneReference(worklaneID: worklane.id, paneID: payload.paneID),
                forceReload: true
            )
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

    private func agentStartRequiresReviewRefresh(
        payload: AgentStatusPayload,
        previousWorklane: WorklaneState,
        nextWorklane: WorklaneState
    ) -> Bool {
        guard payload.signalKind == .lifecycle,
              payload.state == .starting
        else {
            return false
        }

        return hasReviewLookupContext(previousWorklane.auxiliaryStateByPaneID[payload.paneID])
            || hasReviewLookupContext(nextWorklane.auxiliaryStateByPaneID[payload.paneID])
    }

    private func hasReviewLookupContext(_ auxiliaryState: PaneAuxiliaryState?) -> Bool {
        if auxiliaryState?.presentation.prLookupKey != nil {
            return true
        }

        guard let gitContext = auxiliaryState?.gitContext else {
            return false
        }

        return gitContext.repoRoot != nil && gitContext.lookupBranch != nil
    }

    private func logCodexRestartTerminalEvent(
        stage: String,
        paneID: PaneID,
        event: TerminalEvent,
        auxiliaryState: PaneAuxiliaryState?
    ) {
        guard shouldLogCodexRestartDiagnostics(auxiliaryState: auxiliaryState, event: event) else {
            return
        }

        codexRestartLogger.notice(
            "\(stage, privacy: .public) pane=\(paneID.rawValue, privacy: .public) event=\(Self.codexRestartEventDescription(event), privacy: .public) title=\(auxiliaryState?.metadata?.title ?? "<nil>", privacy: .public) process=\(auxiliaryState?.metadata?.processName ?? "<nil>", privacy: .public) status=\(Self.codexRestartStatusDescription(auxiliaryState?.agentStatus), privacy: .public) sessions=\(auxiliaryState?.agentReducerState.sessionsByID.count ?? -1, privacy: .public) suppression=\(Self.codexRestartSuppressionDescription(auxiliaryState?.raw), privacy: .public)"
        )
    }

    private func logCodexRestartPayload(
        stage: String,
        payload: AgentStatusPayload,
        resolvedTool: AgentTool?,
        auxiliaryState: PaneAuxiliaryState?
    ) {
        guard resolvedTool == .codex
            || auxiliaryState?.agentStatus?.tool == .codex
            || auxiliaryState?.raw.codexInterruptSuppressionUntil != nil else {
            return
        }

        codexRestartLogger.notice(
            "\(stage, privacy: .public) pane=\(payload.paneID.rawValue, privacy: .public) signal=\(payload.signalKind.rawValue, privacy: .public) state=\(payload.state?.rawValue ?? "<nil>", privacy: .public) shellActivity=\(payload.shellActivityState?.rawValue ?? "<nil>", privacy: .public) origin=\(payload.origin.rawValue, privacy: .public) lifecycle=\(payload.lifecycleEvent?.rawValue ?? "<nil>", privacy: .public) resolved=\(resolvedTool?.displayName ?? "<nil>", privacy: .public) session=\(payload.sessionID ?? "<nil>", privacy: .public) pid=\(payload.pid.map(String.init) ?? "<nil>", privacy: .public) pidEvent=\(payload.pidEvent.map { String(describing: $0) } ?? "<nil>", privacy: .public) transcript=\(payload.agentTranscriptPath ?? "<nil>", privacy: .public) title=\(auxiliaryState?.metadata?.title ?? "<nil>", privacy: .public) process=\(auxiliaryState?.metadata?.processName ?? "<nil>", privacy: .public) status=\(Self.codexRestartStatusDescription(auxiliaryState?.agentStatus), privacy: .public) sessions=\(auxiliaryState?.agentReducerState.sessionsByID.count ?? -1, privacy: .public) suppression=\(Self.codexRestartSuppressionDescription(auxiliaryState?.raw), privacy: .public)"
        )
    }

    private func shouldLogCodexRestartDiagnostics(
        auxiliaryState: PaneAuxiliaryState?,
        event: TerminalEvent
    ) -> Bool {
        if auxiliaryState?.agentStatus?.tool == .codex
            || auxiliaryState?.raw.codexInterruptSuppressionUntil != nil
            || AgentToolRecognizer.recognize(metadata: auxiliaryState?.metadata) == .codex {
            return true
        }

        switch event {
        case .userInterrupted, .commandFinished, .userSubmittedInput, .progressReport:
            return true
        case .shellReady, .desktopNotification, .userEditedInput, .surfaceClosed:
            return false
        }
    }

    private static func codexRestartEventDescription(_ event: TerminalEvent) -> String {
        switch event {
        case .shellReady:
            return "shellReady"
        case .progressReport(let report):
            return "progressReport:\(report.state)"
        case .commandFinished(let exitCode, let durationNanoseconds):
            return "commandFinished:exit=\(exitCode.map(String.init) ?? "<nil>"):durationNs=\(durationNanoseconds)"
        case .desktopNotification(let notification):
            return "desktopNotification:title=\(notification.title ?? "<nil>"):body=\(notification.body ?? "<nil>")"
        case .userInterrupted:
            return "userInterrupted"
        case .userEditedInput:
            return "userEditedInput"
        case .userSubmittedInput:
            return "userSubmittedInput"
        case .surfaceClosed:
            return "surfaceClosed"
        }
    }

    private func agentCompletionRequiresGitContextRefresh(
        previousWorklane: WorklaneState,
        nextWorklane: WorklaneState,
        paneID: PaneID
    ) -> Bool {
        let previousAuxiliaryState = previousWorklane.auxiliaryStateByPaneID[paneID]
        let nextAuxiliaryState = nextWorklane.auxiliaryStateByPaneID[paneID]

        guard previousAuxiliaryState?.presentation.isWorking == true,
              nextAuxiliaryState?.presentation.runtimePhase == .idle
        else {
            return false
        }

        return localReviewWorkingDirectory(for: paneID, in: nextWorklane) != nil
    }

    private func clearTransientAgentStateForFreshShellIfNeeded(
        paneID: PaneID,
        in worklane: inout WorklaneState
    ) {
        guard var auxiliaryState = worklane.auxiliaryStateByPaneID[paneID] else {
            return
        }

        if let trackedPID = auxiliaryState.agentStatus?.trackedPID,
           Self.isProcessAlive(pid: trackedPID) {
            return
        }

        guard auxiliaryState.agentStatus != nil
            || !auxiliaryState.agentReducerState.sessionsByID.isEmpty
            || auxiliaryState.terminalProgress != nil
            || auxiliaryState.raw.wantsReadyStatus
            || auxiliaryState.raw.showsReadyStatus
            || auxiliaryState.raw.codexCurrentRunHasObservedActivity
            || auxiliaryState.raw.lastDesktopNotificationText != nil
            || auxiliaryState.raw.codexTranscriptContext != nil
        else {
            return
        }

        auxiliaryState.agentStatus = nil
        auxiliaryState.agentReducerState = PaneAgentReducerState()
        auxiliaryState.terminalProgress = nil
        auxiliaryState.raw.wantsReadyStatus = false
        auxiliaryState.raw.showsReadyStatus = false
        auxiliaryState.raw.codexCurrentRunHasObservedActivity = false
        auxiliaryState.raw.codexTitleIdleSuppressionUntil = nil
        auxiliaryState.raw.codexInterruptSuppressionUntil = nil
        auxiliaryState.raw.codexTranscriptContext = nil
        auxiliaryState.raw.lastDesktopNotificationText = nil
        auxiliaryState.raw.lastDesktopNotificationDate = nil
        worklane.auxiliaryStateByPaneID[paneID] = auxiliaryState
    }

    private func shouldClearWeakCodexStatusOnCommandFinished(_ status: PaneAgentStatus?) -> Bool {
        guard let status,
              status.tool == .codex,
              status.state != .idle,
              status.state != .needsInput,
              status.state != .starting else {
            return false
        }

        return status.origin == .shell || status.source == .inferred
    }

    private func shouldClearCodexStatusFromShellPrompt(_ status: PaneAgentStatus) -> Bool {
        status.tool == .codex && (status.origin == .shell || status.source == .inferred)
    }

    private func clearTransientCodexState(
        paneID: PaneID,
        in worklane: inout WorklaneState,
        reason: String
    ) {
        guard var auxiliaryState = worklane.auxiliaryStateByPaneID[paneID] else {
            return
        }

        codexRestartLogger.notice(
            "\(reason, privacy: .public) clear pane=\(paneID.rawValue, privacy: .public) status=\(Self.codexRestartStatusDescription(auxiliaryState.agentStatus), privacy: .public) sessions=\(auxiliaryState.agentReducerState.sessionsByID.count, privacy: .public)"
        )
        _ = auxiliaryState.agentReducerState.clearCodexSessionsFromUserInterrupt()
        if auxiliaryState.agentStatus?.tool == .codex {
            auxiliaryState.agentStatus = nil
        }
        auxiliaryState.terminalProgress = nil
        auxiliaryState.raw.wantsReadyStatus = false
        auxiliaryState.raw.showsReadyStatus = false
        auxiliaryState.raw.codexCurrentRunHasObservedActivity = false
        auxiliaryState.raw.codexTitleIdleSuppressionUntil = nil
        auxiliaryState.raw.codexInterruptSuppressionUntil = nil
        auxiliaryState.raw.codexTranscriptContext = nil
        auxiliaryState.raw.lastDesktopNotificationText = nil
        auxiliaryState.raw.lastDesktopNotificationDate = nil
        worklane.auxiliaryStateByPaneID[paneID] = auxiliaryState
    }

    private func reconcileReadyStatus(
        existingStatus: PaneAgentStatus?,
        payload: AgentStatusPayload,
        paneID: PaneID,
        in worklane: inout WorklaneState
    ) {
        let nextStatus = worklane.auxiliaryStateByPaneID[paneID]?.agentStatus

        if shouldEnterReadyStatus(from: existingStatus, to: nextStatus) {
            stopSignalLogger.debug(
                "reconcile.enter pane=\(paneID.rawValue, privacy: .public) prev=\(existingStatus?.state.rawValue ?? "<nil>", privacy: .public) next=\(nextStatus?.state.rawValue ?? "<nil>", privacy: .public) => requestReady"
            )
            requestReadyStatusIfNeeded(for: paneID, in: &worklane)
            return
        }

        // Note: we deliberately do NOT re-promote to ready when an
        // explicit-API idle lifecycle payload lands on an already-idle
        // session. The Codex title-interrupt suppression path intentionally
        // leaves the session in `Idle` (no ready label) because title +
        // notify are not reliable enough to tell a natural completion apart
        // from an interrupt, and the user-visible cost of a false "Agent
        // ready" after Esc is worse than a false "Idle" after completion.

        if shouldClearReadyStatus(for: nextStatus, payload: payload) {
            stopSignalLogger.debug(
                "reconcile.clear pane=\(paneID.rawValue, privacy: .public) next=\(nextStatus?.state.rawValue ?? "<nil>", privacy: .public) payloadState=\(payload.state?.rawValue ?? "<nil>", privacy: .public)"
            )
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
              existingStatus.state != .idle,
              existingStatus.origin != .shell,
              nextStatus.origin != .shell,
              existingStatus.source == .explicit,
              nextStatus.source == .explicit else {
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

    private func shouldPromoteIdleStatusToReadyOnCommandFinished(_ status: PaneAgentStatus?) -> Bool {
        guard let status,
              status.tool == .amp,
              status.state == .idle,
              status.hasObservedRunning,
              status.origin != .shell,
              status.source == .explicit else {
            return false
        }

        return true
    }

    private func shouldClearAmpStatusForNonAgentCommand(
        _ status: PaneAgentStatus?,
        payload: AgentStatusPayload
    ) -> Bool {
        guard payload.signalKind == .shellState,
              payload.shellActivityState == .commandRunning,
              let status,
              status.tool == .amp,
              status.source == .explicit,
              status.origin != .shell,
              status.state == .idle || status.state == .unresolvedStop else {
            return false
        }

        if AgentTool.resolveKnown(named: payload.toolName) == .amp {
            return false
        }
        if AgentTool.resolveKnown(named: payload.shellCommand) == .amp {
            return false
        }
        return true
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

    private func shouldClearReadyStatusForSupersededTool(
        existingStatus: PaneAgentStatus?,
        incomingTool: AgentTool?,
        payload: AgentStatusPayload
    ) -> Bool {
        guard let existingTool = existingStatus?.tool,
              let incomingTool,
              existingTool != incomingTool else {
            return false
        }

        switch payload.signalKind {
        case .lifecycle:
            guard let state = payload.state else {
                return false
            }
            return state == .starting || state == .running || state == .needsInput
        case .pid:
            return payload.pidEvent == .attach
        case .shellState, .paneRootPID, .paneContext:
            return false
        }
    }

    private func shouldClearCodexTitleIdleSuppression(
        existingStatus: PaneAgentStatus?,
        incomingTool: AgentTool?,
        payload: AgentStatusPayload
    ) -> Bool {
        let tool = incomingTool ?? existingStatus?.tool
        guard tool == .codex else {
            return false
        }

        switch payload.signalKind {
        case .lifecycle:
            return payload.state != nil
        case .pid:
            return payload.pidEvent == .attach
        case .shellState:
            return payload.shellActivityState == .commandRunning
        case .paneRootPID, .paneContext:
            return false
        }
    }

    private func clearCodexTitleIdleSuppression(
        for paneID: PaneID,
        in worklane: inout WorklaneState
    ) {
        worklane.auxiliaryStateByPaneID[paneID]?.raw.codexTitleIdleSuppressionUntil = nil
    }

    private func completionNotificationIndicatesReady(
        _ notificationText: String?,
        recognizedTool: AgentTool?
    ) -> Bool {
        guard let notificationText = AgentInteractionClassifier.trimmed(notificationText)?.lowercased() else {
            return false
        }

        if notificationText.contains("agent run complete")
            || notificationText.contains("agent ready")
            || notificationText.contains("agent turn complete") {
            return true
        }

        return recognizedTool == .gemini && notificationText.contains("session complete")
    }

    func invalidateCachedGitContext(path: String?) {
        guard let path = WorklaneContextFormatter.trimmed(path) else {
            return
        }

        cachedGitContextByPath.removeValue(forKey: path)
        knownNonRepositoryPaths.remove(path)
        nonRepositoryRetryDeadlineByPath.removeValue(forKey: path)
    }

    func clearStaleAgentSessions() {
        let now = currentDateProvider()
        for worklaneIndex in worklanes.indices {
            var worklane = worklanes[worklaneIndex]
            let previousWorklane = worklane
            var changedPaneIDs = Set<PaneID>()

            for (paneID, aux) in worklane.auxiliaryStateByPaneID {
                if !aux.agentReducerState.sessionsByID.isEmpty {
                    var reducerState = aux.agentReducerState
                    reducerState.sweep(now: now, isProcessAlive: Self.isProcessAlive(pid:))
                    var reducedStatus = Self.hydratedStatus(
                        reducerState.reducedStatus(now: now),
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
                        changedPaneIDs.insert(paneID)
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

                changedPaneIDs.insert(paneID)
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
            for paneID in changedPaneIDs {
                let impacts = auxiliaryInvalidation(
                    for: paneID,
                    previousWorklane: previousWorklane,
                    nextWorklane: worklane
                )
                if !impacts.isEmpty {
                    notify(.auxiliaryStateUpdated(worklane.id, paneID, impacts))
                }
            }
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
            agentLaunchSnapshot: existingStatus.agentLaunchSnapshot,
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
            taskProgress: existingStatus.taskProgress,
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
        status.agentLaunchSnapshot = status.agentLaunchSnapshot ?? existingStatus?.agentLaunchSnapshot
        return status
    }

    private func updateCodexTranscriptContext(
        payload: AgentStatusPayload,
        tool: AgentTool?,
        auxiliaryState: inout PaneAuxiliaryState
    ) {
        guard tool == .codex else {
            return
        }

        if let path = WorklaneContextFormatter.trimmed(payload.agentTranscriptPath) {
            auxiliaryState.raw.codexTranscriptContext = PaneCodexTranscriptContext(
                sessionID: WorklaneContextFormatter.trimmed(payload.sessionID)
                    ?? auxiliaryState.raw.codexTranscriptContext?.sessionID,
                path: path
            )
            return
        }

        if (payload.state == .starting || payload.state == .running),
           let sessionID = WorklaneContextFormatter.trimmed(payload.sessionID),
           auxiliaryState.raw.codexTranscriptContext?.sessionID != sessionID {
            auxiliaryState.raw.codexTranscriptContext = nil
            return
        }

        guard let sessionID = WorklaneContextFormatter.trimmed(payload.sessionID),
              var context = auxiliaryState.raw.codexTranscriptContext else {
            return
        }
        context.sessionID = sessionID
        auxiliaryState.raw.codexTranscriptContext = context
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
            windowID: windowID,
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

    private func resumeBlockedAgentStateFromUserInput(
        paneID: PaneID,
        allowCodexNeedsInputResume: Bool,
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
        guard auxiliaryState.agentReducerState.resumeBlockedSessionFromUserInput(
            allowCodexNeedsInputResume: allowCodexNeedsInputResume,
            now: now
        ) else {
            return
        }

        auxiliaryState.agentStatus = auxiliaryState.agentReducerState.reducedStatus(now: now)
        worklane.auxiliaryStateByPaneID[paneID] = auxiliaryState
    }

    private func promoteCodexAgentStateFromUserInput(
        paneID: PaneID,
        allowNeedsInputResume: Bool,
        allowIdleResume: Bool,
        now: Date,
        in worklane: inout WorklaneState
    ) {
        guard var auxiliaryState = worklane.auxiliaryStateByPaneID[paneID],
              auxiliaryState.agentStatus?.tool == .codex,
              auxiliaryState.agentStatus?.source == .explicit
        else {
            return
        }

        let priorState = auxiliaryState.agentStatus?.state
        auxiliaryState.agentReducerState = Self.seededReducerState(
            auxiliaryState.agentReducerState,
            from: auxiliaryState.agentStatus
        )
        guard auxiliaryState.agentReducerState.promoteExplicitCodexSessionFromUserInput(
            allowNeedsInputResume: allowNeedsInputResume,
            allowIdleResume: allowIdleResume,
            now: now
        ) else {
            return
        }

        worklaneStoreLogger.notice(
            "promoteCodexAgentStateFromUserInput priorState=\(priorState.map(String.init(describing:)) ?? "nil", privacy: .public) pane=\(paneID.rawValue, privacy: .public)"
        )

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
              !auxiliaryState.raw.codexInterruptSuppressionIsActive(),
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
        let preState = auxiliaryState.agentStatus?.state.rawValue ?? "<nil>"
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
        stopSignalLogger.debug(
            "codex.applyPayload.repromote pane=\(paneID.rawValue, privacy: .public) preState=\(preState, privacy: .public) didPromoteStarting=\(didPromoteStarting, privacy: .public) didResumeBlocked=\(didResumeBlocked, privacy: .public) => running"
        )
    }

    private func promoteCodexRunningIfCurrentTitleAndProgressIndicateRunning(
        paneID: PaneID,
        now: Date,
        in worklane: inout WorklaneState
    ) {
        guard var auxiliaryState = worklane.auxiliaryStateByPaneID[paneID],
              auxiliaryState.terminalProgress?.state.indicatesActivity == true,
              !auxiliaryState.raw.codexInterruptSuppressionIsActive(now: now),
              let existingStatus = auxiliaryState.agentStatus,
              existingStatus.tool == .codex,
              existingStatus.state == .needsInput,
              existingStatus.interactionKind.requiresHumanAttention,
              let signature = TerminalMetadataChangeClassifier.volatileAgentStatusTitleSignature(
                  auxiliaryState.metadata?.title,
                  recognizedTool: .codex
              ),
              signature.phase == .running else {
            return
        }

        let newStatus = Self.codexRunningStatus(from: existingStatus, now: now)
        auxiliaryState.agentStatus = newStatus
        auxiliaryState.agentReducerState = Self.seededReducerState(
            PaneAgentReducerState(),
            from: newStatus
        )
        worklane.auxiliaryStateByPaneID[paneID] = auxiliaryState
        stopSignalLogger.debug(
            "codex.progress.running force pane=\(paneID.rawValue, privacy: .public) preState=needsInput => running"
        )
    }

    private func shouldAllowCodexNeedsInputResumeFromUserSubmittedInput(
        paneID: PaneID,
        now: Date,
        in worklane: WorklaneState
    ) -> Bool {
        guard let status = worklane.auxiliaryStateByPaneID[paneID]?.agentStatus,
              status.tool == .codex,
              status.state == .needsInput || status.interactionKind.requiresHumanAttention else {
            return true
        }

        return now.timeIntervalSince(status.updatedAt) >= Self.codexInputSubmitStabilizationWindow
    }

    private func codexInterruptSuppressionIsActive(
        for paneID: PaneID,
        in worklane: WorklaneState,
        now: Date = Date()
    ) -> Bool {
        worklane.auxiliaryStateByPaneID[paneID]?.raw.codexInterruptSuppressionIsActive(now: now) == true
    }

    private func shouldSuppressCodexPayloadDuringInterrupt(
        payload: AgentStatusPayload,
        tool: AgentTool?,
        auxiliaryState: PaneAuxiliaryState
    ) -> Bool {
        guard tool == .codex,
              auxiliaryState.raw.codexInterruptSuppressionIsActive() else {
            return false
        }

        switch payload.signalKind {
        case .lifecycle:
            return payload.state == .idle || payload.clearsStatus
        case .pid, .paneRootPID, .shellState, .paneContext:
            return false
        }
    }

    private func shouldSuppressCodexTurnCompleteForCurrentNeedsInputTitle(
        payload: AgentStatusPayload,
        tool: AgentTool?,
        auxiliaryState: PaneAuxiliaryState
    ) -> Bool {
        guard tool == .codex,
              payload.lifecycleEvent == .turnComplete else {
            return false
        }

        return Self.codexCurrentTitleIndicatesNeedsInput(auxiliaryState)
    }

    static func codexRunningStatus(from existingStatus: PaneAgentStatus, now: Date) -> PaneAgentStatus {
        PaneAgentStatus(
            tool: .codex,
            state: .running,
            text: nil,
            artifactLink: existingStatus.artifactLink,
            updatedAt: now,
            source: existingStatus.source,
            origin: existingStatus.origin,
            interactionKind: .none,
            confidence: existingStatus.confidence,
            shellActivityState: existingStatus.shellActivityState,
            trackedPID: existingStatus.trackedPID,
            workingDirectory: existingStatus.workingDirectory,
            hasObservedRunning: true,
            sessionID: existingStatus.sessionID,
            parentSessionID: existingStatus.parentSessionID,
            taskProgress: existingStatus.taskProgress
        )
    }

    static func codexCurrentTitleIndicatesNeedsInput(_ auxiliaryState: PaneAuxiliaryState) -> Bool {
        guard let title = auxiliaryState.metadata?.title else {
            return false
        }

        if TerminalMetadataChangeClassifier.codexTitleInteractionKind(for: title) != nil {
            return true
        }

        return TerminalMetadataChangeClassifier.volatileAgentStatusTitleSignature(
            title,
            recognizedTool: .codex
        )?.phase == .needsInput
    }

    private func shouldClearCodexInterruptSuppression(
        payload: AgentStatusPayload,
        tool: AgentTool?
    ) -> Bool {
        guard tool == .codex else {
            return false
        }

        switch payload.signalKind {
        case .pid:
            return payload.pidEvent == .attach
        case .lifecycle:
            guard let state = payload.state else {
                return false
            }
            return state == .starting || state == .running || state == .needsInput
        case .shellState, .paneRootPID, .paneContext:
            return false
        }
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

    private static func trimmedShellCommand(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
