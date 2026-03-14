import CoreGraphics

struct PaneID: Hashable, Equatable, Sendable {
    let rawValue: String

    init(_ rawValue: String) {
        self.rawValue = rawValue
    }
}

struct PaneState: Equatable, Sendable {
    let id: PaneID
    var title: String
}

enum PanePlacement: Sendable {
    case beforeFocused
    case afterFocused
}

struct PaneWidthProfile: Equatable, Sendable {
    let primary: CGFloat
    let secondary: CGFloat

    static let pocDefault = PaneWidthProfile(primary: 408, secondary: 248)
}

struct PaneLayoutItem: Equatable, Sendable {
    let pane: PaneState
    let width: CGFloat
    let isFocused: Bool
}

struct PaneStripState: Equatable, Sendable {
    private(set) var panes: [PaneState]
    private(set) var focusedPaneID: PaneID?
    let widthProfile: PaneWidthProfile

    init(
        panes: [PaneState],
        focusedPaneID: PaneID? = nil,
        widthProfile: PaneWidthProfile = .pocDefault
    ) {
        self.panes = panes
        self.widthProfile = widthProfile
        self.focusedPaneID = PaneStripState.resolveFocusedPaneID(
            panes: panes,
            preferredID: focusedPaneID
        )
    }

    var focusedPane: PaneState? {
        guard let focusedPaneID else {
            return nil
        }

        return panes.first { $0.id == focusedPaneID }
    }

    var focusedIndex: Int {
        guard let focusedPaneID else {
            return 0
        }

        return panes.firstIndex { $0.id == focusedPaneID } ?? 0
    }

    var layoutItems: [PaneLayoutItem] {
        panes.map { pane in
            let isFocused = pane.id == focusedPaneID
            return PaneLayoutItem(
                pane: pane,
                width: isFocused ? widthProfile.primary : widthProfile.secondary,
                isFocused: isFocused
            )
        }
    }

    mutating func moveFocusLeft() {
        moveFocus(by: -1)
    }

    mutating func moveFocusRight() {
        moveFocus(by: 1)
    }

    mutating func moveFocusToFirst() {
        focusedPaneID = panes.first?.id
    }

    mutating func moveFocusToLast() {
        focusedPaneID = panes.last?.id
    }

    mutating func insertPane(_ pane: PaneState, placement: PanePlacement) {
        guard !panes.isEmpty else {
            panes = [pane]
            focusedPaneID = pane.id
            return
        }

        let focusIndex = focusedIndex
        let insertionIndex: Int

        switch placement {
        case .beforeFocused:
            insertionIndex = focusIndex
        case .afterFocused:
            insertionIndex = min(focusIndex + 1, panes.count)
        }

        panes.insert(pane, at: insertionIndex)
        focusedPaneID = pane.id
    }

    @discardableResult
    mutating func closeFocusedPane() -> PaneState? {
        guard let focusedPaneID else {
            return nil
        }

        guard let removalIndex = panes.firstIndex(where: { $0.id == focusedPaneID }) else {
            return nil
        }

        let removedPane = panes.remove(at: removalIndex)

        guard !panes.isEmpty else {
            self.focusedPaneID = nil
            return removedPane
        }

        let nextIndex = min(removalIndex, panes.count - 1)
        self.focusedPaneID = panes[nextIndex].id
        return removedPane
    }

    private mutating func moveFocus(by delta: Int) {
        guard !panes.isEmpty else {
            focusedPaneID = nil
            return
        }

        let nextIndex = max(0, min(focusedIndex + delta, panes.count - 1))
        focusedPaneID = panes[nextIndex].id
    }

    private static func resolveFocusedPaneID(
        panes: [PaneState],
        preferredID: PaneID?
    ) -> PaneID? {
        guard let preferredID else {
            return panes.first?.id
        }

        return panes.contains(where: { $0.id == preferredID }) ? preferredID : panes.first?.id
    }
}

extension PaneStripState {
    static let pocDefault = PaneStripState(
        panes: [
            PaneState(id: PaneID("logs"), title: "logs"),
            PaneState(id: PaneID("editor"), title: "editor"),
            PaneState(id: PaneID("tests"), title: "tests"),
            PaneState(id: PaneID("shell"), title: "shell"),
        ],
        focusedPaneID: PaneID("editor")
    )
}
