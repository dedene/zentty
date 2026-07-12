import Foundation
import os

private let stopSignalLogger = Logger(subsystem: "be.zenjoy.zentty", category: "StopSignals")

struct PaneAgentSessionState: Equatable, Sendable {
    var sessionID: String
    var parentSessionID: String?
    var agentLaunchSnapshot: AgentLaunchSnapshot? = nil
    var tool: AgentTool
    var state: PaneAgentState
    var text: String?
    var artifactLink: WorklaneArtifactLink?
    var updatedAt: Date
    var source: PaneAgentStatusSource
    var origin: AgentSignalOrigin
    var interactionKind: PaneAgentInteractionKind
    var confidence: AgentSignalConfidence
    var shellActivityState: PaneShellActivityState
    var trackedPID: Int32?
    var hasObservedRunning: Bool
    var taskProgress: PaneAgentTaskProgress? = nil
    var completionCandidateDeadline: Date?
    var idleVisibleUntil: Date?
    var unresolvedStopVisibleUntil: Date?
    var transientTextVisibleUntil: Date?
    /// Timestamp of the most recent explicit Stop-style transition into
    /// `.idle`. Used by `shouldApplyLifecycle` to ignore weaker `.needsInput`
    /// signals that arrive moments after Stop — e.g., a generic Claude
    /// `Notification("Claude is waiting for your input")` racing the Stop hook
    /// over the IPC bus.
    var explicitIdleSince: Date?
}

struct PaneAgentReducerState: Equatable, Sendable {
    static let stopGraceWindow: TimeInterval = 2
    static let ephemeralStartExitWindow: TimeInterval = 1
    static let idleVisibilityWindow: TimeInterval = 120
    static let unresolvedStopVisibilityWindow: TimeInterval = 600
    static let staleSessionVisibilityWindow: TimeInterval = 1_800
    // Fallback only: explicit compact-end events should clear this immediately.
    static let transientRunningTextVisibilityWindow: TimeInterval = 120
    static let compactingStatusText = "Compacting"
    /// How long after an explicit Stop we ignore non-explicit `.needsInput`
    /// payloads. Real follow-up interactions (PermissionRequest,
    /// AskUserQuestion) come through with `.explicit` confidence and bypass
    /// this guard.
    static let postStopNeedsInputGraceWindow: TimeInterval = 5

    var sessionsByID: [String: PaneAgentSessionState] = [:]

    mutating func apply(_ payload: AgentStatusPayload, now: Date = Date()) {
        switch payload.signalKind {
        case .lifecycle:
            applyLifecycle(payload, now: now)
        case .pid:
            applyPID(payload, now: now)
        case .shellState:
            applyShellState(payload, now: now)
        case .paneRootPID:
            break
        case .paneContext:
            break
        }
    }

    mutating func sweep(
        now: Date = Date(),
        isProcessAlive: (Int32) -> Bool
    ) {
        for sessionID in sessionsByID.keys {
            guard var session = sessionsByID[sessionID] else {
                continue
            }

            if let trackedPID = session.trackedPID, !isProcessAlive(trackedPID) {
                session.trackedPID = nil

                // PID is dead while state is already .idle: nothing more
                // can happen in this pane, so drop the session instead of
                // waiting out `idleVisibilityWindow`. Resume capability is
                // held by SessionRestoreStore, not the sidebar badge.
                if session.state == .idle {
                    sessionsByID.removeValue(forKey: sessionID)
                    continue
                }

                let shouldSilenceEphemeralStart = session.state == .starting
                    && !session.interactionKind.requiresHumanAttention
                    && session.completionCandidateDeadline == nil
                    && now.timeIntervalSince(session.updatedAt) <= Self.ephemeralStartExitWindow

                if shouldSilenceEphemeralStart {
                    sessionsByID.removeValue(forKey: sessionID)
                    continue
                }

                if session.state == .starting || session.state == .running || session.interactionKind.requiresHumanAttention || session.completionCandidateDeadline != nil {
                    session.state = .unresolvedStop
                    session.interactionKind = .none
                    session.text = nil
                    session.completionCandidateDeadline = nil
                    session.idleVisibleUntil = nil
                    session.unresolvedStopVisibleUntil = now.addingTimeInterval(Self.unresolvedStopVisibilityWindow)
                    session.updatedAt = now
                }
            }

            if let deadline = session.completionCandidateDeadline, now >= deadline {
                if !session.hasObservedRunning {
                    sessionsByID.removeValue(forKey: sessionID)
                    continue
                }
                stopSignalLogger.debug(
                    "reducer.sweep graceExpired session=\(sessionID, privacy: .public) tool=\(session.tool.displayName, privacy: .public) => idle"
                )
                session.state = .idle
                session.interactionKind = .none
                session.text = nil
                session.trackedPID = nil
                session.completionCandidateDeadline = nil
                session.idleVisibleUntil = now.addingTimeInterval(Self.idleVisibilityWindow)
                session.unresolvedStopVisibleUntil = nil
                session.updatedAt = now
            }

            let shouldExpireIdle = session.state == .idle
                && session.trackedPID == nil
                && (session.idleVisibleUntil.map { now >= $0 } ?? false)
            let shouldExpireUnresolvedStop = session.state == .unresolvedStop
                && (session.unresolvedStopVisibleUntil.map { now >= $0 } ?? false)
                && session.trackedPID == nil
            let shouldExpireInactive = session.trackedPID == nil
                && !session.interactionKind.requiresHumanAttention
                && now.timeIntervalSince(session.updatedAt) >= Self.staleSessionVisibilityWindow

            if shouldExpireIdle || shouldExpireUnresolvedStop || shouldExpireInactive {
                sessionsByID.removeValue(forKey: sessionID)
            } else {
                sessionsByID[sessionID] = session
            }
        }
    }

    mutating func markUnresolvedStop(
        sessionID: String?,
        now: Date = Date()
    ) {
        if let sessionID = normalized(sessionID), var session = sessionsByID[sessionID] {
            session.state = .unresolvedStop
            session.text = nil
            session.interactionKind = .none
            session.trackedPID = nil
            session.completionCandidateDeadline = nil
            session.idleVisibleUntil = nil
            session.unresolvedStopVisibleUntil = now.addingTimeInterval(Self.unresolvedStopVisibilityWindow)
            session.updatedAt = now
            sessionsByID[sessionID] = session
            return
        }

        for key in sessionsByID.keys {
            guard var session = sessionsByID[key] else {
                continue
            }
            guard session.state == .running || session.state == .starting else {
                continue
            }
            session.state = .unresolvedStop
            session.text = nil
            session.interactionKind = .none
            session.trackedPID = nil
            session.completionCandidateDeadline = nil
            session.idleVisibleUntil = nil
            session.unresolvedStopVisibleUntil = now.addingTimeInterval(Self.unresolvedStopVisibilityWindow)
            session.updatedAt = now
            sessionsByID[key] = session
        }
    }

    @discardableResult
    mutating func resumeBlockedSessionFromActivity(now: Date = Date()) -> Bool {
        let blockedSessions = sessionsByID.values.filter { session in
            if session.tool == .codex,
               session.state == .needsInput || session.interactionKind.requiresHumanAttention {
                return false
            }
            if session.tool == .grok,
               session.state == .needsInput || session.interactionKind.requiresHumanAttention {
                return false
            }
            // Kimi keeps emitting shell/progress activity while its inline
            // approval panel is visible. Treating that passive activity as a
            // resume signal clears "Requires approval" before the user has
            // actually confirmed anything.
            if session.tool == .kimi, session.interactionKind == .approval {
                return false
            }

            return session.state == .needsInput || session.interactionKind.requiresHumanAttention
        }
        guard let sessionID = blockedSessions.sorted(by: Self.preferred(lhs:rhs:)).first?.sessionID,
              var session = sessionsByID[sessionID]
        else {
            return false
        }

        session.state = .running
        session.text = nil
        session.interactionKind = .none
        session.completionCandidateDeadline = nil
        session.idleVisibleUntil = nil
        session.unresolvedStopVisibleUntil = nil
        session.hasObservedRunning = true
        session.updatedAt = now
        sessionsByID[sessionID] = session
        return true
    }

    @discardableResult
    mutating func resumeBlockedSessionFromUserInput(
        allowCodexNeedsInputResume: Bool = true,
        now: Date = Date()
    ) -> Bool {
        let blockedSessions = sessionsByID.values.filter { session in
            if session.tool == .codex,
               !allowCodexNeedsInputResume,
               session.state == .needsInput || session.interactionKind.requiresHumanAttention {
                return false
            }
            return session.state == .needsInput || session.interactionKind.requiresHumanAttention
        }
        guard let sessionID = blockedSessions.sorted(by: Self.preferred(lhs:rhs:)).first?.sessionID,
              var session = sessionsByID[sessionID]
        else {
            return false
        }

        session.state = .running
        session.text = nil
        session.interactionKind = .none
        session.completionCandidateDeadline = nil
        session.idleVisibleUntil = nil
        session.unresolvedStopVisibleUntil = nil
        session.hasObservedRunning = true
        session.updatedAt = now
        sessionsByID[sessionID] = session
        return true
    }

    /// Mistral Vibe exposes no turn-start / prompt-submit hook, so a user
    /// submit (Enter, not a newline) is Zentty's only signal that a new turn
    /// began. Promote the explicit Vibe session to running from idle /
    /// needs-input / starting. Unlike Codex this does NOT require
    /// `hasObservedRunning`: a text-only first turn never observes a
    /// tool-driven running state, yet should still read as running while Vibe
    /// generates. The `post_agent_turn` hook flips it back to idle at turn end.
    @discardableResult
    mutating func promoteExplicitVibeSessionFromUserInput(now: Date = Date()) -> Bool {
        let candidateSessions = sessionsByID.values.filter { session in
            session.tool == .vibe
                && session.source == .explicit
                && session.origin != .shell
                && (
                    session.state == .idle
                        || session.state == .needsInput
                        || session.state == .starting
                )
        }
        guard let sessionID = candidateSessions.sorted(by: Self.preferred(lhs:rhs:)).first?.sessionID,
              var session = sessionsByID[sessionID]
        else {
            return false
        }

        session.state = .running
        session.text = nil
        session.interactionKind = .none
        session.completionCandidateDeadline = nil
        session.idleVisibleUntil = nil
        session.unresolvedStopVisibleUntil = nil
        session.hasObservedRunning = true
        session.updatedAt = now
        sessionsByID[sessionID] = session
        return true
    }

    @discardableResult
    mutating func markExplicitClaudeCodeSessionIdleFromIdleTitle(now: Date = Date()) -> Bool {
        let candidateSessions = sessionsByID.values.filter { session in
            session.tool == .claudeCode
                && session.source == .explicit
                && session.origin != .shell
                && session.hasObservedRunning
                && (
                    session.state == .running
                        || session.state == .starting
                        || session.completionCandidateDeadline != nil
                )
        }
        guard let sessionID = candidateSessions.sorted(by: Self.preferred(lhs:rhs:)).first?.sessionID,
              var session = sessionsByID[sessionID]
        else {
            return false
        }

        session.state = .running
        session.text = nil
        session.interactionKind = .none
        session.completionCandidateDeadline = now.addingTimeInterval(Self.stopGraceWindow)
        session.idleVisibleUntil = nil
        session.unresolvedStopVisibleUntil = nil
        session.hasObservedRunning = true
        session.updatedAt = now
        sessionsByID[sessionID] = session
        return true
    }

    func reducedStatus(now: Date = Date()) -> PaneAgentStatus? {
        let sessions = sessionsByID.values.filter { session in
            if session.state == .idle,
               let idleVisibleUntil = session.idleVisibleUntil {
                return now <= idleVisibleUntil
            }

            if session.state == .unresolvedStop,
               let unresolvedStopVisibleUntil = session.unresolvedStopVisibleUntil {
                return now <= unresolvedStopVisibleUntil
            }

            return true
        }
        let activeSessions = sessions.filter { session in
            session.completionCandidateDeadline != nil
                || session.state == .starting
                || session.state == .running
                || session.state == .needsInput
                || session.interactionKind.requiresHumanAttention
        }
        let preferredSessions = activeSessions.isEmpty
            ? sessions
            : sessions.filter { $0.state != .unresolvedStop }

        guard let session = preferredSessions.sorted(by: Self.preferred(lhs:rhs:)).first else {
            return nil
        }

        return PaneAgentStatus(
            tool: session.tool,
            state: session.state,
            text: Self.visibleText(for: session, now: now),
            artifactLink: session.artifactLink,
            updatedAt: session.updatedAt,
            source: session.source,
            origin: session.origin,
            interactionKind: session.interactionKind,
            confidence: session.confidence,
            shellActivityState: session.shellActivityState,
            trackedPID: session.trackedPID,
            hasObservedRunning: session.hasObservedRunning,
            sessionID: session.sessionID,
            parentSessionID: session.parentSessionID,
            agentLaunchSnapshot: session.agentLaunchSnapshot,
            taskProgress: session.taskProgress
        )
    }

    private mutating func applyLifecycle(_ payload: AgentStatusPayload, now: Date) {
        if payload.clearsStatus {
            if let sessionID = normalized(payload.sessionID) {
                sessionsByID.removeValue(forKey: sessionID)
            } else {
                sessionsByID.removeAll()
            }
            return
        }

        guard let state = payload.state else {
            return
        }
        guard let tool = AgentTool.resolve(named: payload.toolName) ?? sessionsByID[normalized(payload.sessionID) ?? ""]?.tool else {
            return
        }

        let payloadSessionID = normalized(payload.sessionID)
        let sessionID = resolvedSessionID(for: payload, tool: tool)
        if tool == .codex,
           payload.origin == .explicitHook,
           (state == .starting || state == .running) {
            removeStaleCodexNeedsInputSessions(excluding: sessionID)
        }
        var session = sessionsByID[sessionID] ?? PaneAgentSessionState(
            sessionID: sessionID,
            parentSessionID: normalized(payload.parentSessionID),
            agentLaunchSnapshot: payload.agentLaunchSnapshot,
            tool: tool,
            state: .starting,
            text: nil,
            artifactLink: explicitArtifactLink(from: payload),
            updatedAt: now,
            source: statusSource(for: payload.origin),
            origin: payload.origin,
            interactionKind: .none,
            confidence: payload.confidence ?? defaultConfidence(for: payload.origin),
            shellActivityState: .unknown,
            trackedPID: nil,
            hasObservedRunning: false,
            taskProgress: payload.taskProgress,
            completionCandidateDeadline: nil,
            idleVisibleUntil: nil,
            unresolvedStopVisibleUntil: nil,
            transientTextVisibleUntil: nil,
            explicitIdleSince: nil
        )

        if payload.origin != .inferred {
            mergeInferredSessions(into: &session, for: tool, excluding: sessionID)
        }
        if payloadSessionID != nil {
            mergeFallbackSession(into: &session, for: tool, excluding: sessionID)
        }

        if !shouldApplyLifecycle(payload, over: session, now: now) {
            return
        }

        let interactionKind = payload.interactionKind ?? defaultInteractionKind(for: state)
        let payloadText = AgentInteractionClassifier.trimmed(payload.text)
        let existingText = AgentInteractionClassifier.trimmed(session.text)
        let previousState = session.state
        let previousInteractionKind = session.interactionKind
        let previousOrigin = session.origin

        session.parentSessionID = normalized(payload.parentSessionID) ?? session.parentSessionID
        session.agentLaunchSnapshot = payload.agentLaunchSnapshot ?? session.agentLaunchSnapshot
        session.tool = tool
        session.source = statusSource(for: payload.origin)
        session.origin = payload.origin
        session.confidence = payload.confidence ?? defaultConfidence(for: payload.origin)
        session.artifactLink = explicitArtifactLink(from: payload) ?? session.artifactLink
        session.updatedAt = now
        session.idleVisibleUntil = nil
        session.unresolvedStopVisibleUntil = nil
        session.taskProgress = payload.taskProgress ?? session.taskProgress

        if payload.lifecycleEvent == .stopCandidate {
            session.state = .running
            session.interactionKind = .none
            session.text = nil
            session.completionCandidateDeadline = now.addingTimeInterval(Self.stopGraceWindow)
            sessionsByID[sessionID] = session
            stopSignalLogger.debug(
                "reducer.lifecycle stopCandidate session=\(sessionID, privacy: .public) tool=\(tool.displayName, privacy: .public) prevState=\(previousState.rawValue, privacy: .public) => running+grace"
            )
            return
        }

        session.completionCandidateDeadline = nil
        if state == .running {
            session.hasObservedRunning = true
        }

        if state == .idle && !session.hasObservedRunning {
            sessionsByID.removeValue(forKey: sessionID)
            return
        }

        session.state = state
        session.interactionKind = state == .needsInput ? interactionKind : .none
        switch state {
        case .needsInput:
            if previousState == .needsInput {
                if payload.origin.priority > previousOrigin.priority
                    || interactionKind.priority > previousInteractionKind.priority {
                    session.text = payloadText ?? existingText
                } else {
                    session.text = AgentInteractionClassifier.preferredWaitingMessage(
                        existing: existingText,
                        candidate: payloadText
                    ) ?? payloadText ?? existingText
                }
            } else {
                session.text = payloadText ?? existingText
            }
            session.explicitIdleSince = nil
        case .idle:
            session.text = nil
            session.transientTextVisibleUntil = nil
            session.idleVisibleUntil = now.addingTimeInterval(Self.idleVisibilityWindow)
            // Stamp the moment we accepted an explicit Stop (or equivalent
            // .idle transition) so a late, lower-confidence `.needsInput`
            // can't flip the session right back. Re-stamping on each
            // explicit idle is fine — only the most recent matters.
            if payload.origin == .explicitHook || payload.origin == .explicitAPI {
                session.explicitIdleSince = now
            } else {
                session.explicitIdleSince = nil
            }
        case .unresolvedStop:
            session.text = nil
            session.transientTextVisibleUntil = nil
            session.trackedPID = nil
            session.unresolvedStopVisibleUntil = now.addingTimeInterval(Self.unresolvedStopVisibilityWindow)
            session.explicitIdleSince = nil
        case .running, .starting:
            if let payloadText {
                session.text = payloadText
                session.transientTextVisibleUntil = Self.transientTextVisibleUntil(for: payloadText, now: now)
            } else if Self.shouldPreserveTransientRunningText(
                existingText,
                previousState: previousState,
                existingVisibleUntil: session.transientTextVisibleUntil,
                lifecycleEvent: payload.lifecycleEvent,
                now: now
            ) {
                session.text = existingText
            } else {
                session.text = nil
                session.transientTextVisibleUntil = nil
            }
            session.explicitIdleSince = nil
        }

        sessionsByID[sessionID] = session
        stopSignalLogger.debug(
            "reducer.lifecycle applied session=\(sessionID, privacy: .public) tool=\(tool.displayName, privacy: .public) prev=\(previousState.rawValue, privacy: .public) => \(session.state.rawValue, privacy: .public) origin=\(payload.origin.rawValue, privacy: .public) interaction=\(session.interactionKind.rawValue, privacy: .public) hasObservedRunning=\(session.hasObservedRunning, privacy: .public)"
        )
    }

    private mutating func mergeInferredSessions(
        into session: inout PaneAgentSessionState,
        for tool: AgentTool,
        excluding sessionID: String
    ) {
        let inferredSessions = sessionsByID.values.filter { candidate in
            candidate.sessionID != sessionID
                && candidate.tool == tool
                && candidate.source == .inferred
        }
        guard !inferredSessions.isEmpty else {
            return
        }

        for inferredSession in inferredSessions {
            session.hasObservedRunning = session.hasObservedRunning || inferredSession.hasObservedRunning
            session.artifactLink = session.artifactLink ?? inferredSession.artifactLink
            session.text = session.text ?? inferredSession.text
            session.transientTextVisibleUntil = session.transientTextVisibleUntil ?? inferredSession.transientTextVisibleUntil
            session.taskProgress = session.taskProgress ?? inferredSession.taskProgress
            session.agentLaunchSnapshot = session.agentLaunchSnapshot ?? inferredSession.agentLaunchSnapshot
            if inferredSession.updatedAt > session.updatedAt {
                session.updatedAt = inferredSession.updatedAt
            }
            sessionsByID.removeValue(forKey: inferredSession.sessionID)
        }
    }

    private mutating func mergeFallbackSession(
        into session: inout PaneAgentSessionState,
        for tool: AgentTool,
        excluding sessionID: String
    ) {
        let fallbackSessionID = fallbackSessionID(for: tool)
        guard fallbackSessionID != sessionID,
              let fallbackSession = sessionsByID[fallbackSessionID],
              fallbackSession.tool == tool
        else {
            return
        }

        session.hasObservedRunning = session.hasObservedRunning || fallbackSession.hasObservedRunning
        session.artifactLink = session.artifactLink ?? fallbackSession.artifactLink
        session.text = session.text ?? fallbackSession.text
        session.transientTextVisibleUntil = session.transientTextVisibleUntil ?? fallbackSession.transientTextVisibleUntil
        session.trackedPID = session.trackedPID ?? fallbackSession.trackedPID
        session.taskProgress = session.taskProgress ?? fallbackSession.taskProgress
        session.agentLaunchSnapshot = session.agentLaunchSnapshot ?? fallbackSession.agentLaunchSnapshot
        if session.shellActivityState == .unknown {
            session.shellActivityState = fallbackSession.shellActivityState
        }
        sessionsByID.removeValue(forKey: fallbackSessionID)
    }

    private mutating func applyPID(_ payload: AgentStatusPayload, now: Date) {
        guard let pidEvent = payload.pidEvent else {
            return
        }

        switch pidEvent {
        case .attach:
            guard let tool = AgentTool.resolve(named: payload.toolName), let pid = payload.pid else {
                return
            }
            let sessionID = resolvedSessionID(for: payload, tool: tool)
            var session = sessionsByID[sessionID] ?? PaneAgentSessionState(
                sessionID: sessionID,
                parentSessionID: normalized(payload.parentSessionID),
                agentLaunchSnapshot: payload.agentLaunchSnapshot,
                tool: tool,
                state: .starting,
                text: nil,
                artifactLink: nil,
                updatedAt: now,
                source: .explicit,
                origin: payload.origin,
                interactionKind: .none,
                confidence: payload.confidence ?? defaultConfidence(for: payload.origin),
                shellActivityState: .unknown,
                trackedPID: nil,
                hasObservedRunning: false,
                taskProgress: payload.taskProgress,
                completionCandidateDeadline: nil,
                idleVisibleUntil: nil,
                unresolvedStopVisibleUntil: nil,
                transientTextVisibleUntil: nil,
                explicitIdleSince: nil
            )

            if session.state == .idle || session.state == .unresolvedStop {
                session.state = .starting
            }
            session.tool = tool
            session.origin = maxOrigin(session.origin, payload.origin)
            session.updatedAt = now
            session.trackedPID = pid
            session.parentSessionID = normalized(payload.parentSessionID) ?? session.parentSessionID
            session.agentLaunchSnapshot = payload.agentLaunchSnapshot ?? session.agentLaunchSnapshot
            sessionsByID[sessionID] = session
        case .clear:
            if let sessionID = normalized(payload.sessionID), var session = sessionsByID[sessionID] {
                session.trackedPID = nil
                session.updatedAt = now
                sessionsByID[sessionID] = session
            } else {
                for sessionID in sessionsByID.keys {
                    sessionsByID[sessionID]?.trackedPID = nil
                    sessionsByID[sessionID]?.updatedAt = now
                }
            }
        }
    }

    private mutating func applyShellState(_ payload: AgentStatusPayload, now: Date) {
        guard let shellActivityState = payload.shellActivityState else {
            return
        }

        for sessionID in sessionsByID.keys {
            sessionsByID[sessionID]?.shellActivityState = shellActivityState
            sessionsByID[sessionID]?.updatedAt = now
        }

        if shellActivityState == .commandRunning {
            _ = resumeBlockedSessionFromActivity(now: now)
        } else if shellActivityState == .promptIdle {
            _ = markRunningSessionIdleFromPromptReturn(now: now)
        }
    }

    @discardableResult
    mutating func promoteExplicitStartingSessionToRunning(now: Date = Date()) -> Bool {
        let candidateSessions = sessionsByID.values.filter { session in
            session.state == .starting
                && session.source == .explicit
                && session.origin != .shell
        }
        guard let sessionID = candidateSessions.sorted(by: Self.preferred(lhs:rhs:)).first?.sessionID,
              var session = sessionsByID[sessionID]
        else {
            return false
        }

        session.state = .running
        session.text = nil
        session.interactionKind = .none
        session.completionCandidateDeadline = nil
        session.idleVisibleUntil = nil
        session.unresolvedStopVisibleUntil = nil
        session.hasObservedRunning = true
        session.updatedAt = now
        sessionsByID[sessionID] = session
        return true
    }

    @discardableResult
    private mutating func markRunningSessionIdleFromPromptReturn(now: Date) -> Bool {
        let candidateSessions = sessionsByID.values.filter { session in
            session.state == .running
                && session.source == .explicit
                && session.origin != .shell
                && !session.interactionKind.requiresHumanAttention
                && session.hasObservedRunning
        }
        guard let sessionID = candidateSessions.sorted(by: Self.preferred(lhs:rhs:)).first?.sessionID,
              var session = sessionsByID[sessionID]
        else {
            return false
        }

        session.state = .idle
        session.text = nil
        session.interactionKind = .none
        session.completionCandidateDeadline = nil
        session.idleVisibleUntil = now.addingTimeInterval(Self.idleVisibilityWindow)
        session.unresolvedStopVisibleUntil = nil
        session.updatedAt = now
        sessionsByID[sessionID] = session
        return true
    }

    private func shouldApplyLifecycle(
        _ payload: AgentStatusPayload,
        over existingSession: PaneAgentSessionState,
        now: Date
    ) -> Bool {
        if payload.lifecycleEvent == .stopCandidate {
            return true
        }

        if existingSession.tool == .codex,
           existingSession.state == .needsInput,
           existingSession.interactionKind.requiresHumanAttention,
           payload.state == .idle || payload.state == .running || payload.state == .starting {
            if payload.origin == .explicitHook,
               payload.state == .starting {
                return true
            }
            return payload.lifecycleEvent == .toolActivity
                || payload.lifecycleEvent == .turnComplete
                || Self.codexNeedsInputIsWeakTerminalFallback(existingSession)
        }

        // Post-Stop grace: if the session was just explicitly stopped
        // (Claude Stop hook, Codex stop, etc.), reject `.needsInput`
        // payloads whose confidence isn't `.explicit`. Real follow-up
        // interactions (PermissionRequest, AskUserQuestion) carry
        // `.explicit` confidence and bypass this guard; weak/stale
        // notifications racing the Stop over the IPC bus do not.
        if existingSession.state == .idle,
           payload.state == .needsInput,
           let explicitIdleSince = existingSession.explicitIdleSince {
            let payloadConfidence = payload.confidence ?? defaultConfidence(for: payload.origin)
            if payloadConfidence != .explicit,
               now.timeIntervalSince(explicitIdleSince) <= Self.postStopNeedsInputGraceWindow {
                stopSignalLogger.debug(
                    "reducer.lifecycle suppressing late needs-input session=\(existingSession.sessionID, privacy: .public) tool=\(existingSession.tool.displayName, privacy: .public) confidence=\(payloadConfidence.rawValue, privacy: .public)"
                )
                return false
            }
        }

        if payload.origin.priority > existingSession.origin.priority {
            return true
        }

        if payload.origin.priority < existingSession.origin.priority {
            if payload.state == .needsInput,
               existingSession.state == .running || existingSession.state == .starting {
                return true
            }
            if payload.state == existingSession.state {
                let payloadInteraction = payload.interactionKind ?? defaultInteractionKind(for: payload.state ?? existingSession.state)
                return payloadInteraction.priority >= existingSession.interactionKind.priority
            }
            return false
        }

        if payload.state == .needsInput, existingSession.state == .needsInput {
            let payloadInteraction = payload.interactionKind ?? .genericInput
            if payloadInteraction.priority < existingSession.interactionKind.priority {
                return false
            }
        }

        return true
    }

    private static func visibleText(for session: PaneAgentSessionState, now: Date) -> String? {
        guard let text = session.text else {
            return nil
        }
        guard isTransientRunningText(text),
              session.state == .running || session.state == .starting else {
            return text
        }
        return session.transientTextVisibleUntil.map { now <= $0 } == true ? text : nil
    }

    private static func shouldPreserveTransientRunningText(
        _ existingText: String?,
        previousState: PaneAgentState,
        existingVisibleUntil: Date?,
        lifecycleEvent: AgentLifecycleEvent?,
        now: Date
    ) -> Bool {
        guard let existingText,
              isTransientRunningText(existingText),
              previousState == .running || previousState == .starting,
              lifecycleEvent == .toolActivity,
              let existingVisibleUntil else {
            return false
        }
        return now <= existingVisibleUntil
    }

    private static func isTransientRunningText(_ text: String) -> Bool {
        text == compactingStatusText
    }

    private static func transientTextVisibleUntil(for text: String, now: Date) -> Date? {
        isTransientRunningText(text) ? now.addingTimeInterval(transientRunningTextVisibilityWindow) : nil
    }

    static func preferred(lhs: PaneAgentSessionState, rhs: PaneAgentSessionState) -> Bool {
        if sessionPriority(lhs) != sessionPriority(rhs) {
            return sessionPriority(lhs) > sessionPriority(rhs)
        }

        if lhs.confidence.priority != rhs.confidence.priority {
            return lhs.confidence.priority > rhs.confidence.priority
        }

        if lhs.origin.priority != rhs.origin.priority {
            return lhs.origin.priority > rhs.origin.priority
        }

        // Root sessions preferred over child sessions — prevents subagents
        // from stealing the status slot while the parent is still active.
        let lhsIsRoot = lhs.parentSessionID == nil
        let rhsIsRoot = rhs.parentSessionID == nil
        if lhsIsRoot != rhsIsRoot {
            return lhsIsRoot
        }

        return lhs.updatedAt > rhs.updatedAt
    }

    private static func sessionPriority(_ session: PaneAgentSessionState) -> Int {
        if session.interactionKind.requiresHumanAttention || session.state == .needsInput {
            return 500 + session.interactionKind.priority
        }

        if session.completionCandidateDeadline != nil {
            return 225
        }

        switch session.state {
        case .unresolvedStop:
            return 400
        case .running:
            return 300
        case .starting:
            return 250
        case .idle:
            return 200
        case .needsInput:
            return 100
        }
    }

    private func resolvedSessionID(for payload: AgentStatusPayload, tool: AgentTool) -> String {
        if let sessionID = normalized(payload.sessionID) {
            return sessionID
        }

        if let sessionID = sessionsByID.values
            .filter({ $0.tool == tool && $0.sessionID != fallbackSessionID(for: tool) })
            .sorted(by: Self.preferred(lhs:rhs:))
            .first?
            .sessionID {
            return sessionID
        }

        return fallbackSessionID(for: tool)
    }

    private func fallbackSessionID(for tool: AgentTool) -> String {
        "pane-\(tool.displayName.lowercased())"
    }

    private func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    private func defaultInteractionKind(for state: PaneAgentState) -> PaneAgentInteractionKind {
        state == .needsInput ? .genericInput : .none
    }

    private func defaultConfidence(for origin: AgentSignalOrigin) -> AgentSignalConfidence {
        switch origin {
        case .explicitHook, .explicitAPI:
            return .explicit
        case .heuristic, .compatibility:
            return .strong
        case .shell, .inferred:
            return .weak
        }
    }

    private func statusSource(for origin: AgentSignalOrigin) -> PaneAgentStatusSource {
        switch origin {
        case .shell, .inferred:
            return .inferred
        case .compatibility, .explicitHook, .explicitAPI, .heuristic:
            return .explicit
        }
    }

    private func maxOrigin(_ lhs: AgentSignalOrigin, _ rhs: AgentSignalOrigin) -> AgentSignalOrigin {
        lhs.priority >= rhs.priority ? lhs : rhs
    }

    private func explicitArtifactLink(from payload: AgentStatusPayload) -> WorklaneArtifactLink? {
        guard
            let kind = payload.artifactKind,
            let label = payload.artifactLabel,
            let url = payload.artifactURL
        else {
            return nil
        }

        return WorklaneArtifactLink(kind: kind, label: label, url: url, isExplicit: true)
    }
}
