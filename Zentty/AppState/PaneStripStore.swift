import Foundation

struct WorkspaceID: Hashable, Equatable, Sendable {
    let rawValue: String

    init(_ rawValue: String) {
        self.rawValue = rawValue
    }
}

struct WorkspaceState: Equatable, Sendable {
    let id: WorkspaceID
    var title: String
    var paneStripState: PaneStripState
    var nextPaneNumber: Int
    var metadataByPaneID: [PaneID: TerminalMetadata]
    var agentStatusByPaneID: [PaneID: PaneAgentStatus]
    var inferredArtifactByPaneID: [PaneID: WorkspaceArtifactLink]
    var reviewStateByPaneID: [PaneID: WorkspaceReviewState]

    init(
        id: WorkspaceID,
        title: String,
        paneStripState: PaneStripState,
        nextPaneNumber: Int = 1,
        metadataByPaneID: [PaneID: TerminalMetadata] = [:],
        agentStatusByPaneID: [PaneID: PaneAgentStatus] = [:],
        inferredArtifactByPaneID: [PaneID: WorkspaceArtifactLink] = [:],
        reviewStateByPaneID: [PaneID: WorkspaceReviewState] = [:]
    ) {
        self.id = id
        self.title = title
        self.paneStripState = paneStripState
        self.nextPaneNumber = nextPaneNumber
        self.metadataByPaneID = metadataByPaneID
        self.agentStatusByPaneID = agentStatusByPaneID
        self.inferredArtifactByPaneID = inferredArtifactByPaneID
        self.reviewStateByPaneID = reviewStateByPaneID
    }
}

final class WorkspaceStore {
    private(set) var workspaces: [WorkspaceState]
    private var layoutContext: PaneLayoutContext

    private(set) var activeWorkspaceID: WorkspaceID

    var onChange: ((PaneStripState) -> Void)?

    init(
        workspaces: [WorkspaceState] = [],
        layoutContext: PaneLayoutContext = .fallback,
        activeWorkspaceID: WorkspaceID? = nil
    ) {
        self.layoutContext = layoutContext
        let initialWorkspaces = workspaces.isEmpty ? WorkspaceStore.defaultWorkspaces(layoutContext: layoutContext) : workspaces
        self.workspaces = initialWorkspaces
        self.activeWorkspaceID = activeWorkspaceID ?? initialWorkspaces.first?.id ?? WorkspaceID("workspace-main")
        self.activeWorkspaceID = initialWorkspaces.contains(where: { $0.id == self.activeWorkspaceID })
            ? self.activeWorkspaceID
            : initialWorkspaces.first?.id ?? WorkspaceID("workspace-main")
    }

    var activeWorkspace: WorkspaceState? {
        get {
            workspaces.first { $0.id == activeWorkspaceID }
        }
        set {
            guard let newValue, let index = workspaces.firstIndex(where: { $0.id == newValue.id }) else {
                return
            }

            workspaces[index] = newValue
        }
    }

    var state: PaneStripState {
        activeWorkspace?.paneStripState ?? .pocDefault
    }

    func updateLayoutContext(_ layoutContext: PaneLayoutContext) {
        let previousLayoutContext = self.layoutContext
        self.layoutContext = layoutContext
        var didUpdatePaneWidths = false
        let viewportScaleFactor = Self.viewportScaleFactor(
            from: previousLayoutContext.viewportWidth,
            to: layoutContext.viewportWidth
        )

        for index in workspaces.indices {
            if workspaces[index].paneStripState.updateSinglePaneWidth(layoutContext.singlePaneWidth) {
                didUpdatePaneWidths = true
                continue
            }

            if let viewportScaleFactor,
               workspaces[index].paneStripState.scalePaneWidths(by: viewportScaleFactor) {
                didUpdatePaneWidths = true
            }
        }

        if didUpdatePaneWidths {
            notifyStateChanged()
        }
    }

    func send(_ command: PaneCommand) {
        guard var workspace = activeWorkspace else {
            return
        }

        switch command {
        case .split, .splitAfterFocusedPane:
            workspace.paneStripState.insertPane(makePane(in: &workspace), placement: .afterFocused)
        case .splitBeforeFocusedPane:
            workspace.paneStripState.insertPane(makePane(in: &workspace), placement: .beforeFocused)
        case .closeFocusedPane:
            if workspace.paneStripState.panes.count == 1 {
                guard removeActiveWorkspaceIfPossible() else {
                    notifyStateChanged()
                    return
                }
                notifyStateChanged()
                return
            }

            if let removedPane = workspace.paneStripState.closeFocusedPane(singlePaneWidth: layoutContext.singlePaneWidth) {
                clearPaneState(for: removedPane.id, in: &workspace)
            }
        case .focusLeft:
            workspace.paneStripState.moveFocusLeft()
        case .focusRight:
            workspace.paneStripState.moveFocusRight()
        case .focusFirst:
            workspace.paneStripState.moveFocusToFirst()
        case .focusLast:
            workspace.paneStripState.moveFocusToLast()
        }

        activeWorkspace = workspace
        notifyStateChanged()
    }

    func selectWorkspace(id: WorkspaceID) {
        guard workspaces.contains(where: { $0.id == id }) else {
            return
        }

        activeWorkspaceID = id
        notifyStateChanged()
    }

    func createWorkspace() {
        let newIndex = workspaces.count + 1
        let title = "WS \(newIndex)"
        let id = WorkspaceID("workspace-\(newIndex)")

        workspaces.append(
            Self.makeDefaultWorkspace(id: id, title: title, layoutContext: layoutContext)
        )
        activeWorkspaceID = id
        notifyStateChanged()
    }

    func focusPane(id: PaneID) {
        guard var workspace = activeWorkspace else {
            return
        }

        workspace.paneStripState.focusPane(id: id)
        activeWorkspace = workspace
        notifyStateChanged()
    }

    func updateMetadata(paneID: PaneID, metadata: TerminalMetadata) {
        guard let workspaceIndex = workspaces.firstIndex(where: { workspace in
            workspace.paneStripState.panes.contains(where: { $0.id == paneID })
        }) else {
            return
        }

        var workspace = workspaces[workspaceIndex]
        let previousMetadata = workspace.metadataByPaneID[paneID]
        workspace.metadataByPaneID[paneID] = metadata
        if branchContextDidChange(previous: previousMetadata, next: metadata) {
            clearBranchDerivedState(for: paneID, in: &workspace)
        }
        if
            let existingStatus = workspace.agentStatusByPaneID[paneID],
            existingStatus.source == .inferred,
            AgentToolRecognizer.recognize(metadata: metadata) == nil
        {
            workspace.agentStatusByPaneID.removeValue(forKey: paneID)
        }
        workspaces[workspaceIndex] = workspace
        notifyStateChanged()
    }

    func handleTerminalEvent(paneID: PaneID, event: TerminalEvent) {
        guard let workspaceIndex = workspaces.firstIndex(where: { workspace in
            workspace.paneStripState.panes.contains(where: { $0.id == paneID })
        }) else {
            return
        }

        var workspace = workspaces[workspaceIndex]
        switch event {
        case .commandFinished:
            let existingStatus = workspace.agentStatusByPaneID[paneID]
            guard existingStatus?.state != .completed, existingStatus?.state != .needsInput else {
                return
            }

            guard
                existingStatus?.source == .explicit,
                let tool = existingStatus?.tool
            else {
                return
            }

            workspace.agentStatusByPaneID[paneID] = PaneAgentStatus(
                tool: tool,
                state: .unresolvedStop,
                text: nil,
                artifactLink: existingStatus?.artifactLink,
                updatedAt: Date(),
                source: .inferred
            )
        }

        workspaces[workspaceIndex] = workspace
        notifyStateChanged()
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
            workspace.agentStatusByPaneID.removeValue(forKey: payload.paneID)
            workspaces[workspaceIndex] = workspace
            notifyStateChanged()
            return
        }

        guard let state = payload.state else {
            return
        }

        let existingStatus = workspace.agentStatusByPaneID[payload.paneID]
        guard
            let tool = AgentTool.resolve(named: payload.toolName)
                ?? existingStatus?.tool
                ?? AgentToolRecognizer.recognize(metadata: workspace.metadataByPaneID[payload.paneID])
        else {
            return
        }

        let artifactLink: WorkspaceArtifactLink?
        if
            let kind = payload.artifactKind,
            let label = payload.artifactLabel,
            let url = payload.artifactURL
        {
            artifactLink = WorkspaceArtifactLink(
                kind: kind,
                label: label,
                url: url,
                isExplicit: true
            )
        } else {
            artifactLink = existingStatus?.artifactLink
        }

        workspace.agentStatusByPaneID[payload.paneID] = PaneAgentStatus(
            tool: tool,
            state: state,
            text: payload.text ?? existingStatus?.text,
            artifactLink: artifactLink,
            updatedAt: Date(),
            source: .explicit
        )
        workspaces[workspaceIndex] = workspace
        notifyStateChanged()
    }

    func updateInferredArtifact(paneID: PaneID, artifact: WorkspaceArtifactLink?) {
        guard let workspaceIndex = workspaces.firstIndex(where: { workspace in
            workspace.paneStripState.panes.contains(where: { $0.id == paneID })
        }) else {
            return
        }

        var workspace = workspaces[workspaceIndex]
        let previousArtifact = workspace.inferredArtifactByPaneID[paneID]
        guard previousArtifact != artifact else {
            return
        }
        if let artifact {
            workspace.inferredArtifactByPaneID[paneID] = artifact
        } else {
            workspace.inferredArtifactByPaneID.removeValue(forKey: paneID)
        }
        workspaces[workspaceIndex] = workspace
        notifyStateChanged()
    }

    func updateReviewResolution(paneID: PaneID, resolution: WorkspaceReviewResolution) {
        guard let workspaceIndex = workspaces.firstIndex(where: { workspace in
            workspace.paneStripState.panes.contains(where: { $0.id == paneID })
        }) else {
            return
        }

        var workspace = workspaces[workspaceIndex]
        let previousState = workspace.reviewStateByPaneID[paneID]
        let previousArtifact = workspace.inferredArtifactByPaneID[paneID]
        guard previousState != resolution.reviewState || previousArtifact != resolution.inferredArtifact else {
            return
        }

        if let reviewState = resolution.reviewState {
            workspace.reviewStateByPaneID[paneID] = reviewState
        } else {
            workspace.reviewStateByPaneID.removeValue(forKey: paneID)
        }

        if let artifact = resolution.inferredArtifact {
            workspace.inferredArtifactByPaneID[paneID] = artifact
        } else {
            workspace.inferredArtifactByPaneID.removeValue(forKey: paneID)
        }

        workspaces[workspaceIndex] = workspace
        notifyStateChanged()
    }

    func updateReviewState(paneID: PaneID, reviewState: WorkspaceReviewState?) {
        guard let workspaceIndex = workspaces.firstIndex(where: { workspace in
            workspace.paneStripState.panes.contains(where: { $0.id == paneID })
        }) else {
            return
        }

        var workspace = workspaces[workspaceIndex]
        let previousState = workspace.reviewStateByPaneID[paneID]
        guard previousState != reviewState else {
            return
        }

        if let reviewState {
            workspace.reviewStateByPaneID[paneID] = reviewState
        } else {
            workspace.reviewStateByPaneID.removeValue(forKey: paneID)
        }

        workspaces[workspaceIndex] = workspace
        notifyStateChanged()
    }

    func closePane(id: PaneID) {
        guard var workspace = activeWorkspace else {
            return
        }

        workspace.paneStripState.focusPane(id: id)
        if workspace.paneStripState.panes.count == 1 {
            guard removeActiveWorkspaceIfPossible() else {
                notifyStateChanged()
                return
            }
            notifyStateChanged()
            return
        }

        if let removedPane = workspace.paneStripState.closeFocusedPane(singlePaneWidth: layoutContext.singlePaneWidth) {
            clearPaneState(for: removedPane.id, in: &workspace)
        }

        activeWorkspace = workspace
        notifyStateChanged()
    }

    func updateMetadata(id: PaneID, metadata: TerminalMetadata) {
        updateMetadata(paneID: id, metadata: metadata)
    }

    func replaceWorkspacesForTesting(_ workspaces: [WorkspaceState], activeWorkspaceID: WorkspaceID? = nil) {
        self.workspaces = workspaces
        let fallbackID = activeWorkspaceID ?? workspaces.first?.id ?? WorkspaceID("workspace-main")
        self.activeWorkspaceID = workspaces.contains(where: { $0.id == fallbackID })
            ? fallbackID
            : workspaces.first?.id ?? WorkspaceID("workspace-main")
        notifyStateChanged()
    }

    private func clearStatusDerivedState(for paneID: PaneID, in workspace: inout WorkspaceState) {
        workspace.agentStatusByPaneID.removeValue(forKey: paneID)
    }

    private func clearBranchDerivedState(for paneID: PaneID, in workspace: inout WorkspaceState) {
        workspace.inferredArtifactByPaneID.removeValue(forKey: paneID)
        workspace.reviewStateByPaneID.removeValue(forKey: paneID)
        if var status = workspace.agentStatusByPaneID[paneID], status.artifactLink?.kind == .pullRequest {
            status.artifactLink = nil
            workspace.agentStatusByPaneID[paneID] = status
        }
    }

    private func clearPaneState(for paneID: PaneID, in workspace: inout WorkspaceState) {
        workspace.metadataByPaneID.removeValue(forKey: paneID)
        clearStatusDerivedState(for: paneID, in: &workspace)
        clearBranchDerivedState(for: paneID, in: &workspace)
    }

    private func branchContextDidChange(previous: TerminalMetadata?, next: TerminalMetadata) -> Bool {
        WorkspaceContextFormatter.trimmed(previous?.gitBranch) != WorkspaceContextFormatter.trimmed(next.gitBranch)
            || WorkspaceContextFormatter.resolvedWorkingDirectory(for: previous) != WorkspaceContextFormatter.resolvedWorkingDirectory(for: next)
    }

    private func makePane(in workspace: inout WorkspaceState) -> PaneState {
        defer {
            workspace.nextPaneNumber += 1
        }

        let title = "pane \(workspace.nextPaneNumber)"
        let paneID = PaneID("\(workspace.id.rawValue)-pane-\(workspace.nextPaneNumber)")
        let focusedPaneID = workspace.paneStripState.focusedPaneID
        let workingDirectory = focusedPaneID.flatMap {
            workspace.metadataByPaneID[$0]?.currentWorkingDirectory
        }
        return PaneState(
            id: paneID,
            title: title,
            sessionRequest: TerminalSessionRequest(
                workingDirectory: workingDirectory,
                inheritFromPaneID: focusedPaneID,
                environmentVariables: Self.sessionEnvironment(
                    workspaceID: workspace.id,
                    paneID: paneID
                )
            ),
            width: layoutContext.newPaneWidth
        )
    }

    private static func defaultWorkspaces(layoutContext: PaneLayoutContext) -> [WorkspaceState] {
        [
            makeDefaultWorkspace(
                id: WorkspaceID("workspace-main"),
                title: "MAIN",
                layoutContext: layoutContext
            ),
        ]
    }

    private static func makeDefaultWorkspace(
        id: WorkspaceID,
        title: String,
        layoutContext: PaneLayoutContext
    ) -> WorkspaceState {
        let shellPaneID = PaneID("\(id.rawValue)-shell")
        return WorkspaceState(
            id: id,
            title: title,
            paneStripState: PaneStripState(
                panes: [
                    PaneState(
                        id: shellPaneID,
                        title: "shell",
                        sessionRequest: TerminalSessionRequest(
                            environmentVariables: Self.sessionEnvironment(
                                workspaceID: id,
                                paneID: shellPaneID
                            )
                        ),
                        width: layoutContext.singlePaneWidth
                    ),
                ],
                focusedPaneID: shellPaneID
            )
        )
    }

    private func notifyStateChanged() {
        onChange?(state)
    }

    private static func sessionEnvironment(
        workspaceID: WorkspaceID,
        paneID: PaneID
    ) -> [String: String] {
        var environment: [String: String] = [
            "ZENTTY_WORKSPACE_ID": workspaceID.rawValue,
            "ZENTTY_PANE_ID": paneID.rawValue,
        ]
        if let helperPath = AgentStatusHelper.binaryPath() {
            environment["ZENTTY_AGENT_BIN"] = helperPath
        }
        if let claudeHookCommand = AgentStatusHelper.claudeHookCommand() {
            environment["ZENTTY_CLAUDE_HOOK_COMMAND"] = claudeHookCommand
        }
        return environment
    }

    private static func viewportScaleFactor(
        from previousViewportWidth: CGFloat,
        to nextViewportWidth: CGFloat
    ) -> CGFloat? {
        guard previousViewportWidth > 0, nextViewportWidth > 0 else {
            return nil
        }

        return nextViewportWidth / previousViewportWidth
    }

    @discardableResult
    private func removeActiveWorkspaceIfPossible() -> Bool {
        guard workspaces.count > 1, let activeIndex = workspaces.firstIndex(where: { $0.id == activeWorkspaceID }) else {
            return false
        }

        workspaces.remove(at: activeIndex)
        let replacementIndex = min(max(activeIndex - 1, 0), workspaces.count - 1)
        activeWorkspaceID = workspaces[replacementIndex].id
        return true
    }
}

typealias PaneStripStore = WorkspaceStore
