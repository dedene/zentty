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
    var sessionRequest: TerminalSessionRequest
    var width: CGFloat

    init(
        id: PaneID,
        title: String,
        sessionRequest: TerminalSessionRequest = TerminalSessionRequest(),
        width: CGFloat = PaneLayoutPreset.balanced.defaultPaneWidth(for: .largeDisplay, viewportWidth: 1280)
    ) {
        self.id = id
        self.title = title
        self.sessionRequest = sessionRequest
        self.width = width
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
        self.panes = panes
        self.layoutSizing = layoutSizing
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

    func layoutItems(
        in containerSize: CGSize,
        leadingVisibleInset: CGFloat = 0
    ) -> [PaneLayoutItem] {
        let paneHeight = layoutSizing.paneHeight(for: containerSize.height)

        return panes.map { pane in
            PaneLayoutItem(
                pane: pane,
                width: max(1, pane.width),
                height: paneHeight,
                isFocused: pane.id == focusedPaneID
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
        focusedPaneID = pane.id
    }

    @discardableResult
    mutating func closeFocusedPane(singlePaneWidth: CGFloat? = nil) -> PaneState? {
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

        if panes.count == 1, let singlePaneWidth {
            panes[0].width = singlePaneWidth
        }

        return removedPane
    }

    @discardableResult
    mutating func updateSinglePaneWidth(_ width: CGFloat) -> Bool {
        guard panes.count == 1 else {
            return false
        }

        let resolvedWidth = max(1, width)
        guard panes[0].width != resolvedWidth else {
            return false
        }

        panes[0].width = resolvedWidth
        return true
    }

    @discardableResult
    mutating func scalePaneWidths(by factor: CGFloat) -> Bool {
        guard panes.count > 1 else {
            return false
        }

        let resolvedFactor = max(0, factor)
        guard abs(resolvedFactor - 1) > 0.001 else {
            return false
        }

        for index in panes.indices {
            panes[index].width = max(1, panes[index].width * resolvedFactor)
        }

        return true
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
            PaneState(id: PaneID("shell"), title: "shell"),
        ],
        focusedPaneID: PaneID("shell")
    )
}
