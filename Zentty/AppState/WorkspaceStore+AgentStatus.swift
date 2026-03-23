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
            }
        case .commandFinished:
            workspace.auxiliaryStateByPaneID[paneID]?.terminalProgress = nil
            let existingStatus = workspace.auxiliaryStateByPaneID[paneID]?.agentStatus
            if existingStatus?.state != .completed,
               existingStatus?.state != .needsInput,
               existingStatus?.state != .starting,
               existingStatus?.source == .explicit,
               let tool = existingStatus?.tool {
                workspace.auxiliaryStateByPaneID[paneID, default: PaneAuxiliaryState()].agentStatus = PaneAgentStatus(
                    tool: tool,
                    state: .unresolvedStop,
                    text: nil,
                    artifactLink: existingStatus?.artifactLink,
                    updatedAt: Date(),
                    source: .inferred,
                    origin: .inferred,
                    interactionState: PaneInteractionState.none,
                    shellActivityState: existingStatus?.shellActivityState ?? .unknown,
                    trackedPID: nil
                )
            }
        }

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
            workspace.auxiliaryStateByPaneID[payload.paneID]?.agentStatus = nil
            workspace.auxiliaryStateByPaneID[payload.paneID]?.terminalProgress = nil
            workspaces[workspaceIndex] = workspace
            notify(.auxiliaryStateUpdated(workspace.id, payload.paneID))
            return
        }

        if payload.clearsPaneContext {
            workspace.auxiliaryStateByPaneID[payload.paneID]?.shellContext = nil
            clearPaneContextBranch(for: payload.paneID, in: &workspace)
            workspaces[workspaceIndex] = workspace
            refreshLastFocusedLocalWorkingDirectoryIfNeeded(workspace: workspace, paneID: payload.paneID)
            notify(.auxiliaryStateUpdated(workspace.id, payload.paneID))
            return
        }

        let existingStatus = workspace.auxiliaryStateByPaneID[payload.paneID]?.agentStatus
        let tool = AgentTool.resolve(named: payload.toolName)
            ?? existingStatus?.tool
            ?? AgentToolRecognizer.recognize(metadata: workspace.auxiliaryStateByPaneID[payload.paneID]?.metadata)

        switch payload.signalKind {
        case .lifecycle:
            guard payload.state != nil, let tool else {
                return
            }
            guard shouldApplyLifecycleSignal(payload, over: existingStatus) else {
                return
            }

            workspace.auxiliaryStateByPaneID[payload.paneID, default: PaneAuxiliaryState()].agentStatus = Self.makeLifecycleStatus(
                tool: tool,
                payload: payload,
                existingStatus: existingStatus
            )
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
                        workspaces[workspaceIndex] = workspace
                        notify(.auxiliaryStateUpdated(workspace.id, payload.paneID))
                        return
                    case .unknown:
                        break
                    }
                }

                workspace.auxiliaryStateByPaneID[payload.paneID, default: PaneAuxiliaryState()].agentStatus = existingStatus
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

                var status = existingStatus
                    .map {
                        PaneAgentStatus(
                            tool: tool,
                            state: ($0.state == .completed || $0.state == .unresolvedStop) ? .starting : $0.state,
                            text: $0.text,
                            artifactLink: $0.artifactLink,
                            updatedAt: Date(),
                            source: $0.source,
                            origin: $0.origin.priority >= payload.origin.priority ? $0.origin : payload.origin,
                            interactionState: $0.interactionState,
                            shellActivityState: $0.shellActivityState,
                            trackedPID: $0.trackedPID
                        )
                    }
                    ?? PaneAgentStatus(
                        tool: tool,
                        state: .starting,
                        text: nil,
                        artifactLink: nil,
                        updatedAt: Date(),
                        source: .explicit,
                        origin: payload.origin,
                        interactionState: PaneInteractionState.none
                    )
                status.trackedPID = pid
                status.updatedAt = Date()
                workspace.auxiliaryStateByPaneID[payload.paneID, default: PaneAuxiliaryState()].agentStatus = status
            case .clear:
                guard var status = existingStatus else {
                    return
                }
                status.trackedPID = nil
                status.updatedAt = Date()
                workspace.auxiliaryStateByPaneID[payload.paneID, default: PaneAuxiliaryState()].agentStatus = status
            }
        case .paneContext:
            guard let paneContext = payload.paneContext else {
                return
            }

            workspace.auxiliaryStateByPaneID[payload.paneID, default: PaneAuxiliaryState()].shellContext = paneContext
            updatePaneContextBranch(paneContext.gitBranch, for: payload.paneID, in: &workspace)
        }

        workspaces[workspaceIndex] = workspace
        refreshLastFocusedLocalWorkingDirectoryIfNeeded(workspace: workspace, paneID: payload.paneID)
        notify(.auxiliaryStateUpdated(workspace.id, payload.paneID))
    }

    func clearStaleAgentSessions() {
        var didChange = false

        for workspaceIndex in workspaces.indices {
            var workspace = workspaces[workspaceIndex]

            for (paneID, aux) in workspace.auxiliaryStateByPaneID {
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
                    workspace.auxiliaryStateByPaneID[paneID]?.inferredArtifact = nil
                } else {
                    var nextStatus = status
                    nextStatus.trackedPID = nil
                    workspace.auxiliaryStateByPaneID[paneID]?.agentStatus = nextStatus
                }
            }

            workspaces[workspaceIndex] = workspace
        }

        if didChange {
            notify(.workspaceListChanged)
        }
    }

    private func shouldApplyLifecycleSignal(
        _ payload: AgentStatusPayload,
        over existingStatus: PaneAgentStatus?
    ) -> Bool {
        guard let existingStatus else {
            return true
        }

        if payload.origin.priority >= existingStatus.origin.priority {
            return true
        }

        return payload.state == existingStatus.state
    }

    private static func makeLifecycleStatus(
        tool: AgentTool,
        payload: AgentStatusPayload,
        existingStatus: PaneAgentStatus?
    ) -> PaneAgentStatus {
        let artifactLink = explicitArtifactLink(from: payload) ?? existingStatus?.artifactLink
        let state = payload.state ?? .running
        let payloadText = AgentInteractionClassifier.trimmed(payload.text)
        let existingText = AgentInteractionClassifier.trimmed(existingStatus?.text)
        let text: String?
        if state == .needsInput, existingStatus?.state == .needsInput {
            text = AgentInteractionClassifier.preferredWaitingMessage(
                existing: existingText,
                candidate: payloadText
            )
        } else if state == .needsInput {
            text = payloadText ?? existingText
        } else {
            text = nil
        }

        return PaneAgentStatus(
            tool: tool,
            state: state,
            text: text,
            artifactLink: artifactLink,
            updatedAt: Date(),
            source: payload.origin == .inferred ? .inferred : .explicit,
            origin: payload.origin,
            interactionState: state == .needsInput ? .awaitingHuman : .none,
            shellActivityState: existingStatus?.shellActivityState ?? .unknown,
            trackedPID: state == .completed ? nil : existingStatus?.trackedPID
        )
    }

    private static func explicitArtifactLink(from payload: AgentStatusPayload) -> WorkspaceArtifactLink? {
        guard
            let kind = payload.artifactKind,
            let label = payload.artifactLabel,
            let url = payload.artifactURL
        else {
            return nil
        }

        return WorkspaceArtifactLink(
            kind: kind,
            label: label,
            url: url,
            isExplicit: true
        )
    }

    private func updatePaneContextBranch(
        _ gitBranch: String?,
        for paneID: PaneID,
        in workspace: inout WorkspaceState
    ) {
        var metadata = workspace.auxiliaryStateByPaneID[paneID]?.metadata ?? TerminalMetadata()
        let previousBranch = WorkspaceContextFormatter.trimmed(metadata.gitBranch)
        let nextBranch = WorkspaceContextFormatter.trimmed(gitBranch)
        guard previousBranch != nextBranch else {
            return
        }

        metadata.gitBranch = nextBranch
        workspace.auxiliaryStateByPaneID[paneID, default: PaneAuxiliaryState()].metadata = metadata
        clearBranchDerivedReviewArtifacts(for: paneID, in: &workspace)
    }

    private func clearPaneContextBranch(for paneID: PaneID, in workspace: inout WorkspaceState) {
        updatePaneContextBranch(nil, for: paneID, in: &workspace)
    }

    private func clearBranchDerivedReviewArtifacts(for paneID: PaneID, in workspace: inout WorkspaceState) {
        workspace.auxiliaryStateByPaneID[paneID]?.inferredArtifact = nil
        workspace.auxiliaryStateByPaneID[paneID]?.reviewState = nil
        if var status = workspace.auxiliaryStateByPaneID[paneID]?.agentStatus, status.artifactLink?.kind == .pullRequest {
            status.artifactLink = nil
            workspace.auxiliaryStateByPaneID[paneID]?.agentStatus = status
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
}
