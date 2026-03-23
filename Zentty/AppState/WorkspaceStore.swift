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


}

struct WorkspacePaneContext: Equatable, Sendable {
    let pane: PaneState
    let auxiliaryState: PaneAuxiliaryState?

    var paneID: PaneID { pane.id }
    var metadata: TerminalMetadata? { auxiliaryState?.metadata }
}

struct PaneBorderContextDisplayModel: Equatable, Sendable {
    let text: String
}

extension WorkspaceState {
    var focusedPaneContext: WorkspacePaneContext? {
        paneContext(for: paneStripState.focusedPaneID)
    }

    var paneContextsPrioritizingFocus: [WorkspacePaneContext] {
        let panes = paneStripState.panes
        guard
            let focusedPaneID = paneStripState.focusedPaneID,
            let focusedPaneIndex = panes.firstIndex(where: { $0.id == focusedPaneID })
        else {
            return panes.map { WorkspacePaneContext(pane: $0, auxiliaryState: auxiliaryStateByPaneID[$0.id]) }
        }

        var orderedPanes = panes
        if focusedPaneIndex != 0 {
            let focusedPane = orderedPanes.remove(at: focusedPaneIndex)
            orderedPanes.insert(focusedPane, at: 0)
        }

        return orderedPanes.map { WorkspacePaneContext(pane: $0, auxiliaryState: auxiliaryStateByPaneID[$0.id]) }
    }

    func paneContext(for paneID: PaneID?) -> WorkspacePaneContext? {
        guard
            let paneID,
            let pane = paneStripState.panes.first(where: { $0.id == paneID })
        else {
            return nil
        }

        return WorkspacePaneContext(pane: pane, auxiliaryState: auxiliaryStateByPaneID[paneID])
    }

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

struct WorkspaceChangeSubscription {
    fileprivate let id: UUID
    fileprivate static let legacyID = UUID()
}

@MainActor
final class WorkspaceStore {
    private struct PaneReference {
        let workspaceID: WorkspaceID
        let paneID: PaneID
    }

    private struct PaneLaunchContext {
        let path: String
        let scope: PaneShellContextScope?
    }

    var workspaces: [WorkspaceState]
    private var layoutContext: PaneLayoutContext
    private var paneViewportHeight: CGFloat = .greatestFiniteMagnitude
    private var lastFocusedPaneReference: PaneReference?
    private var lastFocusedLocalPaneReference: PaneReference?
    private var lastFocusedLocalWorkingDirectory: String?

    private(set) var activeWorkspaceID: WorkspaceID

    private var subscribers: [(id: UUID, handler: (WorkspaceChange) -> Void)] = []
    private var isBatching = false

    @discardableResult
    func subscribe(_ handler: @escaping (WorkspaceChange) -> Void) -> WorkspaceChangeSubscription {
        let id = UUID()
        subscribers.append((id: id, handler: handler))
        return WorkspaceChangeSubscription(id: id)
    }

    func unsubscribe(_ subscription: WorkspaceChangeSubscription) {
        subscribers.removeAll { $0.id == subscription.id }
    }

    /// Deprecated compatibility shim — use subscribe() for new code.
    var onChange: ((WorkspaceChange) -> Void)? {
        get { nil }
        set {
            subscribers.removeAll { $0.id == WorkspaceChangeSubscription.legacyID }
            if let handler = newValue {
                subscribers.append((id: WorkspaceChangeSubscription.legacyID, handler: handler))
            }
        }
    }

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
        case .resizeLeft, .resizeRight, .resizeUp, .resizeDown, .resetLayout:
            activeWorkspace = workspace
            return
        }

        activeWorkspace = workspace
        refreshLastFocusedLocalWorkingDirectory()
        notify(changeType)
    }

    func markDividerInteraction(_ divider: PaneDivider) {
        guard var workspace = activeWorkspace else {
            return
        }

        workspace.paneStripState.markDividerInteraction(divider)
        activeWorkspace = workspace
    }

    func resizeDivider(
        _ divider: PaneDivider,
        delta: CGFloat,
        availableSize: CGSize,
        minimumSizeByPaneID: [PaneID: PaneMinimumSize]
    ) {
        guard var workspace = activeWorkspace else {
            return
        }

        guard workspace.paneStripState.resizeDivider(
            divider,
            delta: delta,
            availableSize: availableSize,
            minimumSizeByPaneID: minimumSizeByPaneID
        ) else {
            return
        }

        activeWorkspace = workspace
        notify(.layoutResized(activeWorkspaceID))
    }

    func resize(
        _ target: PaneResizeTarget,
        delta: CGFloat,
        availableSize: CGSize,
        minimumSizeByPaneID: [PaneID: PaneMinimumSize]
    ) {
        guard var workspace = activeWorkspace else {
            return
        }

        guard workspace.paneStripState.resize(
            target,
            delta: delta,
            availableSize: availableSize,
            minimumSizeByPaneID: minimumSizeByPaneID
        ) else {
            return
        }

        activeWorkspace = workspace
        notify(.layoutResized(activeWorkspaceID))
    }

    func equalizeDivider(
        _ divider: PaneDivider,
        availableSize: CGSize
    ) {
        guard var workspace = activeWorkspace else {
            return
        }

        guard workspace.paneStripState.equalizeDivider(divider, availableSize: availableSize) else {
            return
        }

        activeWorkspace = workspace
        notify(.layoutResized(activeWorkspaceID))
    }

    func resizeFocusedPane(
        in axis: PaneResizeAxis,
        delta: CGFloat,
        availableSize: CGSize,
        minimumSizeByPaneID: [PaneID: PaneMinimumSize]
    ) {
        guard var workspace = activeWorkspace else {
            return
        }

        guard workspace.paneStripState.resizeFocusedPane(
            in: axis,
            delta: delta,
            availableSize: availableSize,
            minimumSizeByPaneID: minimumSizeByPaneID
        ) else {
            return
        }

        activeWorkspace = workspace
        notify(.layoutResized(activeWorkspaceID))
    }

    func restorePaneLayout(_ paneStripState: PaneStripState) {
        guard var workspace = activeWorkspace else {
            return
        }

        workspace.paneStripState = paneStripState
        activeWorkspace = workspace
        notify(.layoutResized(activeWorkspaceID))
    }

    func resetActiveWorkspaceLayout() {
        guard var workspace = activeWorkspace else {
            return
        }

        var columns = workspace.paneStripState.columns
        guard !columns.isEmpty else {
            return
        }

        let defaultColumnWidth = layoutContext.newPaneWidth
        let firstColumnWidth = columns.count == 1
            ? layoutContext.singlePaneWidth
            : (layoutContext.firstPaneWidthAfterSingleSplit ?? defaultColumnWidth)
        for index in columns.indices {
            columns[index].width = index == 0 ? firstColumnWidth : defaultColumnWidth
            columns[index].resetPaneHeights()
        }

        workspace.paneStripState = PaneStripState(
            columns: columns,
            focusedColumnID: workspace.paneStripState.focusedColumnID,
            layoutSizing: layoutContext.sizing
        )
        activeWorkspace = workspace
        notify(.layoutResized(activeWorkspaceID))
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
        let workingDirectory = resolveWorkingDirectoryForNewWorkspace()
        let configInheritanceSourcePaneID = resolveConfigInheritanceSourcePaneIDForNewWorkspace()

        workspaces.append(
            Self.makeDefaultWorkspace(
                id: id,
                title: title,
                layoutContext: layoutContext,
                workingDirectory: workingDirectory,
                surfaceContext: .tab,
                configInheritanceSourcePaneID: configInheritanceSourcePaneID
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

    #if DEBUG
    func replaceWorkspaces(_ workspaces: [WorkspaceState], activeWorkspaceID: WorkspaceID? = nil) {
        self.workspaces = workspaces
        let fallbackID = activeWorkspaceID ?? workspaces.first?.id ?? WorkspaceID("workspace-main")
        self.activeWorkspaceID = workspaces.contains(where: { $0.id == fallbackID })
            ? fallbackID
            : workspaces.first?.id ?? WorkspaceID("workspace-main")
        notify(.workspaceListChanged)
    }
    #endif

    private func makePane(in workspace: inout WorkspaceState, existingPaneCount: Int) -> PaneState {
        defer {
            workspace.nextPaneNumber += 1
        }

        let title = "pane \(workspace.nextPaneNumber)"
        let paneID = PaneID("\(workspace.id.rawValue)-pane-\(workspace.nextPaneNumber)")
        let workingDirectory = resolveWorkingDirectoryForNewPane(in: workspace)
        let inheritFromPaneID = sourcePaneIDForSessionInheritance(in: workspace)
        let configInheritanceSourcePaneID = sourcePaneIDForConfigInheritance(in: workspace)
        return PaneState(
            id: paneID,
            title: title,
            sessionRequest: TerminalSessionRequest(
                workingDirectory: workingDirectory,
                inheritFromPaneID: inheritFromPaneID,
                configInheritanceSourcePaneID: configInheritanceSourcePaneID,
                surfaceContext: .split,
                environmentVariables: Self.sessionEnvironment(
                    workspaceID: workspace.id,
                    paneID: paneID,
                    initialWorkingDirectory: inheritFromPaneID == nil ? workingDirectory : nil
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
                workingDirectory: Self.defaultWorkingDirectory(),
                surfaceContext: .window
            ),
        ]
    }

    private static func makeDefaultWorkspace(
        id: WorkspaceID,
        title: String,
        layoutContext: PaneLayoutContext,
        workingDirectory: String,
        surfaceContext: TerminalSurfaceContext,
        configInheritanceSourcePaneID: PaneID? = nil
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
                            configInheritanceSourcePaneID: configInheritanceSourcePaneID,
                            surfaceContext: surfaceContext,
                            environmentVariables: Self.sessionEnvironment(
                                workspaceID: id,
                                paneID: shellPaneID,
                                initialWorkingDirectory: workingDirectory
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

    func batchUpdate(_ body: () -> Void) {
        isBatching = true
        body()
        isBatching = false
    }

    /// Internal — called by WorkspaceStore extension files to dispatch change notifications.
    /// Not intended for use outside WorkspaceStore and its extensions.
    func notify(_ change: WorkspaceChange) {
        guard !isBatching else { return }
        for subscriber in subscribers {
            subscriber.handler(change)
        }
    }

    private static func sessionEnvironment(
        workspaceID: WorkspaceID,
        paneID: PaneID,
        initialWorkingDirectory: String? = nil
    ) -> [String: String] {
        var environment: [String: String] = [
            "ZENTTY_WORKSPACE_ID": workspaceID.rawValue,
            "ZENTTY_PANE_ID": paneID.rawValue,
        ]
        if let initialWorkingDirectory = trimmedWorkingDirectory(initialWorkingDirectory) {
            environment["ZENTTY_INITIAL_WORKING_DIRECTORY"] = initialWorkingDirectory
        }
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

    private func sourcePaneIDForConfigInheritance(in workspace: WorkspaceState) -> PaneID? {
        guard let focusedPaneID = workspace.paneStripState.focusedPaneID,
              pane(for: focusedPaneID, in: workspace) != nil else {
            return nil
        }

        return focusedPaneID
    }

    private func resolveLaunchContext(
        for paneID: PaneID,
        in workspace: WorkspaceState
    ) -> PaneLaunchContext? {
        let paneContext = workspace.auxiliaryStateByPaneID[paneID]?.shellContext
        let metadataWorkingDirectory = Self.trimmedWorkingDirectory(
            workspace.auxiliaryStateByPaneID[paneID]?.metadata?.currentWorkingDirectory
        )
        let requestWorkingDirectory = nonInheritedSessionWorkingDirectory(for: paneID, in: workspace)

        if let paneContext {
            return resolvedWorkingDirectory(
                metadataWorkingDirectory: metadataWorkingDirectory,
                paneContext: paneContext,
                requestWorkingDirectory: requestWorkingDirectory
            )
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
            lastFocusedPaneReference = nil
            return
        }

        lastFocusedPaneReference = PaneReference(workspaceID: workspace.id, paneID: focusedPaneID)
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

            let metadataWorkingDirectory = Self.trimmedWorkingDirectory(
                workspace.auxiliaryStateByPaneID[paneID]?.metadata?.currentWorkingDirectory
            )
            let requestWorkingDirectory = nonInheritedSessionWorkingDirectory(for: paneID, in: workspace)
            lastFocusedLocalPaneReference = PaneReference(workspaceID: workspace.id, paneID: paneID)
            lastFocusedLocalWorkingDirectory = resolvedWorkingDirectory(
                metadataWorkingDirectory: metadataWorkingDirectory,
                paneContext: paneContext,
                requestWorkingDirectory: requestWorkingDirectory
            )
            return
        }

        if let nonInheritedSessionWorkingDirectory = nonInheritedSessionWorkingDirectory(for: paneID, in: workspace) {
            lastFocusedLocalPaneReference = PaneReference(workspaceID: workspace.id, paneID: paneID)
            lastFocusedLocalWorkingDirectory = nonInheritedSessionWorkingDirectory
        }
    }

    private func resolveWorkingDirectoryForNewWorkspace() -> String {
        if let lastFocusedPaneReference,
           let workspace = workspaces.first(where: { $0.id == lastFocusedPaneReference.workspaceID }),
           let launchContext = resolveLaunchContext(for: lastFocusedPaneReference.paneID, in: workspace),
           launchContext.scope != .remote {
            return launchContext.path
        }

        return lastFocusedLocalWorkingDirectory ?? Self.defaultWorkingDirectory()
    }

    private func resolveConfigInheritanceSourcePaneIDForNewWorkspace() -> PaneID? {
        guard let lastFocusedLocalPaneReference,
              let workspace = workspaces.first(where: { $0.id == lastFocusedLocalPaneReference.workspaceID }),
              pane(for: lastFocusedLocalPaneReference.paneID, in: workspace) != nil else {
            return nil
        }

        return lastFocusedLocalPaneReference.paneID
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

    private func resolvedWorkingDirectory(
        metadataWorkingDirectory: String?,
        paneContext: PaneShellContext,
        requestWorkingDirectory: String?
    ) -> String? {
        let contextWorkingDirectory = Self.trimmedWorkingDirectory(paneContext.path)

        if paneContext.scope == .local,
           metadataWorkingDirectory == requestWorkingDirectory,
           let contextWorkingDirectory {
            return contextWorkingDirectory
        }

        return metadataWorkingDirectory ?? contextWorkingDirectory ?? requestWorkingDirectory
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
