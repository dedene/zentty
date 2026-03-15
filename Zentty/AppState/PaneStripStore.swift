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

    init(
        id: WorkspaceID,
        title: String,
        paneStripState: PaneStripState,
        nextPaneNumber: Int = 1,
        metadataByPaneID: [PaneID: TerminalMetadata] = [:]
    ) {
        self.id = id
        self.title = title
        self.paneStripState = paneStripState
        self.nextPaneNumber = nextPaneNumber
        self.metadataByPaneID = metadataByPaneID
    }
}

final class WorkspaceStore {
    private(set) var workspaces: [WorkspaceState]

    private(set) var activeWorkspaceID: WorkspaceID

    var onChange: ((PaneStripState) -> Void)?

    init(
        workspaces: [WorkspaceState] = WorkspaceStore.defaultWorkspaces(),
        activeWorkspaceID: WorkspaceID? = nil
    ) {
        let initialWorkspaces = workspaces.isEmpty ? WorkspaceStore.defaultWorkspaces() : workspaces
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

            if let removedPane = workspace.paneStripState.closeFocusedPane() {
                workspace.metadataByPaneID.removeValue(forKey: removedPane.id)
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
        let shellPaneID = PaneID("\(id.rawValue)-shell")

        workspaces.append(
            WorkspaceState(
                id: id,
                title: title,
                paneStripState: PaneStripState(
                    panes: [PaneState(id: shellPaneID, title: "shell")],
                    focusedPaneID: shellPaneID
                )
            )
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
        workspace.metadataByPaneID[paneID] = metadata
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

        if let removedPane = workspace.paneStripState.closeFocusedPane() {
            workspace.metadataByPaneID.removeValue(forKey: removedPane.id)
        }

        activeWorkspace = workspace
        notifyStateChanged()
    }

    func updateMetadata(id: PaneID, metadata: TerminalMetadata) {
        updateMetadata(paneID: id, metadata: metadata)
    }

    private func makePane(in workspace: inout WorkspaceState) -> PaneState {
        defer {
            workspace.nextPaneNumber += 1
        }

        let title = "pane \(workspace.nextPaneNumber)"
        let focusedPaneID = workspace.paneStripState.focusedPaneID
        let workingDirectory = focusedPaneID.flatMap {
            workspace.metadataByPaneID[$0]?.currentWorkingDirectory
        }
        return PaneState(
            id: PaneID("\(workspace.id.rawValue)-pane-\(workspace.nextPaneNumber)"),
            title: title,
            sessionRequest: TerminalSessionRequest(
                workingDirectory: workingDirectory,
                inheritFromPaneID: focusedPaneID
            )
        )
    }

    private static func defaultWorkspaces() -> [WorkspaceState] {
        [
            makeDefaultWorkspace(id: WorkspaceID("workspace-main"), title: "MAIN"),
        ]
    }

    private static func makeDefaultWorkspace(id: WorkspaceID, title: String) -> WorkspaceState {
        let shellPaneID = PaneID("\(id.rawValue)-shell")
        return WorkspaceState(
            id: id,
            title: title,
            paneStripState: PaneStripState(
                panes: [PaneState(id: shellPaneID, title: "shell")],
                focusedPaneID: shellPaneID
            )
        )
    }

    private func notifyStateChanged() {
        onChange?(state)
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
