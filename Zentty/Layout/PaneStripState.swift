import CoreGraphics

struct PaneID: Hashable, Equatable, Sendable {
    let rawValue: String

    init(_ rawValue: String) {
        self.rawValue = rawValue
    }
}

struct PaneColumnID: Hashable, Equatable, Sendable {
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

struct PaneColumnState: Equatable, Sendable {
    let id: PaneColumnID
    var panes: [PaneState]
    var width: CGFloat
    private(set) var focusedPaneID: PaneID?
    private(set) var lastFocusedPaneID: PaneID?

    init(
        id: PaneColumnID,
        panes: [PaneState],
        width: CGFloat,
        focusedPaneID: PaneID? = nil,
        lastFocusedPaneID: PaneID? = nil
    ) {
        self.id = id
        self.panes = panes
        self.width = max(1, width)
        self.focusedPaneID = PaneColumnState.resolvePaneID(
            panes: panes,
            preferredID: focusedPaneID
        )
        self.lastFocusedPaneID = PaneColumnState.resolvePaneID(
            panes: panes,
            preferredID: lastFocusedPaneID ?? focusedPaneID
        )
    }

    var focusedPane: PaneState? {
        guard let focusedPaneID else {
            return nil
        }

        return panes.first { $0.id == focusedPaneID }
    }

    var focusedPaneIndex: Int {
        guard let focusedPaneID else {
            return 0
        }

        return panes.firstIndex { $0.id == focusedPaneID } ?? 0
    }

    mutating func restoreLastFocusedPane() {
        let restoredPaneID = PaneColumnState.resolvePaneID(
            panes: panes,
            preferredID: lastFocusedPaneID ?? focusedPaneID
        )
        focusedPaneID = restoredPaneID
        if let restoredPaneID {
            lastFocusedPaneID = restoredPaneID
        }
    }

    mutating func focusPane(id: PaneID) {
        guard panes.contains(where: { $0.id == id }) else {
            return
        }

        focusedPaneID = id
        lastFocusedPaneID = id
    }

    mutating func moveFocusUp() {
        moveFocus(by: -1)
    }

    mutating func moveFocusDown() {
        moveFocus(by: 1)
    }

    mutating func insertPaneVertically(_ pane: PaneState) {
        let insertionIndex = min(focusedPaneIndex + 1, panes.count)
        panes.insert(pane, at: insertionIndex)
        focusPane(id: pane.id)
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
            self.lastFocusedPaneID = nil
            return removedPane
        }

        let nextIndex = removalIndex < panes.count ? removalIndex : panes.count - 1
        let nextPaneID = panes[nextIndex].id
        self.focusedPaneID = nextPaneID
        self.lastFocusedPaneID = nextPaneID

        return removedPane
    }

    private mutating func moveFocus(by delta: Int) {
        guard !panes.isEmpty else {
            focusedPaneID = nil
            lastFocusedPaneID = nil
            return
        }

        let nextIndex = max(0, min(focusedPaneIndex + delta, panes.count - 1))
        let nextPaneID = panes[nextIndex].id
        focusedPaneID = nextPaneID
        lastFocusedPaneID = nextPaneID
    }

    private static func resolvePaneID(
        panes: [PaneState],
        preferredID: PaneID?
    ) -> PaneID? {
        guard let preferredID else {
            return panes.first?.id
        }

        return panes.contains(where: { $0.id == preferredID }) ? preferredID : panes.first?.id
    }
}

struct PaneStripState: Equatable, Sendable {
    static let minimumVerticalPaneHeight: CGFloat = 160

    private(set) var columns: [PaneColumnState]
    private(set) var focusedColumnID: PaneColumnID?
    private(set) var layoutSizing: PaneLayoutSizing

    init(
        columns: [PaneColumnState],
        focusedColumnID: PaneColumnID? = nil,
        layoutSizing: PaneLayoutSizing = .balanced
    ) {
        self.columns = columns.filter { !$0.panes.isEmpty }
        self.layoutSizing = layoutSizing
        self.focusedColumnID = PaneStripState.resolveFocusedColumnID(
            columns: self.columns,
            preferredID: focusedColumnID
        )
        restoreColumnFocusIfNeeded()
    }

    init(
        panes: [PaneState],
        focusedPaneID: PaneID? = nil,
        layoutSizing: PaneLayoutSizing = .balanced
    ) {
        let columns = panes.map { pane in
            PaneColumnState(
                id: PaneColumnID("column-\(pane.id.rawValue)"),
                panes: [pane],
                width: pane.width,
                focusedPaneID: pane.id,
                lastFocusedPaneID: pane.id
            )
        }
        let focusedColumnID = focusedPaneID.flatMap { paneID in
            columns.first(where: { column in
                column.panes.contains(where: { $0.id == paneID })
            })?.id
        }
        self.init(columns: columns, focusedColumnID: focusedColumnID, layoutSizing: layoutSizing)
        if let focusedPaneID {
            focusPane(id: focusedPaneID)
        }
    }

    var panes: [PaneState] {
        columns.flatMap { column in
            column.panes.map { pane in
                var pane = pane
                pane.width = column.width
                return pane
            }
        }
    }

    var focusedPaneID: PaneID? {
        focusedColumn?.focusedPaneID
    }

    var focusedColumn: PaneColumnState? {
        guard let focusedColumnID else {
            return nil
        }

        return columns.first { $0.id == focusedColumnID }
    }

    var focusedPane: PaneState? {
        guard let focusedColumn else {
            return nil
        }

        guard var pane = focusedColumn.focusedPane else {
            return nil
        }

        pane.width = focusedColumn.width
        return pane
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
        let totalHeight = layoutSizing.paneHeight(for: containerSize.height)

        return columns.flatMap { column in
            let perPaneHeight = resolvedPaneHeight(
                totalHeight: totalHeight,
                paneCount: column.panes.count
            )

            return column.panes.map { pane in
                PaneLayoutItem(
                    pane: pane,
                    width: max(1, column.width),
                    height: perPaneHeight,
                    isFocused: pane.id == focusedPaneID
                )
            }
        }
    }

    mutating func moveFocusLeft() {
        moveColumnFocus(by: -1)
    }

    mutating func moveFocusRight() {
        moveColumnFocus(by: 1)
    }

    mutating func moveFocusUp() {
        guard let focusedColumnIndex else {
            return
        }

        columns[focusedColumnIndex].moveFocusUp()
    }

    mutating func moveFocusDown() {
        guard let focusedColumnIndex else {
            return
        }

        columns[focusedColumnIndex].moveFocusDown()
    }

    mutating func moveFocusToFirst() {
        moveFocusToFirstColumn()
    }

    mutating func moveFocusToLast() {
        moveFocusToLastColumn()
    }

    mutating func moveFocusToFirstColumn() {
        focusedColumnID = columns.first?.id
        restoreColumnFocusIfNeeded()
    }

    mutating func moveFocusToLastColumn() {
        focusedColumnID = columns.last?.id
        restoreColumnFocusIfNeeded()
    }

    mutating func focusPane(id: PaneID) {
        guard let columnIndex = columns.firstIndex(where: { column in
            column.panes.contains(where: { $0.id == id })
        }) else {
            return
        }

        focusedColumnID = columns[columnIndex].id
        columns[columnIndex].focusPane(id: id)
    }

    mutating func insertPane(_ pane: PaneState, placement: PanePlacement) {
        switch placement {
        case .beforeFocused:
            insertPaneHorizontally(pane, placement: .beforeFocused)
        case .afterFocused:
            insertPaneHorizontally(pane, placement: .afterFocused)
        }
    }

    mutating func insertPaneHorizontally(
        _ pane: PaneState,
        placement: PanePlacement = .afterFocused
    ) {
        guard !columns.isEmpty else {
            columns = [
                PaneColumnState(
                    id: PaneColumnID("column-\(pane.id.rawValue)"),
                    panes: [pane],
                    width: pane.width,
                    focusedPaneID: pane.id,
                    lastFocusedPaneID: pane.id
                )
            ]
            focusedColumnID = columns.first?.id
            return
        }

        let sourceIndex = focusedColumnIndex ?? 0
        let sourceWidth = columns[sourceIndex].width
        let insertionIndex: Int

        switch placement {
        case .beforeFocused:
            insertionIndex = sourceIndex
        case .afterFocused:
            insertionIndex = min(sourceIndex + 1, columns.count)
        }

        let newColumn = PaneColumnState(
            id: PaneColumnID("column-\(pane.id.rawValue)"),
            panes: [pane],
            width: sourceWidth,
            focusedPaneID: pane.id,
            lastFocusedPaneID: pane.id
        )
        columns.insert(newColumn, at: insertionIndex)
        focusedColumnID = newColumn.id
    }

    @discardableResult
    mutating func insertPaneVertically(
        _ pane: PaneState,
        in columnID: PaneColumnID? = nil,
        availableHeight: CGFloat,
        minimumPaneHeight: CGFloat = PaneStripState.minimumVerticalPaneHeight
    ) -> Bool {
        let targetColumnID = columnID ?? focusedColumnID
        guard let targetColumnID,
              let targetIndex = columns.firstIndex(where: { $0.id == targetColumnID }) else {
            return false
        }

        let nextPaneCount = columns[targetIndex].panes.count + 1
        guard nextPaneCount > 0 else {
            return false
        }

        let resolvedMinimum = max(1, minimumPaneHeight)
        let equalizedHeight = resolvedPaneHeight(totalHeight: availableHeight, paneCount: nextPaneCount)
        guard equalizedHeight >= resolvedMinimum else {
            return false
        }

        columns[targetIndex].insertPaneVertically(pane)
        focusedColumnID = columns[targetIndex].id
        return true
    }

    mutating func resizeFirstPane(to width: CGFloat) {
        resizeFirstColumn(to: width)
    }

    mutating func resizeFirstColumn(to width: CGFloat) {
        guard !columns.isEmpty else {
            return
        }

        columns[0].width = max(1, width)
    }

    @discardableResult
    mutating func closeFocusedPane(singleColumnWidth: CGFloat? = nil) -> PaneState? {
        guard let focusedColumnIndex else {
            return nil
        }

        if columns[focusedColumnIndex].panes.count > 1 {
            let removedPane = columns[focusedColumnIndex].closeFocusedPane()
            if columns.count == 1,
               columns[focusedColumnIndex].panes.count == 1,
               let singleColumnWidth {
                columns[focusedColumnIndex].width = max(1, singleColumnWidth)
            }
            return removedPane
        }

        guard let removedPane = columns[focusedColumnIndex].panes.first else {
            return nil
        }

        columns.remove(at: focusedColumnIndex)

        guard !columns.isEmpty else {
            focusedColumnID = nil
            return removedPane
        }

        let nextIndex = min(focusedColumnIndex, columns.count - 1)
        focusedColumnID = columns[nextIndex].id
        restoreColumnFocusIfNeeded()

        if columns.count == 1, let singleColumnWidth {
            columns[0].width = max(1, singleColumnWidth)
        }

        return removedPane
    }

    @discardableResult
    mutating func updateSinglePaneWidth(_ width: CGFloat) -> Bool {
        guard columns.count == 1, columns[0].panes.count == 1 else {
            return false
        }

        let resolvedWidth = max(1, width)
        guard columns[0].width != resolvedWidth else {
            return false
        }

        columns[0].width = resolvedWidth
        return true
    }

    @discardableResult
    mutating func scalePaneWidths(by factor: CGFloat) -> Bool {
        guard columns.count > 1 else {
            return false
        }

        let resolvedFactor = max(0, factor)
        guard abs(resolvedFactor - 1) > 0.001 else {
            return false
        }

        for index in columns.indices {
            columns[index].width = max(1, columns[index].width * resolvedFactor)
        }

        return true
    }

    private var focusedColumnIndex: Int? {
        guard let focusedColumnID else {
            return nil
        }

        return columns.firstIndex { $0.id == focusedColumnID }
    }

    @discardableResult
    mutating func updateLayoutSizing(_ layoutSizing: PaneLayoutSizing) -> Bool {
        guard self.layoutSizing != layoutSizing else {
            return false
        }

        self.layoutSizing = layoutSizing
        return true
    }

    private mutating func moveColumnFocus(by delta: Int) {
        guard !columns.isEmpty else {
            focusedColumnID = nil
            return
        }

        let currentIndex = focusedColumnIndex ?? 0
        let nextIndex = max(0, min(currentIndex + delta, columns.count - 1))
        focusedColumnID = columns[nextIndex].id
        restoreColumnFocusIfNeeded()
    }

    private mutating func restoreColumnFocusIfNeeded() {
        guard let focusedColumnIndex else {
            return
        }

        columns[focusedColumnIndex].restoreLastFocusedPane()
    }

    private static func resolveFocusedColumnID(
        columns: [PaneColumnState],
        preferredID: PaneColumnID?
    ) -> PaneColumnID? {
        guard let preferredID else {
            return columns.first?.id
        }

        return columns.contains(where: { $0.id == preferredID }) ? preferredID : columns.first?.id
    }

    private func resolvedPaneHeight(
        totalHeight: CGFloat,
        paneCount: Int
    ) -> CGFloat {
        guard paneCount > 0 else {
            return 0
        }

        let totalSpacing = layoutSizing.interPaneSpacing * CGFloat(max(0, paneCount - 1))
        let usableHeight = max(0, totalHeight - totalSpacing)
        return usableHeight / CGFloat(paneCount)
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
