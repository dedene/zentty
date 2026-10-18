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
        guard let worklane = worklanes.first(where: { $0.paneStripState.panes.contains { $0.id == paneID } }),
              let pane = worklane.paneStripState.panes.first(where: { $0.id == paneID }) else {
            return nil
        }
        return AgentForkCommandBuilder.availability(
            pane: pane,
            auxiliary: worklane.auxiliaryStateByPaneID[paneID]
        )
    }

    /// Opens the agent's own fork command in a new pane next to `paneID`,
    /// leaving the source agent running. The command is typed at the new
    /// pane's shell prompt so the Zentty agent wrapper launches it.
    @discardableResult
    func forkAgentConversation(
        paneID: PaneID,
        destination: AgentForkDestination
    ) throws -> AgentForkResult {
        guard let sourceWorklane = worklanes.first(where: {
            $0.paneStripState.panes.contains { $0.id == paneID }
        }),
            let sourcePane = sourceWorklane.paneStripState.panes.first(where: { $0.id == paneID }) else {
            throw AgentForkError.paneNotFound
        }
        let availability = AgentForkCommandBuilder.availability(
            pane: sourcePane,
            auxiliary: sourceWorklane.auxiliaryStateByPaneID[paneID]
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
            result = forkIntoNewWorklane(
                plan: plan,
                sourceShellContext: sourceWorklane.auxiliaryStateByPaneID[paneID]?.shellContext,
                anchorWorklaneID: sourceWorklane.id
            )
        }

        if let title = AgentForkCommandBuilder.forkedPaneTitle(sourceCustomTitle: sourcePane.customTitle) {
            setPaneCustomTitle(title, on: result.paneID)
        }
        return result
    }

    private func forkIntoNewWorklane(
        plan: AgentForkPlan,
        sourceShellContext: PaneShellContext?,
        anchorWorklaneID: WorklaneID
    ) -> AgentForkResult {
        var worklane = WorklaneState(
            id: runtimeIdentity.makeWorklaneID(),
            title: nil,
            paneStripState: PaneStripState(columns: [], focusedColumnID: nil),
            nextPaneNumber: 1
        )
        var pane = makePaneWithDirectory(
            in: &worklane,
            existingPaneCount: 0,
            workingDirectory: plan.workingDirectory,
            sourceShellContext: sourceShellContext,
            command: plan.command
        )
        pane.sessionRequest.surfaceContext = .tab
        pane.sessionRequest.replaysCommandOnRestore = false
        worklane.paneStripState.insertPaneAsColumn(
            pane,
            atColumnIndex: 0,
            width: layoutContext.singlePaneWidth
        )

        worklanes.insert(worklane, at: insertionIndexForNewWorklane(anchorWorklaneID: anchorWorklaneID))
        notify(.worklaneListChanged)
        selectWorklane(id: worklane.id)
        return AgentForkResult(paneID: pane.id, worklaneID: worklane.id)
    }
}
