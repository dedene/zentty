final class PaneStripStore {
    private(set) var state: PaneStripState {
        didSet {
            onChange?(state)
        }
    }

    var onChange: ((PaneStripState) -> Void)?

    private var nextPaneNumber: Int
    private var metadataByPaneID: [PaneID: TerminalMetadata] = [:]

    init(state: PaneStripState = .pocDefault) {
        self.state = state
        self.nextPaneNumber = 1
    }

    func send(_ command: PaneCommand) {
        switch command {
        case .split:
            state.insertPane(makePane(), placement: .afterFocused)
        case .closeFocusedPane:
            guard state.panes.count > 1 else {
                return
            }

            if let removedPane = state.closeFocusedPane() {
                metadataByPaneID.removeValue(forKey: removedPane.id)
            }
        case .focusLeft:
            state.moveFocusLeft()
        case .focusRight:
            state.moveFocusRight()
        case .focusFirst:
            state.moveFocusToFirst()
        case .focusLast:
            state.moveFocusToLast()
        }
    }

    func focusPane(id: PaneID) {
        state.focusPane(id: id)
    }

    func updateMetadata(id: PaneID, metadata: TerminalMetadata) {
        metadataByPaneID[id] = metadata
    }

    private func makePane() -> PaneState {
        defer {
            nextPaneNumber += 1
        }

        let title = "pane \(nextPaneNumber)"
        let workingDirectory = state.focusedPaneID.flatMap { metadataByPaneID[$0]?.currentWorkingDirectory }
        return PaneState(
            id: PaneID("pane-\(nextPaneNumber)"),
            title: title,
            sessionRequest: TerminalSessionRequest(workingDirectory: workingDirectory)
        )
    }
}
