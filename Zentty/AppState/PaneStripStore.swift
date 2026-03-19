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
    var auxiliaryStateByPaneID: [PaneID: PaneAuxiliaryState]

    init(
        id: WorkspaceID,
        title: String,
        paneStripState: PaneStripState,
        nextPaneNumber: Int = 1,
        auxiliaryStateByPaneID: [PaneID: PaneAuxiliaryState] = [:]
    ) {
        self.id = id
        self.title = title
        self.paneStripState = paneStripState
        self.nextPaneNumber = nextPaneNumber
        self.auxiliaryStateByPaneID = auxiliaryStateByPaneID
    }

    /// Convenience init that accepts the old separate dictionaries to ease migration.
    init(
        id: WorkspaceID,
        title: String,
        paneStripState: PaneStripState,
        nextPaneNumber: Int = 1,
        metadataByPaneID: [PaneID: TerminalMetadata] = [:],
        paneContextByPaneID: [PaneID: PaneShellContext] = [:],
        agentStatusByPaneID: [PaneID: PaneAgentStatus] = [:],
        inferredArtifactByPaneID: [PaneID: WorkspaceArtifactLink] = [:],
        reviewStateByPaneID: [PaneID: WorkspaceReviewState] = [:]
    ) {
        self.id = id
        self.title = title
        self.paneStripState = paneStripState
        self.nextPaneNumber = nextPaneNumber

        var aux: [PaneID: PaneAuxiliaryState] = [:]
        let allPaneIDs = Set(metadataByPaneID.keys)
            .union(paneContextByPaneID.keys)
            .union(agentStatusByPaneID.keys)
            .union(inferredArtifactByPaneID.keys)
            .union(reviewStateByPaneID.keys)
        for paneID in allPaneIDs {
            aux[paneID] = PaneAuxiliaryState(
                metadata: metadataByPaneID[paneID],
                shellContext: paneContextByPaneID[paneID],
                agentStatus: agentStatusByPaneID[paneID],
                inferredArtifact: inferredArtifactByPaneID[paneID],
                reviewState: reviewStateByPaneID[paneID]
            )
        }
        self.auxiliaryStateByPaneID = aux
    }
}

struct PaneBorderContextDisplayModel: Equatable, Sendable {
    let text: String
}

extension WorkspaceState {
    var paneBorderContextDisplayByPaneID: [PaneID: PaneBorderContextDisplayModel] {
        auxiliaryStateByPaneID.compactMapValues { $0.shellContext?.displayModel }
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

enum WorkspaceChange: Equatable, Sendable {
    case paneStructure(WorkspaceID)
    case focusChanged(WorkspaceID)
    case layoutResized(WorkspaceID)
    case auxiliaryStateUpdated(WorkspaceID, PaneID)
    case activeWorkspaceChanged
    case workspaceListChanged
}

@MainActor
final class WorkspaceStore {
    private struct PaneLaunchContext {
        let path: String
        let scope: PaneShellContextScope?
    }

    var workspaces: [WorkspaceState]
    private var layoutContext: PaneLayoutContext
    private var paneViewportHeight: CGFloat = .greatestFiniteMagnitude
    private var lastFocusedLocalWorkingDirectory: String?

    private(set) var activeWorkspaceID: WorkspaceID

    var onChange: ((WorkspaceChange) -> Void)?

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
        var didUpdateWorkspaceState = false
        let viewportScaleFactor = Self.viewportScaleFactor(
            from: previousLayoutContext.viewportWidth,
            to: layoutContext.viewportWidth
        )

        for index in workspaces.indices {
            if workspaces[index].paneStripState.updateLayoutSizing(layoutContext.sizing) {
                didUpdateWorkspaceState = true
            }

            if workspaces[index].paneStripState.updateSinglePaneWidth(layoutContext.singlePaneWidth) {
                didUpdateWorkspaceState = true
                continue
            }

            if let viewportScaleFactor,
               workspaces[index].paneStripState.scalePaneWidths(by: viewportScaleFactor) {
                didUpdateWorkspaceState = true
            }
        }

        if didUpdateWorkspaceState {
            notify(.layoutResized(activeWorkspaceID))
        }
    }

    func updatePaneViewportHeight(_ height: CGFloat) {
        paneViewportHeight = max(1, height)
    }

    func send(_ command: PaneCommand) {
        guard var workspace = activeWorkspace else {
            return
        }

        let changeType: WorkspaceChange

        switch command {
        case .split, .splitHorizontally, .splitAfterFocusedPane:
            insertNewPaneHorizontally(into: &workspace, placement: .afterFocused)
            changeType = .paneStructure(activeWorkspaceID)
        case .splitVertically:
            insertNewPaneVertically(into: &workspace)
            changeType = .paneStructure(activeWorkspaceID)
        case .splitBeforeFocusedPane:
            insertNewPaneHorizontally(into: &workspace, placement: .beforeFocused)
            changeType = .paneStructure(activeWorkspaceID)
        case .closeFocusedPane:
            if workspace.paneStripState.columns.count == 1,
               workspace.paneStripState.panes.count == 1 {
                guard removeActiveWorkspaceIfPossible() else {
                    refreshLastFocusedLocalWorkingDirectory()
                    notify(.paneStructure(activeWorkspaceID))
                    return
                }
                refreshLastFocusedLocalWorkingDirectory()
                notify(.workspaceListChanged)
                return
            }

            if let removedPane = workspace.paneStripState.closeFocusedPane(singleColumnWidth: layoutContext.singlePaneWidth) {
                clearPaneState(for: removedPane.id, in: &workspace)
            }
            changeType = .paneStructure(activeWorkspaceID)
        case .focusLeft:
            workspace.paneStripState.moveFocusLeft()
            changeType = .focusChanged(activeWorkspaceID)
        case .focusRight:
            workspace.paneStripState.moveFocusRight()
            changeType = .focusChanged(activeWorkspaceID)
        case .focusUp:
            workspace.paneStripState.moveFocusUp()
            changeType = .focusChanged(activeWorkspaceID)
        case .focusDown:
            workspace.paneStripState.moveFocusDown()
            changeType = .focusChanged(activeWorkspaceID)
        case .focusFirst, .focusFirstColumn:
            workspace.paneStripState.moveFocusToFirstColumn()
            changeType = .focusChanged(activeWorkspaceID)
        case .focusLast, .focusLastColumn:
            workspace.paneStripState.moveFocusToLastColumn()
            changeType = .focusChanged(activeWorkspaceID)
        }

        activeWorkspace = workspace
        refreshLastFocusedLocalWorkingDirectory()
        notify(changeType)
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
        notify(.activeWorkspaceChanged)
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
        notify(.workspaceListChanged)
    }

    func focusPane(id: PaneID) {
        guard var workspace = activeWorkspace else {
            return
        }

        workspace.paneStripState.focusPane(id: id)
        activeWorkspace = workspace
        refreshLastFocusedLocalWorkingDirectory()
        notify(.focusChanged(activeWorkspaceID))
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
                notify(.paneStructure(activeWorkspaceID))
                return
            }
            refreshLastFocusedLocalWorkingDirectory()
            notify(.workspaceListChanged)
            return
        }

        if let removedPane = workspace.paneStripState.closeFocusedPane(singleColumnWidth: layoutContext.singlePaneWidth) {
            clearPaneState(for: removedPane.id, in: &workspace)
        }

        activeWorkspace = workspace
        refreshLastFocusedLocalWorkingDirectory()
        notify(.paneStructure(activeWorkspaceID))
    }

    func replaceWorkspacesForTesting(_ workspaces: [WorkspaceState], activeWorkspaceID: WorkspaceID? = nil) {
        self.workspaces = workspaces
        let fallbackID = activeWorkspaceID ?? workspaces.first?.id ?? WorkspaceID("workspace-main")
        self.activeWorkspaceID = workspaces.contains(where: { $0.id == fallbackID })
            ? fallbackID
            : workspaces.first?.id ?? WorkspaceID("workspace-main")
        notify(.workspaceListChanged)
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
                focusedPaneID: shellPaneID,
                layoutSizing: layoutContext.sizing
            )
        )
    }

    func notify(_ change: WorkspaceChange) {
        onChange?(change)
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

        if let paneContext = workspace.auxiliaryStateByPaneID[focusedPaneID]?.shellContext {
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
            workspace.auxiliaryStateByPaneID[paneID]?.metadata?.currentWorkingDirectory
        )
        let paneContext = workspace.auxiliaryStateByPaneID[paneID]?.shellContext
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

    func refreshLastFocusedLocalWorkingDirectoryIfNeeded(
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
        if let paneContext = workspace.auxiliaryStateByPaneID[paneID]?.shellContext {
            guard paneContext.scope == .local else {
                return
            }

            lastFocusedLocalWorkingDirectory = Self.trimmedWorkingDirectory(
                workspace.auxiliaryStateByPaneID[paneID]?.metadata?.currentWorkingDirectory
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
