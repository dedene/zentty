import Foundation

/// Store-only Codex/Kimi session-graph mutations, partitioned out of the core
/// `PaneAgentReducerState` reducer. These are driven by title/interrupt/
/// user-input reconciliation in `WorklaneStore` (and its Codex resolver), not
/// by the generic `apply`/`sweep`/`reducedStatus` algebra that the reducer
/// tests pin. Kept in the same module so they still reach the shared
/// `preferred(lhs:rhs:)` ordering and window constants.
extension PaneAgentReducerState {
    @discardableResult
    mutating func promoteExplicitCodexSessionFromUserInput(
        allowNeedsInputResume: Bool = true,
        allowIdleResume: Bool = true,
        now: Date = Date()
    ) -> Bool {
        let candidateSessions = sessionsByID.values.filter { session in
            session.tool == .codex
                && session.source == .explicit
                && session.origin != .shell
                && (
                    (allowNeedsInputResume && session.state == .needsInput)
                        || session.state == .starting
                        || (allowIdleResume && session.state == .idle && session.hasObservedRunning)
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
                && (session.origin == .explicitHook || session.origin == .explicitAPI)
                && session.hasObservedRunning
                && !session.interactionKind.requiresHumanAttention
                && (
                    session.state == .running
                        || session.state == .starting
                )
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

    @discardableResult
    mutating func clearCodexSessionsFromUserInterrupt(now: Date = Date()) -> Bool {
        let sessionIDs = sessionsByID.values
            .filter { $0.tool == .codex }
            .sorted(by: Self.preferred(lhs:rhs:))
            .map(\.sessionID)
        guard !sessionIDs.isEmpty else {
            return false
        }

        for sessionID in sessionIDs {
            sessionsByID.removeValue(forKey: sessionID)
        }
        return true
    }

    @discardableResult
    mutating func markExplicitKimiSessionIdleFromUserInterrupt(now: Date = Date()) -> Bool {
        let candidateSessions = sessionsByID.values.filter { session in
            session.tool == .kimi
                && session.source == .explicit
                && session.origin != .shell
                && (
                    session.state == .running
                        || (session.state == .starting && !session.interactionKind.requiresHumanAttention)
                )
        }
        guard let sessionID = candidateSessions.sorted(by: Self.preferred(lhs:rhs:)).first?.sessionID,
              var session = sessionsByID[sessionID]
        else {
            return false
        }
        let previousState = session.state

        session.state = .idle
        session.text = nil
        session.interactionKind = .none
        session.completionCandidateDeadline = nil
        session.idleVisibleUntil = now.addingTimeInterval(Self.idleVisibilityWindow)
        session.unresolvedStopVisibleUntil = nil
        session.updatedAt = now
        session.hasObservedRunning = session.hasObservedRunning || previousState == .running
        sessionsByID[sessionID] = session
        return true
    }

    mutating func removeStaleCodexNeedsInputSessions(excluding sessionID: String) {
        for key in Array(sessionsByID.keys) {
            guard key != sessionID,
                  let session = sessionsByID[key],
                  session.tool == .codex,
                  (session.state == .needsInput || session.interactionKind.requiresHumanAttention) else {
                continue
            }
            sessionsByID.removeValue(forKey: key)
        }
    }

    static func codexNeedsInputIsWeakTerminalFallback(_ session: PaneAgentSessionState) -> Bool {
        guard session.tool == .codex,
              session.state == .needsInput,
              session.interactionKind == .genericInput,
              session.confidence == .weak else {
            return false
        }

        switch session.origin {
        case .heuristic, .inferred, .compatibility:
            return true
        case .explicitAPI, .explicitHook, .shell:
            return false
        }
    }
}
