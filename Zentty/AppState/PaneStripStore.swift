import Darwin
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
    var paneContextByPaneID: [PaneID: PaneShellContext]
    var agentStatusByPaneID: [PaneID: PaneAgentStatus]
    var inferredArtifactByPaneID: [PaneID: WorkspaceArtifactLink]

    init(
        id: WorkspaceID,
        title: String,
        paneStripState: PaneStripState,
        nextPaneNumber: Int = 1,
        metadataByPaneID: [PaneID: TerminalMetadata] = [:],
        paneContextByPaneID: [PaneID: PaneShellContext] = [:],
        agentStatusByPaneID: [PaneID: PaneAgentStatus] = [:],
        inferredArtifactByPaneID: [PaneID: WorkspaceArtifactLink] = [:]
    ) {
        self.id = id
        self.title = title
        self.paneStripState = paneStripState
        self.nextPaneNumber = nextPaneNumber
        self.metadataByPaneID = metadataByPaneID
        self.paneContextByPaneID = paneContextByPaneID
        self.agentStatusByPaneID = agentStatusByPaneID
        self.inferredArtifactByPaneID = inferredArtifactByPaneID
    }
}

struct PaneBorderContextDisplayModel: Equatable, Sendable {
    let text: String
}

extension WorkspaceState {
    var paneBorderContextDisplayByPaneID: [PaneID: PaneBorderContextDisplayModel] {
        paneContextByPaneID.compactMapValues { $0.displayModel }
    }
}

private extension PaneShellContext {
    var displayModel: PaneBorderContextDisplayModel? {
        switch scope {
        case .local:
            guard let compactPath = Self.compactPath(path, home: home) else {
                return nil
            }
            if compactPath == "~" {
                let identity = [user, host].compactMap { $0 }.joined(separator: "@")
                if !identity.isEmpty {
                    return PaneBorderContextDisplayModel(text: "\(identity):\(compactPath)")
                }
            }
            return PaneBorderContextDisplayModel(text: compactPath)
        case .remote:
            let identity = [user, host]
                .compactMap { value -> String? in
                    guard let value, !value.isEmpty else {
                        return nil
                    }
                    return value
                }
                .joined(separator: "@")
            let compactPath = Self.compactPath(path, home: home)

            if !identity.isEmpty, let compactPath, !compactPath.isEmpty {
                return PaneBorderContextDisplayModel(text: "\(identity) \(compactPath)")
            }

            if !identity.isEmpty {
                return PaneBorderContextDisplayModel(text: identity)
            }

            if let compactPath, !compactPath.isEmpty {
                return PaneBorderContextDisplayModel(text: compactPath)
            }

            return nil
        }
    }

    static func compactPath(_ path: String?, home: String?) -> String? {
        guard let path, !path.isEmpty else {
            return nil
        }

        guard let home, !home.isEmpty, path.hasPrefix(home) else {
            return path
        }

        if path == home {
            return "~"
        }

        return path.replacingOccurrences(of: home, with: "~", options: [.anchored])
    }
}

final class WorkspaceStore {
    private struct PaneLaunchContext {
        let path: String
        let scope: PaneShellContextScope?
    }

    private(set) var workspaces: [WorkspaceState]
    private var layoutContext: PaneLayoutContext
    private var paneViewportHeight: CGFloat = .greatestFiniteMagnitude
    private var lastFocusedLocalWorkingDirectory: String?

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
        refreshLastFocusedLocalWorkingDirectory()
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

    func updatePaneViewportHeight(_ height: CGFloat) {
        paneViewportHeight = max(1, height)
    }

    func send(_ command: PaneCommand) {
        guard var workspace = activeWorkspace else {
            return
        }

        switch command {
        case .split, .splitHorizontally, .splitAfterFocusedPane:
            insertNewPaneHorizontally(into: &workspace, placement: .afterFocused)
        case .splitVertically:
            insertNewPaneVertically(into: &workspace)
        case .splitBeforeFocusedPane:
            insertNewPaneHorizontally(into: &workspace, placement: .beforeFocused)
        case .closeFocusedPane:
            if workspace.paneStripState.columns.count == 1,
               workspace.paneStripState.panes.count == 1 {
                guard removeActiveWorkspaceIfPossible() else {
                    refreshLastFocusedLocalWorkingDirectory()
                    notifyStateChanged()
                    return
                }
                refreshLastFocusedLocalWorkingDirectory()
                notifyStateChanged()
                return
            }

            if let removedPane = workspace.paneStripState.closeFocusedPane(singleColumnWidth: layoutContext.singlePaneWidth) {
                workspace.metadataByPaneID.removeValue(forKey: removedPane.id)
                workspace.paneContextByPaneID.removeValue(forKey: removedPane.id)
                workspace.agentStatusByPaneID.removeValue(forKey: removedPane.id)
                workspace.inferredArtifactByPaneID.removeValue(forKey: removedPane.id)
            }
        case .focusLeft:
            workspace.paneStripState.moveFocusLeft()
        case .focusRight:
            workspace.paneStripState.moveFocusRight()
        case .focusUp:
            workspace.paneStripState.moveFocusUp()
        case .focusDown:
            workspace.paneStripState.moveFocusDown()
        case .focusFirst, .focusFirstColumn:
            workspace.paneStripState.moveFocusToFirstColumn()
        case .focusLast, .focusLastColumn:
            workspace.paneStripState.moveFocusToLastColumn()
        }

        activeWorkspace = workspace
        refreshLastFocusedLocalWorkingDirectory()
        notifyStateChanged()
    }

    private func insertNewPaneHorizontally(into workspace: inout WorkspaceState, placement: PanePlacement) {
        let existingColumnCount = workspace.paneStripState.columns.count
        let sourceWidth = workspace.paneStripState.focusedColumn?.width
            ?? workspace.paneStripState.panes.first?.width
            ?? layoutContext.singlePaneWidth
        var insertedPane = makePane(in: &workspace, existingPaneCount: existingColumnCount)
        insertedPane.width = sourceWidth

        if existingColumnCount == 1, let firstPaneWidth = layoutContext.firstPaneWidthAfterSingleSplit {
            workspace.paneStripState.resizeFirstColumn(to: firstPaneWidth)
        }

        workspace.paneStripState.insertPaneHorizontally(insertedPane, placement: placement)
    }

    private func insertNewPaneVertically(into workspace: inout WorkspaceState) {
        let existingPaneCount = workspace.paneStripState.panes.count
        let sourceWidth = workspace.paneStripState.focusedColumn?.width
            ?? workspace.paneStripState.panes.first?.width
            ?? layoutContext.singlePaneWidth
        var insertedPane = makePane(in: &workspace, existingPaneCount: existingPaneCount)
        insertedPane.width = sourceWidth
        _ = workspace.paneStripState.insertPaneVertically(
            insertedPane,
            availableHeight: paneViewportHeight
        )
    }

    func selectWorkspace(id: WorkspaceID) {
        guard workspaces.contains(where: { $0.id == id }) else {
            return
        }

        activeWorkspaceID = id
        refreshLastFocusedLocalWorkingDirectory()
        notifyStateChanged()
    }

    func createWorkspace() {
        let newIndex = workspaces.count + 1
        let title = "WS \(newIndex)"
        let id = WorkspaceID("workspace-\(newIndex)")
        let workingDirectory = lastFocusedLocalWorkingDirectory ?? Self.defaultWorkingDirectory()

        workspaces.append(
            Self.makeDefaultWorkspace(
                id: id,
                title: title,
                layoutContext: layoutContext,
                workingDirectory: workingDirectory
            )
        )
        activeWorkspaceID = id
        refreshLastFocusedLocalWorkingDirectory()
        notifyStateChanged()
    }

    func focusPane(id: PaneID) {
        guard var workspace = activeWorkspace else {
            return
        }

        workspace.paneStripState.focusPane(id: id)
        activeWorkspace = workspace
        refreshLastFocusedLocalWorkingDirectory()
        notifyStateChanged()
    }

    func updateMetadata(paneID: PaneID, metadata: TerminalMetadata) {
        guard let workspaceIndex = workspaces.firstIndex(where: { workspace in
            workspace.paneStripState.panes.contains(where: { $0.id == paneID })
        }) else {
            return
        }

        var workspace = workspaces[workspaceIndex]
        workspace.metadataByPaneID[paneID] = metadata
        if
            let existingStatus = workspace.agentStatusByPaneID[paneID],
            existingStatus.source == .inferred,
            AgentToolRecognizer.recognize(metadata: metadata) == nil
        {
            workspace.agentStatusByPaneID.removeValue(forKey: paneID)
            workspace.inferredArtifactByPaneID.removeValue(forKey: paneID)
        }
        workspaces[workspaceIndex] = workspace
        refreshLastFocusedLocalWorkingDirectoryIfNeeded(workspace: workspace, paneID: paneID)
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
                source: .inferred,
                origin: .inferred,
                interactionState: .none,
                shellActivityState: existingStatus?.shellActivityState ?? .unknown,
                trackedPID: nil
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
            workspace.inferredArtifactByPaneID.removeValue(forKey: payload.paneID)
            workspaces[workspaceIndex] = workspace
            notifyStateChanged()
            return
        }

        if payload.clearsPaneContext {
            workspace.paneContextByPaneID.removeValue(forKey: payload.paneID)
            workspaces[workspaceIndex] = workspace
            refreshLastFocusedLocalWorkingDirectoryIfNeeded(workspace: workspace, paneID: payload.paneID)
            notifyStateChanged()
            return
        }

        let existingStatus = workspace.agentStatusByPaneID[payload.paneID]
        let tool = AgentTool.resolve(named: payload.toolName)
            ?? existingStatus?.tool
            ?? AgentToolRecognizer.recognize(metadata: workspace.metadataByPaneID[payload.paneID])

        switch payload.signalKind {
        case .lifecycle:
            guard payload.state != nil, let tool else {
                return
            }
            guard shouldApplyLifecycleSignal(payload, over: existingStatus) else {
                return
            }

            workspace.agentStatusByPaneID[payload.paneID] = Self.makeLifecycleStatus(
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
                        existingStatus.state = .running
                    case .promptIdle:
                        workspace.agentStatusByPaneID.removeValue(forKey: payload.paneID)
                        workspaces[workspaceIndex] = workspace
                        notifyStateChanged()
                        return
                    case .unknown:
                        break
                    }
                }

                workspace.agentStatusByPaneID[payload.paneID] = existingStatus
            } else if shellActivityState == .commandRunning, let tool {
                workspace.agentStatusByPaneID[payload.paneID] = PaneAgentStatus(
                    tool: tool,
                    state: .running,
                    text: nil,
                    artifactLink: nil,
                    updatedAt: Date(),
                    source: .inferred,
                    origin: .shell,
                    interactionState: .none,
                    shellActivityState: shellActivityState
                )
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
                            state: ($0.state == .completed || $0.state == .unresolvedStop) ? .running : $0.state,
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
                        state: .running,
                        text: nil,
                        artifactLink: nil,
                        updatedAt: Date(),
                        source: .explicit,
                        origin: payload.origin,
                        interactionState: .none
                    )
                status.trackedPID = pid
                status.updatedAt = Date()
                workspace.agentStatusByPaneID[payload.paneID] = status
            case .clear:
                guard var status = existingStatus else {
                    return
                }
                status.trackedPID = nil
                status.updatedAt = Date()
                workspace.agentStatusByPaneID[payload.paneID] = status
            }
        case .paneContext:
            guard let paneContext = payload.paneContext else {
                return
            }

            workspace.paneContextByPaneID[payload.paneID] = paneContext
        }

        workspaces[workspaceIndex] = workspace
        refreshLastFocusedLocalWorkingDirectoryIfNeeded(workspace: workspace, paneID: payload.paneID)
        notifyStateChanged()
    }

    func clearStaleAgentSessions() {
        var didChange = false

        for workspaceIndex in workspaces.indices {
            var workspace = workspaces[workspaceIndex]

            for (paneID, status) in workspace.agentStatusByPaneID {
                guard let trackedPID = status.trackedPID, !Self.isProcessAlive(pid: trackedPID) else {
                    continue
                }

                didChange = true
                if status.state == .running || status.requiresHumanAttention {
                    workspace.agentStatusByPaneID.removeValue(forKey: paneID)
                    workspace.inferredArtifactByPaneID.removeValue(forKey: paneID)
                } else {
                    var nextStatus = status
                    nextStatus.trackedPID = nil
                    workspace.agentStatusByPaneID[paneID] = nextStatus
                }
            }

            workspaces[workspaceIndex] = workspace
        }

        if didChange {
            notifyStateChanged()
        }
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

    func closePane(id: PaneID) {
        guard var workspace = activeWorkspace else {
            return
        }

        workspace.paneStripState.focusPane(id: id)
        if workspace.paneStripState.columns.count == 1,
           workspace.paneStripState.panes.count == 1 {
            guard removeActiveWorkspaceIfPossible() else {
                refreshLastFocusedLocalWorkingDirectory()
                notifyStateChanged()
                return
            }
            refreshLastFocusedLocalWorkingDirectory()
            notifyStateChanged()
            return
        }

        if let removedPane = workspace.paneStripState.closeFocusedPane(singleColumnWidth: layoutContext.singlePaneWidth) {
            workspace.metadataByPaneID.removeValue(forKey: removedPane.id)
            workspace.paneContextByPaneID.removeValue(forKey: removedPane.id)
            workspace.agentStatusByPaneID.removeValue(forKey: removedPane.id)
            workspace.inferredArtifactByPaneID.removeValue(forKey: removedPane.id)
        }

        activeWorkspace = workspace
        refreshLastFocusedLocalWorkingDirectory()
        notifyStateChanged()
    }

    func updateMetadata(id: PaneID, metadata: TerminalMetadata) {
        updateMetadata(paneID: id, metadata: metadata)
    }

    private func makePane(in workspace: inout WorkspaceState, existingPaneCount: Int) -> PaneState {
        defer {
            workspace.nextPaneNumber += 1
        }

        let title = "pane \(workspace.nextPaneNumber)"
        let paneID = PaneID("\(workspace.id.rawValue)-pane-\(workspace.nextPaneNumber)")
        let workingDirectory = resolveWorkingDirectoryForNewPane(in: workspace)
        let inheritFromPaneID = sourcePaneIDForSessionInheritance(in: workspace)
        return PaneState(
            id: paneID,
            title: title,
            sessionRequest: TerminalSessionRequest(
                workingDirectory: workingDirectory,
                inheritFromPaneID: inheritFromPaneID,
                environmentVariables: Self.sessionEnvironment(
                    workspaceID: workspace.id,
                    paneID: paneID
                )
            ),
            width: layoutContext.newPaneWidth(existingPaneCount: existingPaneCount)
        )
    }

    private static func defaultWorkspaces(layoutContext: PaneLayoutContext) -> [WorkspaceState] {
        [
            makeDefaultWorkspace(
                id: WorkspaceID("workspace-main"),
                title: "MAIN",
                layoutContext: layoutContext,
                workingDirectory: Self.defaultWorkingDirectory()
            ),
        ]
    }

    private static func makeDefaultWorkspace(
        id: WorkspaceID,
        title: String,
        layoutContext: PaneLayoutContext,
        workingDirectory: String
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
                            workingDirectory: workingDirectory,
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
        if let agentSignalCommand = AgentStatusHelper.agentSignalCommand() {
            environment["ZENTTY_AGENT_SIGNAL_COMMAND"] = agentSignalCommand
        }
        if let claudeHookCommand = AgentStatusHelper.claudeHookCommand() {
            environment["ZENTTY_CLAUDE_HOOK_COMMAND"] = claudeHookCommand
        }
        if let wrapperBinPath = AgentStatusHelper.wrapperBinPath() {
            environment["ZENTTY_WRAPPER_BIN_DIR"] = wrapperBinPath
            let currentPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
            environment["PATH"] = "\(wrapperBinPath):\(currentPath)"
        }
        if let shellIntegrationDirectory = AgentStatusHelper.shellIntegrationDirectoryPath() {
            environment["ZENTTY_SHELL_INTEGRATION_DIR"] = shellIntegrationDirectory
            environment["ZENTTY_SHELL_INTEGRATION"] = "1"
            environment["ZDOTDIR"] = shellIntegrationDirectory
            if let currentZDOTDIR = ProcessInfo.processInfo.environment["ZDOTDIR"], !currentZDOTDIR.isEmpty {
                environment["ZENTTY_ORIGINAL_ZDOTDIR"] = currentZDOTDIR
            }
            if let currentPromptCommand = ProcessInfo.processInfo.environment["PROMPT_COMMAND"], !currentPromptCommand.isEmpty {
                environment["ZENTTY_BASH_ORIGINAL_PROMPT_COMMAND"] = currentPromptCommand
            }
            environment["PROMPT_COMMAND"] = ". \"\(shellIntegrationDirectory)/zentty-bash-integration.bash\""
        }
        return environment
    }

    private func resolveWorkingDirectoryForNewPane(in workspace: WorkspaceState) -> String {
        guard let focusedPaneID = workspace.paneStripState.focusedPaneID else {
            return lastFocusedLocalWorkingDirectory ?? Self.defaultWorkingDirectory()
        }

        return resolveLaunchContext(for: focusedPaneID, in: workspace)?.path
            ?? lastFocusedLocalWorkingDirectory
            ?? Self.defaultWorkingDirectory()
    }

    private func sourcePaneIDForSessionInheritance(in workspace: WorkspaceState) -> PaneID? {
        guard let focusedPaneID = workspace.paneStripState.focusedPaneID else {
            return nil
        }

        if let paneContext = workspace.paneContextByPaneID[focusedPaneID] {
            return paneContext.scope == .remote ? focusedPaneID : nil
        }

        guard let pane = pane(for: focusedPaneID, in: workspace) else {
            return nil
        }

        return pane.sessionRequest.inheritFromPaneID == nil ? nil : focusedPaneID
    }

    private func resolveLaunchContext(
        for paneID: PaneID,
        in workspace: WorkspaceState
    ) -> PaneLaunchContext? {
        let metadataWorkingDirectory = Self.trimmedWorkingDirectory(
            workspace.metadataByPaneID[paneID]?.currentWorkingDirectory
        )
        let paneContext = workspace.paneContextByPaneID[paneID]
        let requestWorkingDirectory = pane(for: paneID, in: workspace).flatMap {
            Self.trimmedWorkingDirectory($0.sessionRequest.workingDirectory)
        }

        if let paneContext {
            return (metadataWorkingDirectory ?? Self.trimmedWorkingDirectory(paneContext.path) ?? requestWorkingDirectory)
                .map { PaneLaunchContext(path: $0, scope: paneContext.scope) }
        }

        return (metadataWorkingDirectory ?? requestWorkingDirectory)
            .map { PaneLaunchContext(path: $0, scope: nil) }
    }

    private func refreshLastFocusedLocalWorkingDirectory() {
        guard
            let workspace = activeWorkspace,
            let focusedPaneID = workspace.paneStripState.focusedPaneID
        else {
            return
        }

        updateLastFocusedLocalWorkingDirectory(using: focusedPaneID, in: workspace)
    }

    private func refreshLastFocusedLocalWorkingDirectoryIfNeeded(
        workspace: WorkspaceState,
        paneID: PaneID
    ) {
        guard workspace.id == activeWorkspaceID, workspace.paneStripState.focusedPaneID == paneID else {
            return
        }

        updateLastFocusedLocalWorkingDirectory(using: paneID, in: workspace)
    }

    private func updateLastFocusedLocalWorkingDirectory(
        using paneID: PaneID,
        in workspace: WorkspaceState
    ) {
        if let paneContext = workspace.paneContextByPaneID[paneID] {
            guard paneContext.scope == .local else {
                return
            }

            lastFocusedLocalWorkingDirectory = Self.trimmedWorkingDirectory(
                workspace.metadataByPaneID[paneID]?.currentWorkingDirectory
            ) ?? Self.trimmedWorkingDirectory(paneContext.path)
                ?? nonInheritedSessionWorkingDirectory(for: paneID, in: workspace)
            return
        }

        if let nonInheritedSessionWorkingDirectory = nonInheritedSessionWorkingDirectory(for: paneID, in: workspace) {
            lastFocusedLocalWorkingDirectory = nonInheritedSessionWorkingDirectory
        }
    }

    private func nonInheritedSessionWorkingDirectory(
        for paneID: PaneID,
        in workspace: WorkspaceState
    ) -> String? {
        guard let pane = pane(for: paneID, in: workspace),
              pane.sessionRequest.inheritFromPaneID == nil else {
            return nil
        }

        return Self.trimmedWorkingDirectory(pane.sessionRequest.workingDirectory)
    }

    private func pane(for paneID: PaneID, in workspace: WorkspaceState) -> PaneState? {
        workspace.paneStripState.panes.first { $0.id == paneID }
    }

    private static func defaultWorkingDirectory() -> String {
        NSHomeDirectory()
    }

    private static func trimmedWorkingDirectory(_ workingDirectory: String?) -> String? {
        guard let workingDirectory = workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines),
              !workingDirectory.isEmpty else {
            return nil
        }

        return workingDirectory
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

    private static func isProcessAlive(pid: Int32) -> Bool {
        guard pid > 0 else {
            return false
        }

        if kill(pid, 0) == 0 {
            return true
        }

        return errno == EPERM
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
