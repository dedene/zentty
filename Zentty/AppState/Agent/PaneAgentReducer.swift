import Foundation

struct PaneAgentSessionState: Equatable, Sendable {
    var sessionID: String
    var parentSessionID: String?
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
    var completionCandidateDeadline: Date?
    var idleVisibleUntil: Date?
    var unresolvedStopVisibleUntil: Date?
}

struct PaneAgentReducerState: Equatable, Sendable {
    static let stopGraceWindow: TimeInterval = 2
    static let ephemeralStartExitWindow: TimeInterval = 1
    static let idleVisibilityWindow: TimeInterval = 120
    static let unresolvedStopVisibilityWindow: TimeInterval = 600
    static let staleSessionVisibilityWindow: TimeInterval = 1_800

    var sessionsByID: [String: PaneAgentSessionState] = [:]

    mutating func apply(_ payload: AgentStatusPayload, now: Date = Date()) {
        switch payload.signalKind {
        case .lifecycle:
            applyLifecycle(payload, now: now)
        case .pid:
            applyPID(payload, now: now)
        case .shellState:
            applyShellState(payload, now: now)
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
            session.state == .needsInput || session.interactionKind.requiresHumanAttention
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
    mutating func promoteExplicitCodexSessionFromUserInput(now: Date = Date()) -> Bool {
        let candidateSessions = sessionsByID.values.filter { session in
            session.tool == .codex
                && session.source == .explicit
                && session.origin != .shell
                && (
                    session.state == .needsInput
                        || session.state == .starting
                        || (session.state == .idle && session.hasObservedRunning)
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
    mutating func markExplicitCodexSessionIdleFromReadyTitle(now: Date = Date()) -> Bool {
        let candidateSessions = sessionsByID.values.filter { session in
            session.tool == .codex
                && session.source == .explicit
                && session.origin != .shell
                && session.hasObservedRunning
                && !session.interactionKind.requiresHumanAttention
                && (session.state == .running || session.state == .starting)
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
        guard let session = sessions.sorted(by: Self.preferred(lhs:rhs:)).first else {
            return nil
        }

        return PaneAgentStatus(
            tool: session.tool,
            state: session.state,
            text: session.text,
            artifactLink: session.artifactLink,
            updatedAt: session.updatedAt,
            source: session.source,
            origin: session.origin,
            interactionKind: session.interactionKind,
            confidence: session.confidence,
            shellActivityState: session.shellActivityState,
            trackedPID: session.state == .idle ? nil : session.trackedPID,
            hasObservedRunning: session.hasObservedRunning,
            sessionID: session.sessionID,
            parentSessionID: session.parentSessionID
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

        let sessionID = resolvedSessionID(for: payload, tool: tool)
        var session = sessionsByID[sessionID] ?? PaneAgentSessionState(
            sessionID: sessionID,
            parentSessionID: normalized(payload.parentSessionID),
            tool: tool,
            state: .starting,
            text: nil,
            artifactLink: explicitArtifactLink(from: payload),
            updatedAt: now,
            source: payload.origin == .inferred ? .inferred : .explicit,
            origin: payload.origin,
            interactionKind: .none,
            confidence: payload.confidence ?? defaultConfidence(for: payload.origin),
            shellActivityState: .unknown,
            trackedPID: nil,
            hasObservedRunning: false,
            completionCandidateDeadline: nil,
            idleVisibleUntil: nil,
            unresolvedStopVisibleUntil: nil
        )

        if payload.origin != .inferred {
            mergeInferredSessions(into: &session, for: tool, excluding: sessionID)
        }

        if !shouldApplyLifecycle(payload, over: session) {
            return
        }

        let interactionKind = payload.interactionKind ?? defaultInteractionKind(for: state)
        let payloadText = AgentInteractionClassifier.trimmed(payload.text)
        let existingText = AgentInteractionClassifier.trimmed(session.text)
        let previousState = session.state
        let previousInteractionKind = session.interactionKind

        session.parentSessionID = normalized(payload.parentSessionID) ?? session.parentSessionID
        session.tool = tool
        session.source = payload.origin == .inferred ? .inferred : .explicit
        session.origin = payload.origin
        session.confidence = payload.confidence ?? defaultConfidence(for: payload.origin)
        session.artifactLink = explicitArtifactLink(from: payload) ?? session.artifactLink
        session.updatedAt = now
        session.idleVisibleUntil = nil
        session.unresolvedStopVisibleUntil = nil

        if payload.lifecycleEvent == .stopCandidate {
            session.state = .running
            session.interactionKind = .none
            session.text = nil
            session.completionCandidateDeadline = now.addingTimeInterval(Self.stopGraceWindow)
            sessionsByID[sessionID] = session
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
                if interactionKind.priority > previousInteractionKind.priority {
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
        case .idle:
            session.text = nil
            session.idleVisibleUntil = now.addingTimeInterval(Self.idleVisibilityWindow)
        case .unresolvedStop:
            session.text = nil
            session.trackedPID = nil
            session.unresolvedStopVisibleUntil = now.addingTimeInterval(Self.unresolvedStopVisibilityWindow)
        case .running, .starting:
            session.text = nil
        }

        sessionsByID[sessionID] = session
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
            if inferredSession.updatedAt > session.updatedAt {
                session.updatedAt = inferredSession.updatedAt
            }
            sessionsByID.removeValue(forKey: inferredSession.sessionID)
        }
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
                completionCandidateDeadline: nil,
                idleVisibleUntil: nil,
                unresolvedStopVisibleUntil: nil
            )

            if session.state == .idle || session.state == .unresolvedStop {
                session.state = .starting
            }
            session.tool = tool
            session.origin = maxOrigin(session.origin, payload.origin)
            session.updatedAt = now
            session.trackedPID = pid
            session.parentSessionID = normalized(payload.parentSessionID) ?? session.parentSessionID
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
            _ = promoteExplicitStartingSessionToRunning(now: now)
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
        over existingSession: PaneAgentSessionState
    ) -> Bool {
        if existingSession.state == .needsInput,
           existingSession.interactionKind.requiresHumanAttention,
           payload.state == .idle {
            return false
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

    private static func preferred(lhs: PaneAgentSessionState, rhs: PaneAgentSessionState) -> Bool {
        if sessionPriority(lhs) != sessionPriority(rhs) {
            return sessionPriority(lhs) > sessionPriority(rhs)
        }

        if lhs.confidence.priority != rhs.confidence.priority {
            return lhs.confidence.priority > rhs.confidence.priority
        }

        if lhs.origin.priority != rhs.origin.priority {
            return lhs.origin.priority > rhs.origin.priority
        }

        return lhs.updatedAt > rhs.updatedAt
    }

    private static func sessionPriority(_ session: PaneAgentSessionState) -> Int {
        if session.interactionKind.requiresHumanAttention || session.state == .needsInput {
            return 500 + session.interactionKind.priority
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

        return "pane-\(tool.displayName.lowercased())"
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
