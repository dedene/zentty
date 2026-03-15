import CoreGraphics

struct PaneID: Hashable, Equatable, Sendable {
    let rawValue: String

    init(_ rawValue: String) {
        self.rawValue = rawValue
    }
}

enum PaneWidthRole: Equatable, Sendable {
    case leadingReadable
    case standardColumn
}

struct PaneState: Equatable, Sendable {
    let id: PaneID
    var title: String
    var sessionRequest: TerminalSessionRequest
    var widthRole: PaneWidthRole

    init(
        id: PaneID,
        title: String,
        sessionRequest: TerminalSessionRequest = TerminalSessionRequest(),
        widthRole: PaneWidthRole = .standardColumn
    ) {
        self.id = id
        self.title = title
        self.sessionRequest = sessionRequest
        self.widthRole = widthRole
    }
}

enum PanePlacement: Sendable {
    case beforeFocused
    case afterFocused
}

struct PaneLayoutItem: Equatable, Sendable {
    let pane: PaneState
    let width: CGFloat
    let height: CGFloat
    let isFocused: Bool
    let widthRole: PaneWidthRole
}

struct PaneStripState: Equatable, Sendable {
    private(set) var panes: [PaneState]
    private(set) var focusedPaneID: PaneID?
    let layoutSizing: PaneLayoutSizing

    init(
        panes: [PaneState],
        focusedPaneID: PaneID? = nil,
        layoutSizing: PaneLayoutSizing = .balanced
    ) {
        let normalizedPanes = PaneStripState.normalizePaneRoles(in: panes)
        self.panes = normalizedPanes
        self.layoutSizing = layoutSizing
        self.focusedPaneID = PaneStripState.resolveFocusedPaneID(
            panes: normalizedPanes,
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

    func layoutItems(
        in containerSize: CGSize,
        leadingVisibleInset: CGFloat = 0
    ) -> [PaneLayoutItem] {
        let paneHeight = layoutSizing.paneHeight(for: containerSize.height)

        return panes.map { pane in
            let isFocused = pane.id == focusedPaneID
            let paneWidth: CGFloat
            switch pane.widthRole {
            case .leadingReadable:
                paneWidth = layoutSizing.leadingReadableWidth(
                    for: containerSize.width,
                    leadingVisibleInset: leadingVisibleInset
                )
            case .standardColumn:
                paneWidth = layoutSizing.standardColumnWidth(for: containerSize.width)
            }
            return PaneLayoutItem(
                pane: pane,
                width: paneWidth,
                height: paneHeight,
                isFocused: isFocused,
                widthRole: pane.widthRole
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

    mutating func focusPane(id: PaneID) {
        guard panes.contains(where: { $0.id == id }) else {
            return
        }

        focusedPaneID = id
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
        panes = Self.normalizePaneRoles(in: panes)
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

        panes = Self.normalizePaneRoles(in: panes)
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

    private static func normalizePaneRoles(in panes: [PaneState]) -> [PaneState] {
        panes.enumerated().map { index, pane in
            var pane = pane
            pane.widthRole = index == 0 ? .leadingReadable : .standardColumn
            return pane
        }
    }
}

extension PaneStripState {
    static let pocDefault = PaneStripState(
        panes: [
            PaneState(id: PaneID("shell"), title: "shell"),
        ],
        focusedPaneID: PaneID("shell")
    )
}
