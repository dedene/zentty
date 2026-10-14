import Foundation

/// Store-only Muse Code mutation, driven by `MuseTitleActivity` from
/// `WorklaneStore` title reconciliation rather than by hook payloads.
extension PaneAgentReducerState {
    /// Ends the running Muse turn once its title spinner settles: a natural
    /// completion, so the caller requests "Agent ready". Open prompts are
    /// left to their own hooks.
    @discardableResult
    mutating func markExplicitMuseSessionIdleFromSettledTitle(now: Date = Date()) -> Bool {
        let candidateSessions = sessionsByID.values.filter { session in
            session.tool == .muse
                && session.source == .explicit
                && (session.origin == .explicitHook || session.origin == .explicitAPI)
                && session.hasObservedRunning
                && session.state == .running
                && !session.interactionKind.requiresHumanAttention
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
}
