final class PaneStripStore {
    private(set) var state: PaneStripState {
        didSet {
            onChange?(state)
        }
    }

    var onChange: ((PaneStripState) -> Void)?

    private var nextPaneNumber: Int

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

            state.closeFocusedPane()
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

    private func makePane() -> PaneState {
        defer {
            nextPaneNumber += 1
        }

        let title = "pane \(nextPaneNumber)"
        return PaneState(id: PaneID("pane-\(nextPaneNumber)"), title: title)
    }
}
