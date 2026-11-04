import CoreGraphics
import Foundation

extension WorklaneStore {
    struct AgentForkResult: Equatable {
        let paneID: PaneID
        let worklaneID: WorklaneID
    }

    enum AgentForkError: LocalizedError, Equatable {
        case paneNotFound
        case unavailable(String)

        var errorDescription: String? {
            switch self {
            case .paneNotFound:
                "No pane to fork."
            case .unavailable(let reason):
                reason
            }
        }
    }

    /// Fork availability for a pane; `nil` when no agent runs in it.
    func agentForkAvailability(for paneID: PaneID) -> AgentForkAvailability? {
        guard let worklaneIndex = self.worklaneIndex(containingPane: paneID),
              let pane = worklanes[worklaneIndex].pane(id: paneID) else {
            return nil
        }
        return AgentForkCommandBuilder.availability(
            pane: pane,
            auxiliary: worklanes[worklaneIndex].auxiliaryStateByPaneID[paneID]
        )
    }

    /// Opens the agent's own fork command in a new pane next to `paneID`,
    /// leaving the source agent running. The command is typed at the new
    /// pane's shell prompt so the Zentty agent wrapper launches it. A
    /// `sessionOverride` forks that session of the pane instead of the
    /// visible agent.
    @discardableResult
    func forkAgentConversation(
        paneID: PaneID,
        destination: AgentForkDestination,
        sessionOverride: AgentForkSessionOverride? = nil
    ) throws -> AgentForkResult {
        guard let sourceWorklaneIndex = worklaneIndex(containingPane: paneID),
              let sourcePane = worklanes[sourceWorklaneIndex].pane(id: paneID) else {
            throw AgentForkError.paneNotFound
        }
        let sourceWorklane = worklanes[sourceWorklaneIndex]
        let availability = AgentForkCommandBuilder.availability(
            pane: sourcePane,
            auxiliary: sourceWorklane.auxiliaryStateByPaneID[paneID],
            sessionOverride: sessionOverride
        ) ?? .unavailable(reason: AgentForkCommandBuilder.noAgentReason)
        guard let plan = availability.plan else {
            throw AgentForkError.unavailable(availability.unavailableReason ?? AgentForkCommandBuilder.noAgentReason)
        }

        // The fork command is one-shot: restoring a closed fork pane must
        // resume the fork's own session or open a shell, never fork again.
        var sessionRequest = TerminalSessionRequest(
            workingDirectory: plan.workingDirectory,
            command: plan.command
        )
        sessionRequest.replaysCommandOnRestore = false

        let result: AgentForkResult
        switch destination {
        case .splitRight where sourceWorklane.isFloating(paneID),
             .splitDown where sourceWorklane.isFloating(paneID):
            // A float is not a strip split target: fork into a new float
            // offset from the source instead.
            guard let newPaneID = openFloat(
                besideFloat: paneID,
                in: sourceWorklane.id,
                workingDirectory: plan.workingDirectory,
                sourceShellContext: sourceWorklane.auxiliaryStateByPaneID[paneID]?.shellContext,
                command: plan.command,
                configure: { $0.sessionRequest.replaysCommandOnRestore = false }
            ) else {
                throw AgentForkError.paneNotFound
            }
            result = AgentForkResult(paneID: newPaneID, worklaneID: sourceWorklane.id)
        case .splitRight, .splitDown:
            guard let newPaneID = splitWithLayout(
                in: sourceWorklane.id,
                placement: .afterFocused,
                isHorizontal: destination == .splitRight,
                layout: .none,
                availableWidth: layoutContext.availableWidth,
                leadingVisibleInset: layoutContext.leadingVisibleInset,
                availableSize: .zero,
                minimumSizeByPaneID: [:],
                targetPaneID: paneID,
                sessionRequest: sessionRequest
            ) else {
                throw AgentForkError.paneNotFound
            }
            result = AgentForkResult(paneID: newPaneID, worklaneID: sourceWorklane.id)
        case .newWorklane:
            let launched = openWorklane(
                workingDirectory: plan.workingDirectory,
                command: plan.command,
                anchorWorklaneID: sourceWorklane.id,
                sourceShellContext: sourceWorklane.auxiliaryStateByPaneID[paneID]?.shellContext
            )
            result = AgentForkResult(paneID: launched.paneID, worklaneID: launched.worklaneID)
        }

        if let title = AgentForkCommandBuilder.forkedPaneTitle(sourceCustomTitle: sourcePane.customTitle) {
            setPaneCustomTitle(title, on: result.paneID)
        }
        return result
    }
}
