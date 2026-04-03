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

enum PaneResizeAxis: Equatable, Sendable {
    case horizontal
    case vertical
}

enum PaneDivider: Hashable, Equatable, Sendable {
    case column(afterColumnID: PaneColumnID)
    case pane(columnID: PaneColumnID, afterPaneID: PaneID)

    var axis: PaneResizeAxis {
        switch self {
        case .column:
            .horizontal
        case .pane:
            .vertical
        }
    }
}

enum PaneHorizontalEdge: Equatable, Sendable {
    case left
    case right
}

struct PaneHorizontalResizeTarget: Equatable, Sendable {
    let columnID: PaneColumnID
    let edge: PaneHorizontalEdge
    let divider: PaneDivider
}

enum PaneResizeTarget: Equatable, Sendable {
    case divider(PaneDivider)
    case horizontalEdge(PaneHorizontalResizeTarget)

    var axis: PaneResizeAxis {
        switch self {
        case .divider(let divider):
            divider.axis
        case .horizontalEdge:
            .horizontal
        }
    }
}

struct PaneMinimumSize: Equatable, Sendable {
    static let fallback = PaneMinimumSize(width: 320, height: 160)

    let width: CGFloat
    let height: CGFloat

    init(width: CGFloat, height: CGFloat) {
        self.width = max(1, width)
        self.height = max(1, height)
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
    var paneHeights: [CGFloat]
    private(set) var focusedPaneID: PaneID?
    private(set) var lastFocusedPaneID: PaneID?

    init(
        id: PaneColumnID,
        panes: [PaneState],
        width: CGFloat,
        paneHeights: [CGFloat] = [],
        focusedPaneID: PaneID? = nil,
        lastFocusedPaneID: PaneID? = nil
    ) {
        self.id = id
        self.panes = panes
        self.width = max(1, width)
        self.paneHeights = Self.resolvedStoredPaneHeights(
            preferred: paneHeights,
            paneCount: panes.count
        )
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

    var isFocusedPaneAtTop: Bool {
        focusedPaneIndex == 0
    }

    var isFocusedPaneAtBottom: Bool {
        focusedPaneIndex == panes.count - 1
    }

    mutating func moveFocusUp() {
        moveFocus(by: -1)
    }

    mutating func moveFocusDown() {
        moveFocus(by: 1)
    }

    mutating func insertPaneVertically(_ pane: PaneState) {
        guard !panes.isEmpty else {
            panes = [pane]
            paneHeights = [1]
            focusPane(id: pane.id)
            return
        }

        let sourceIndex = max(0, min(focusedPaneIndex, paneHeights.count - 1))
        let insertionIndex = min(sourceIndex + 1, panes.count)
        let sourceHeight = paneHeights[sourceIndex]
        let insertedHeight = max(1, sourceHeight / 2)
        let retainedHeight = max(1, sourceHeight - insertedHeight)

        paneHeights[sourceIndex] = retainedHeight
        paneHeights.insert(insertedHeight, at: insertionIndex)
        panes.insert(pane, at: insertionIndex)
        reconcilePaneHeights()
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
        let removedHeight = paneHeights.indices.contains(removalIndex) ? paneHeights.remove(at: removalIndex) : 1

        guard !panes.isEmpty else {
            self.focusedPaneID = nil
            self.lastFocusedPaneID = nil
            paneHeights = []
            return removedPane
        }

        let nextIndex = removalIndex < panes.count ? removalIndex : panes.count - 1
        let nextPaneID = panes[nextIndex].id
        self.focusedPaneID = nextPaneID
        self.lastFocusedPaneID = nextPaneID
        if paneHeights.indices.contains(nextIndex) {
            paneHeights[nextIndex] += removedHeight
        }
        reconcilePaneHeights()

        return removedPane
    }

    mutating func resizePaneDivider(
        afterPaneAt dividerIndex: Int,
        delta: CGFloat,
        totalHeight: CGFloat,
        spacing: CGFloat,
        minimumHeights: [CGFloat]
    ) -> Bool {
        guard dividerIndex >= 0, dividerIndex + 1 < panes.count else {
            return false
        }

        let currentHeights = resolvedPaneHeights(
            totalHeight: totalHeight,
            spacing: spacing,
            minimumHeights: minimumHeights
        )
        let upperMinimum = Self.normalizedMinimums(minimumHeights, paneCount: panes.count)[dividerIndex]
        let lowerMinimum = Self.normalizedMinimums(minimumHeights, paneCount: panes.count)[dividerIndex + 1]
        let combinedHeight = currentHeights[dividerIndex] + currentHeights[dividerIndex + 1]
        let proposedUpperHeight = currentHeights[dividerIndex] + delta
        let resolvedUpperHeight = min(
            max(upperMinimum, proposedUpperHeight),
            combinedHeight - lowerMinimum
        )
        let resolvedLowerHeight = combinedHeight - resolvedUpperHeight

        guard
            resolvedUpperHeight >= upperMinimum,
            resolvedLowerHeight >= lowerMinimum,
            abs(resolvedUpperHeight - currentHeights[dividerIndex]) > 0.001
        else {
            return false
        }

        var updatedHeights = currentHeights
        updatedHeights[dividerIndex] = resolvedUpperHeight
        updatedHeights[dividerIndex + 1] = resolvedLowerHeight
        paneHeights = updatedHeights
        reconcilePaneHeights()
        return true
    }

    mutating func equalizeAdjacentPanes(
        afterPaneAt dividerIndex: Int,
        totalHeight: CGFloat,
        spacing: CGFloat
    ) -> Bool {
        guard dividerIndex >= 0, dividerIndex + 1 < panes.count else {
            return false
        }

        let currentHeights = resolvedPaneHeights(
            totalHeight: totalHeight,
            spacing: spacing
        )
        let combinedHeight = currentHeights[dividerIndex] + currentHeights[dividerIndex + 1]
        let equalizedHeight = combinedHeight / 2

        guard abs(currentHeights[dividerIndex] - equalizedHeight) > 0.001 else {
            return false
        }

        var updatedHeights = currentHeights
        updatedHeights[dividerIndex] = equalizedHeight
        updatedHeights[dividerIndex + 1] = equalizedHeight
        paneHeights = updatedHeights
        reconcilePaneHeights()
        return true
    }

    mutating func resetPaneHeights() {
        paneHeights = Self.resolvedStoredPaneHeights(preferred: [], paneCount: panes.count)
    }

    func resolvedPaneHeights(
        totalHeight: CGFloat,
        spacing: CGFloat,
        minimumHeights: [CGFloat] = []
    ) -> [CGFloat] {
        guard !panes.isEmpty else {
            return []
        }

        let usableHeight = max(0, totalHeight - (spacing * CGFloat(max(0, panes.count - 1))))
        guard usableHeight > 0 else {
            return Array(repeating: 0, count: panes.count)
        }

        let preferredHeights = Self.resolvedStoredPaneHeights(
            preferred: paneHeights,
            paneCount: panes.count
        )
        let totalPreferredHeight = preferredHeights.reduce(0, +)
        let scaledHeights: [CGFloat]
        if totalPreferredHeight > 0 {
            scaledHeights = preferredHeights.map { $0 * usableHeight / totalPreferredHeight }
        } else {
            scaledHeights = Array(repeating: usableHeight / CGFloat(panes.count), count: panes.count)
        }

        return Self.applyingMinimums(
            to: scaledHeights,
            total: usableHeight,
            minimums: Self.normalizedMinimums(minimumHeights, paneCount: panes.count)
        )
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

    mutating func reconcilePaneHeights() {
        paneHeights = Self.resolvedStoredPaneHeights(
            preferred: paneHeights,
            paneCount: panes.count
        )
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

    private static func resolvedStoredPaneHeights(
        preferred: [CGFloat],
        paneCount: Int
    ) -> [CGFloat] {
        guard paneCount > 0 else {
            return []
        }

        let sanitized = preferred.prefix(paneCount).map { max(1, $0) }
        guard sanitized.count == paneCount else {
            return Array(repeating: 1, count: paneCount)
        }

        return sanitized
    }

    private static func normalizedMinimums(
        _ minimumHeights: [CGFloat],
        paneCount: Int
    ) -> [CGFloat] {
        guard minimumHeights.count == paneCount else {
            return Array(repeating: 0, count: paneCount)
        }

        return minimumHeights.map { max(0, $0) }
    }

    private static func applyingMinimums(
        to sizes: [CGFloat],
        total: CGFloat,
        minimums: [CGFloat]
    ) -> [CGFloat] {
        guard sizes.count == minimums.count else {
            return sizes
        }

        let minimumTotal = minimums.reduce(0, +)
        guard total > 0 else {
            return Array(repeating: 0, count: sizes.count)
        }

        if minimumTotal >= total, minimumTotal > 0 {
            let scale = total / minimumTotal
            return minimums.map { $0 * scale }
        }

        var result = sizes
        var deficit: CGFloat = 0

        for index in result.indices where result[index] < minimums[index] {
            deficit += minimums[index] - result[index]
            result[index] = minimums[index]
        }

        while deficit > 0.001 {
            let donorIndices = result.indices.filter { result[$0] > minimums[$0] + 0.001 }
            guard !donorIndices.isEmpty else {
                break
            }

            let totalDonorCapacity = donorIndices.reduce(0) { partialResult, index in
                partialResult + (result[index] - minimums[index])
            }
            guard totalDonorCapacity > 0 else {
                break
            }

            let resolvedAdjustment = min(deficit, totalDonorCapacity)
            for index in donorIndices {
                let donorCapacity = result[index] - minimums[index]
                let donorShare = resolvedAdjustment * (donorCapacity / totalDonorCapacity)
                result[index] -= donorShare
            }
            deficit -= resolvedAdjustment
        }

        let correction = total - result.reduce(0, +)
        if abs(correction) > 0.001,
           let correctionIndex = result.indices.max(by: { result[$0] < result[$1] }) {
            result[correctionIndex] = max(0, result[correctionIndex] + correction)
        }

        return result
    }
}

struct PaneStripState: Equatable, Sendable {
    static let minimumVerticalPaneHeight: CGFloat = 160

    var columns: [PaneColumnState]
    private(set) var focusedColumnID: PaneColumnID?
    private(set) var layoutSizing: PaneLayoutSizing
    private(set) var lastInteractedDivider: PaneDivider?

    init(
        columns: [PaneColumnState],
        focusedColumnID: PaneColumnID? = nil,
        layoutSizing: PaneLayoutSizing = .balanced,
        lastInteractedDivider: PaneDivider? = nil
    ) {
        self.columns = columns.filter { !$0.panes.isEmpty }
        self.layoutSizing = layoutSizing
        self.focusedColumnID = PaneStripState.resolveFocusedColumnID(
            columns: self.columns,
            preferredID: focusedColumnID
        )
        self.lastInteractedDivider = lastInteractedDivider
        restoreColumnFocusIfNeeded()
        sanitizeLastInteractedDivider()
    }

    init(
        panes: [PaneState],
        focusedPaneID: PaneID? = nil,
        layoutSizing: PaneLayoutSizing = .balanced,
        lastInteractedDivider: PaneDivider? = nil
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
        self.init(
            columns: columns,
            focusedColumnID: focusedColumnID,
            layoutSizing: layoutSizing,
            lastInteractedDivider: lastInteractedDivider
        )
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
        _ = leadingVisibleInset
        let totalHeight = layoutSizing.paneHeight(for: containerSize.height)

        return columns.flatMap { column in
            let resolvedHeights = column.resolvedPaneHeights(
                totalHeight: totalHeight,
                spacing: layoutSizing.interPaneSpacing
            )

            return zip(column.panes, resolvedHeights).map { pane, resolvedHeight in
                PaneLayoutItem(
                    pane: pane,
                    width: max(1, column.width),
                    height: resolvedHeight,
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

    var isFocusedPaneAtTopOfColumn: Bool {
        guard let focusedColumnIndex else { return true }
        return columns[focusedColumnIndex].isFocusedPaneAtTop
    }

    var isFocusedPaneAtBottomOfColumn: Bool {
        guard let focusedColumnIndex else { return true }
        return columns[focusedColumnIndex].isFocusedPaneAtBottom
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
            sanitizeLastInteractedDivider()
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
        sanitizeLastInteractedDivider()
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
        sanitizeLastInteractedDivider()
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
            sanitizeLastInteractedDivider()
            return removedPane
        }

        guard let removedPane = columns[focusedColumnIndex].panes.first else {
            return nil
        }

        columns.remove(at: focusedColumnIndex)

        guard !columns.isEmpty else {
            focusedColumnID = nil
            lastInteractedDivider = nil
            return removedPane
        }

        let nextIndex = min(focusedColumnIndex, columns.count - 1)
        focusedColumnID = columns[nextIndex].id
        restoreColumnFocusIfNeeded()

        if columns.count == 1, let singleColumnWidth {
            columns[0].width = max(1, singleColumnWidth)
        }

        sanitizeLastInteractedDivider()
        return removedPane
    }

    @discardableResult
    mutating func removePane(
        id: PaneID,
        singleColumnWidth: CGFloat? = nil
    ) -> (pane: PaneState, fromColumnID: PaneColumnID, columnIndex: Int, paneIndex: Int)? {
        guard let columnIndex = columns.firstIndex(where: { column in
            column.panes.contains(where: { $0.id == id })
        }) else {
            return nil
        }

        let columnID = columns[columnIndex].id

        guard let paneIndex = columns[columnIndex].panes.firstIndex(where: { $0.id == id }) else {
            return nil
        }

        if columns[columnIndex].panes.count > 1 {
            let removedPane = columns[columnIndex].panes.remove(at: paneIndex)
            let removedHeight = columns[columnIndex].paneHeights.indices.contains(paneIndex)
                ? columns[columnIndex].paneHeights.remove(at: paneIndex) : 1

            let nextIndex = paneIndex < columns[columnIndex].panes.count
                ? paneIndex : columns[columnIndex].panes.count - 1

            if columns[columnIndex].focusedPaneID == id {
                let nextPaneID = columns[columnIndex].panes[nextIndex].id
                columns[columnIndex].focusPane(id: nextPaneID)
            }

            if columns[columnIndex].paneHeights.indices.contains(nextIndex) {
                columns[columnIndex].paneHeights[nextIndex] += removedHeight
            }
            columns[columnIndex].reconcilePaneHeights()

            if columns.count == 1,
               columns[columnIndex].panes.count == 1,
               let singleColumnWidth {
                columns[columnIndex].width = max(1, singleColumnWidth)
            }

            sanitizeLastInteractedDivider()
            return (removedPane, columnID, columnIndex, paneIndex)
        }

        let removedPane = columns[columnIndex].panes[0]
        columns.remove(at: columnIndex)

        guard !columns.isEmpty else {
            focusedColumnID = nil
            lastInteractedDivider = nil
            return (removedPane, columnID, columnIndex, paneIndex)
        }

        let nextColIndex = min(columnIndex, columns.count - 1)
        if focusedColumnID == columnID {
            focusedColumnID = columns[nextColIndex].id
            restoreColumnFocusIfNeeded()
        }

        if columns.count == 1, let singleColumnWidth {
            columns[0].width = max(1, singleColumnWidth)
        }

        sanitizeLastInteractedDivider()
        return (removedPane, columnID, columnIndex, paneIndex)
    }

    mutating func insertPaneAsColumn(
        _ pane: PaneState,
        atColumnIndex index: Int,
        width: CGFloat
    ) {
        let clampedIndex = max(0, min(index, columns.count))
        let newColumn = PaneColumnState(
            id: PaneColumnID("column-\(pane.id.rawValue)"),
            panes: [pane],
            width: width,
            focusedPaneID: pane.id,
            lastFocusedPaneID: pane.id
        )
        columns.insert(newColumn, at: clampedIndex)
        focusedColumnID = newColumn.id
        sanitizeLastInteractedDivider()
    }

    @discardableResult
    mutating func insertPaneIntoColumn(
        _ pane: PaneState,
        columnID: PaneColumnID,
        targetPaneID: PaneID,
        atPaneIndex paneIndex: Int,
        availableHeight: CGFloat,
        minimumPaneHeight: CGFloat = PaneStripState.minimumVerticalPaneHeight
    ) -> Bool {
        guard let columnIndex = columns.firstIndex(where: { $0.id == columnID }) else {
            return false
        }

        guard let targetIndex = columns[columnIndex].panes.firstIndex(where: { $0.id == targetPaneID }) else {
            return false
        }

        // Resolve actual pixel heights to check minimum constraint
        let column = columns[columnIndex]
        let resolvedHeights = column.resolvedPaneHeights(
            totalHeight: availableHeight,
            spacing: layoutSizing.interPaneSpacing
        )
        let targetPixelHeight = resolvedHeights.indices.contains(targetIndex)
            ? resolvedHeights[targetIndex] : availableHeight
        guard targetPixelHeight / 2 >= minimumPaneHeight else {
            return false
        }

        // Split the stored ratio in half
        let targetRatio = column.paneHeights.indices.contains(targetIndex)
            ? column.paneHeights[targetIndex] : 1
        let insertedHeight = max(1, targetRatio / 2)
        let retainedHeight = max(1, targetRatio - insertedHeight)

        columns[columnIndex].paneHeights[targetIndex] = retainedHeight
        let clampedPaneIndex = max(0, min(paneIndex, columns[columnIndex].panes.count))
        columns[columnIndex].paneHeights.insert(insertedHeight, at: clampedPaneIndex)
        columns[columnIndex].panes.insert(pane, at: clampedPaneIndex)
        columns[columnIndex].reconcilePaneHeights()
        columns[columnIndex].focusPane(id: pane.id)
        focusedColumnID = columns[columnIndex].id
        sanitizeLastInteractedDivider()
        return true
    }

    mutating func insertPaneAdjacentToColumn(
        _ pane: PaneState,
        containingPaneID: PaneID,
        leading: Bool,
        width: CGFloat
    ) {
        guard let columnIndex = columns.firstIndex(where: { column in
            column.panes.contains(where: { $0.id == containingPaneID })
        }) else {
            return
        }

        let insertionIndex = leading ? columnIndex : columnIndex + 1
        insertPaneAsColumn(pane, atColumnIndex: insertionIndex, width: width)
    }

    @discardableResult
    mutating func updateSingleColumnWidth(_ width: CGFloat) -> Bool {
        guard columns.count == 1 else {
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

    func arrangedColumnWidth(
        for visibleColumnCount: Int,
        availableWidth: CGFloat,
        leadingVisibleInset: CGFloat = 0
    ) -> CGFloat {
        let resolvedVisibleColumnCount = max(1, visibleColumnCount)
        let readableWidth = layoutSizing.readableWidth(
            for: availableWidth,
            leadingVisibleInset: leadingVisibleInset
        )
        let totalSpacing = layoutSizing.interPaneSpacing * CGFloat(max(0, resolvedVisibleColumnCount - 1))
        let usableWidth = max(0, readableWidth - totalSpacing)
        return max(1, usableWidth / CGFloat(resolvedVisibleColumnCount))
    }

    @discardableResult
    mutating func arrangeHorizontally(
        _ arrangement: PaneHorizontalArrangement,
        availableWidth: CGFloat,
        leadingVisibleInset: CGFloat = 0
    ) -> Bool {
        guard !columns.isEmpty else {
            return false
        }

        let targetWidth = arrangedColumnWidth(
            for: arrangement.visibleColumnCount,
            availableWidth: availableWidth,
            leadingVisibleInset: leadingVisibleInset
        )
        var didChange = false

        for index in columns.indices {
            if abs(columns[index].width - targetWidth) > 0.001 {
                didChange = true
            }
            columns[index].width = targetWidth
        }

        return didChange
    }

    @discardableResult
    mutating func arrangeVertically(_ arrangement: PaneVerticalArrangement) -> Bool {
        let panesInReadingOrder = panes
        guard !panesInReadingOrder.isEmpty else {
            return false
        }

        let previousColumns = columns
        let previousFocusedPaneID = focusedPaneID
        let previousWidths = previousColumns.map(\.width)
        let panesPerColumn = arrangement.panesPerColumn
        var rebuiltColumns: [PaneColumnState] = []
        rebuiltColumns.reserveCapacity(Int(ceil(Double(panesInReadingOrder.count) / Double(max(1, panesPerColumn)))))

        for startIndex in stride(from: 0, to: panesInReadingOrder.count, by: panesPerColumn) {
            let endIndex = min(startIndex + panesPerColumn, panesInReadingOrder.count)
            let paneSlice = Array(panesInReadingOrder[startIndex..<endIndex])
            guard let firstPane = paneSlice.first else {
                continue
            }

            let rebuiltColumnIndex = rebuiltColumns.count
            let inheritedWidth = previousWidths[min(rebuiltColumnIndex, previousWidths.count - 1)]
            let paneIDs = Set(paneSlice.map(\.id))
            let preservedFocusedPaneID = previousFocusedPaneID.flatMap { paneIDs.contains($0) ? $0 : nil }
            let preservedLastFocusedPaneID = previousColumns
                .compactMap(\.lastFocusedPaneID)
                .first(where: { paneIDs.contains($0) })
            let restoredPaneID = preservedFocusedPaneID ?? preservedLastFocusedPaneID ?? firstPane.id
            let adjustedPanes = paneSlice.map { pane -> PaneState in
                var pane = pane
                pane.width = inheritedWidth
                return pane
            }
            let columnID = rebuiltColumnIndex < previousColumns.count
                ? previousColumns[rebuiltColumnIndex].id
                : PaneColumnID("column-\(firstPane.id.rawValue)")

            rebuiltColumns.append(
                PaneColumnState(
                    id: columnID,
                    panes: adjustedPanes,
                    width: inheritedWidth,
                    focusedPaneID: restoredPaneID,
                    lastFocusedPaneID: restoredPaneID
                )
            )
        }

        let rebuiltFocusedColumnID = previousFocusedPaneID.flatMap { paneID in
            rebuiltColumns.first(where: { column in
                column.panes.contains(where: { $0.id == paneID })
            })?.id
        } ?? rebuiltColumns.first?.id

        let rebuiltState = PaneStripState(
            columns: rebuiltColumns,
            focusedColumnID: rebuiltFocusedColumnID,
            layoutSizing: layoutSizing
        )
        guard rebuiltState != self else {
            return false
        }

        self = rebuiltState
        return true
    }

    @discardableResult
    mutating func arrangeGoldenWidth(focusWide: Bool) -> Bool {
        guard columns.count >= 2, let focusedIdx = focusedColumnIndex else {
            return false
        }

        let neighborIdx: Int
        if focusedIdx + 1 < columns.count {
            neighborIdx = focusedIdx + 1
        } else {
            neighborIdx = focusedIdx - 1
        }

        let phi: CGFloat = (1 + sqrt(5)) / 2
        let goldenMajor: CGFloat = phi / (1 + phi)
        let focusedRatio = focusWide ? goldenMajor : 1 - goldenMajor

        let combinedWidth = columns[focusedIdx].width + columns[neighborIdx].width
        let targetFocusedWidth = combinedWidth * focusedRatio
        let targetNeighborWidth = combinedWidth - targetFocusedWidth

        guard abs(columns[focusedIdx].width - targetFocusedWidth) > 0.001 else {
            return false
        }

        columns[focusedIdx].width = targetFocusedWidth
        columns[neighborIdx].width = targetNeighborWidth
        return true
    }

    @discardableResult
    mutating func arrangeGoldenHeight(focusTall: Bool, availableSize: CGSize) -> Bool {
        guard let focusedIdx = focusedColumnIndex else {
            return false
        }

        let column = columns[focusedIdx]
        guard column.panes.count >= 2 else {
            return false
        }

        let focusedPaneIdx = column.focusedPaneIndex
        let neighborPaneIdx: Int
        if focusedPaneIdx + 1 < column.panes.count {
            neighborPaneIdx = focusedPaneIdx + 1
        } else {
            neighborPaneIdx = focusedPaneIdx - 1
        }

        let phi: CGFloat = (1 + sqrt(5)) / 2
        let goldenMajor: CGFloat = phi / (1 + phi)
        let focusedRatio = focusTall ? goldenMajor : 1 - goldenMajor

        let totalHeight = layoutSizing.paneHeight(for: availableSize.height)
        let currentHeights = column.resolvedPaneHeights(
            totalHeight: totalHeight,
            spacing: layoutSizing.interPaneSpacing
        )

        let combinedHeight = currentHeights[focusedPaneIdx] + currentHeights[neighborPaneIdx]
        let targetFocusedHeight = combinedHeight * focusedRatio
        let targetNeighborHeight = combinedHeight - targetFocusedHeight

        guard abs(currentHeights[focusedPaneIdx] - targetFocusedHeight) > 0.001 else {
            return false
        }

        var updatedHeights = currentHeights
        updatedHeights[focusedPaneIdx] = targetFocusedHeight
        updatedHeights[neighborPaneIdx] = targetNeighborHeight
        columns[focusedIdx].paneHeights = updatedHeights
        columns[focusedIdx].reconcilePaneHeights()
        return true
    }

    @discardableResult
    mutating func updateLayoutSizing(_ layoutSizing: PaneLayoutSizing) -> Bool {
        guard self.layoutSizing != layoutSizing else {
            return false
        }

        self.layoutSizing = layoutSizing
        return true
    }

    @discardableResult
    mutating func resizeDivider(
        _ divider: PaneDivider,
        delta: CGFloat,
        availableSize: CGSize,
        minimumSizeByPaneID: [PaneID: PaneMinimumSize] = [:]
    ) -> Bool {
        switch divider {
        case .column(let afterColumnID):
            guard
                let columnIndex = columns.firstIndex(where: { $0.id == afterColumnID }),
                columnIndex + 1 < columns.count
            else {
                return false
            }

            let leftMinimumWidth = minimumColumnWidth(
                for: columns[columnIndex],
                minimumSizeByPaneID: minimumSizeByPaneID
            )
            let rightMinimumWidth = minimumColumnWidth(
                for: columns[columnIndex + 1],
                minimumSizeByPaneID: minimumSizeByPaneID
            )
            let combinedWidth = columns[columnIndex].width + columns[columnIndex + 1].width
            let proposedLeadingWidth = columns[columnIndex].width + delta
            let resolvedLeadingWidth = min(
                max(leftMinimumWidth, proposedLeadingWidth),
                combinedWidth - rightMinimumWidth
            )
            let resolvedTrailingWidth = combinedWidth - resolvedLeadingWidth

            guard
                resolvedLeadingWidth >= leftMinimumWidth,
                resolvedTrailingWidth >= rightMinimumWidth,
                abs(resolvedLeadingWidth - columns[columnIndex].width) > 0.001
            else {
                return false
            }

            columns[columnIndex].width = resolvedLeadingWidth
            columns[columnIndex + 1].width = resolvedTrailingWidth
        case .pane(let columnID, let afterPaneID):
            guard
                let columnIndex = columns.firstIndex(where: { $0.id == columnID }),
                let paneIndex = columns[columnIndex].panes.firstIndex(where: { $0.id == afterPaneID })
            else {
                return false
            }

            let minimumHeights = columns[columnIndex].panes.map { pane in
                (minimumSizeByPaneID[pane.id] ?? .fallback).height
            }
            let didResize = columns[columnIndex].resizePaneDivider(
                afterPaneAt: paneIndex,
                delta: delta,
                totalHeight: layoutSizing.paneHeight(for: availableSize.height),
                spacing: layoutSizing.interPaneSpacing,
                minimumHeights: minimumHeights
            )
            guard didResize else {
                return false
            }
        }

        lastInteractedDivider = divider
        return true
    }

    @discardableResult
    mutating func resize(
        _ target: PaneResizeTarget,
        delta: CGFloat,
        availableSize: CGSize,
        leadingVisibleInset: CGFloat = 0,
        minimumSizeByPaneID: [PaneID: PaneMinimumSize] = [:]
    ) -> Bool {
        switch target {
        case .divider(let divider):
            return resizeDivider(
                divider,
                delta: delta,
                availableSize: availableSize,
                minimumSizeByPaneID: minimumSizeByPaneID
            )
        case .horizontalEdge(let horizontalTarget):
            return resizeHorizontalEdge(
                horizontalTarget,
                delta: delta,
                availableSize: availableSize,
                leadingVisibleInset: leadingVisibleInset,
                minimumSizeByPaneID: minimumSizeByPaneID
            )
        }
    }

    @discardableResult
    mutating func equalizeDivider(
        _ divider: PaneDivider,
        availableSize: CGSize
    ) -> Bool {
        switch divider {
        case .column(let afterColumnID):
            guard
                let columnIndex = columns.firstIndex(where: { $0.id == afterColumnID }),
                columnIndex + 1 < columns.count
            else {
                return false
            }

            let combinedWidth = columns[columnIndex].width + columns[columnIndex + 1].width
            let equalizedWidth = combinedWidth / 2
            guard abs(columns[columnIndex].width - equalizedWidth) > 0.001 else {
                return false
            }
            columns[columnIndex].width = equalizedWidth
            columns[columnIndex + 1].width = equalizedWidth
        case .pane(let columnID, let afterPaneID):
            guard
                let columnIndex = columns.firstIndex(where: { $0.id == columnID }),
                let paneIndex = columns[columnIndex].panes.firstIndex(where: { $0.id == afterPaneID })
            else {
                return false
            }

            let didEqualize = columns[columnIndex].equalizeAdjacentPanes(
                afterPaneAt: paneIndex,
                totalHeight: layoutSizing.paneHeight(for: availableSize.height),
                spacing: layoutSizing.interPaneSpacing
            )
            guard didEqualize else {
                return false
            }
        }

        lastInteractedDivider = divider
        return true
    }

    mutating func resetPaneHeights() {
        for index in columns.indices {
            columns[index].resetPaneHeights()
        }
    }

    mutating func markDividerInteraction(_ divider: PaneDivider) {
        guard contains(divider: divider) else {
            return
        }

        lastInteractedDivider = divider
    }

    func preferredDivider(for axis: PaneResizeAxis) -> PaneDivider? {
        if let lastInteractedDivider,
           lastInteractedDivider.axis == axis,
           isDividerAvailableToFocusedPane(lastInteractedDivider) {
            return lastInteractedDivider
        }

        return nearestDivider(for: axis)
    }

    func horizontalResizeTarget(for divider: PaneDivider) -> PaneHorizontalResizeTarget? {
        guard case .column(let afterColumnID) = divider,
              let dividerColumnIndex = columns.firstIndex(where: { $0.id == afterColumnID }),
              dividerColumnIndex + 1 < columns.count,
              let focusedColumnIndex,
              columns.count > 1 else {
            return nil
        }

        let preferredEdge: PaneHorizontalEdge = focusedColumnIndex > dividerColumnIndex ? .left : .right
        return focusedHorizontalResizeTarget(preferredEdge: preferredEdge)
    }

    func shouldInvertVerticalKeyboardResizeDelta() -> Bool {
        guard let divider = preferredDivider(for: .vertical) else {
            return false
        }

        return isFocusedPaneAbove(divider: divider)
    }

    @discardableResult
    mutating func resizeFocusedPane(
        in axis: PaneResizeAxis,
        delta: CGFloat,
        availableSize: CGSize,
        leadingVisibleInset: CGFloat = 0,
        minimumSizeByPaneID: [PaneID: PaneMinimumSize] = [:]
    ) -> Bool {
        switch axis {
        case .horizontal:
            if isFocusedColumnInteriorForHorizontalKeyboardResize {
                return resizeFocusedInteriorColumn(
                    delta: delta,
                    availableSize: availableSize,
                    leadingVisibleInset: leadingVisibleInset,
                    minimumSizeByPaneID: minimumSizeByPaneID
                )
            }
            guard let target = focusedHorizontalResizeTarget(for: delta) else {
                return false
            }
            return resize(
                target,
                delta: delta,
                availableSize: availableSize,
                leadingVisibleInset: leadingVisibleInset,
                minimumSizeByPaneID: minimumSizeByPaneID
            )
        case .vertical:
            guard let divider = preferredDivider(for: axis) else {
                return false
            }

            let resolvedDelta = adjustedResizeDelta(delta, for: divider)

            return resizeDivider(
                divider,
                delta: resolvedDelta,
                availableSize: availableSize,
                minimumSizeByPaneID: minimumSizeByPaneID
            )
        }
    }

    private var isFocusedColumnInteriorForHorizontalKeyboardResize: Bool {
        guard let focusedColumnIndex else {
            return false
        }

        return columns.count > 2
            && focusedColumnIndex > 0
            && focusedColumnIndex + 1 < columns.count
    }

    private var focusedColumnIndex: Int? {
        guard let focusedColumnID else {
            return nil
        }

        return columns.firstIndex { $0.id == focusedColumnID }
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

    private mutating func sanitizeLastInteractedDivider() {
        if let lastInteractedDivider, !contains(divider: lastInteractedDivider) {
            self.lastInteractedDivider = nil
        }
    }

    private func contains(divider: PaneDivider) -> Bool {
        switch divider {
        case .column(let afterColumnID):
            guard let columnIndex = columns.firstIndex(where: { $0.id == afterColumnID }) else {
                return false
            }

            return columnIndex + 1 < columns.count
        case .pane(let columnID, let afterPaneID):
            guard let column = columns.first(where: { $0.id == columnID }),
                  let paneIndex = column.panes.firstIndex(where: { $0.id == afterPaneID }) else {
                return false
            }

            return paneIndex + 1 < column.panes.count
        }
    }

    private func isDividerAvailableToFocusedPane(_ divider: PaneDivider) -> Bool {
        guard contains(divider: divider), let focusedColumnIndex else {
            return false
        }

        switch divider {
        case .column(let afterColumnID):
            guard let dividerColumnIndex = columns.firstIndex(where: { $0.id == afterColumnID }) else {
                return false
            }
            return focusedColumnIndex == dividerColumnIndex || focusedColumnIndex == dividerColumnIndex + 1
        case .pane(let columnID, let afterPaneID):
            guard columns[focusedColumnIndex].id == columnID,
                  let dividerPaneIndex = columns[focusedColumnIndex].panes.firstIndex(where: { $0.id == afterPaneID }) else {
                return false
            }
            let focusedPaneIndex = columns[focusedColumnIndex].focusedPaneIndex
            return focusedPaneIndex == dividerPaneIndex || focusedPaneIndex == dividerPaneIndex + 1
        }
    }

    private func nearestDivider(for axis: PaneResizeAxis) -> PaneDivider? {
        guard let focusedColumnIndex else {
            return nil
        }

        switch axis {
        case .horizontal:
            if focusedColumnIndex + 1 < columns.count {
                return .column(afterColumnID: columns[focusedColumnIndex].id)
            }
            if focusedColumnIndex > 0 {
                return .column(afterColumnID: columns[focusedColumnIndex - 1].id)
            }
            return nil
        case .vertical:
            let column = columns[focusedColumnIndex]
            let paneIndex = column.focusedPaneIndex
            if paneIndex + 1 < column.panes.count {
                return .pane(columnID: column.id, afterPaneID: column.panes[paneIndex].id)
            }
            if paneIndex > 0 {
                return .pane(columnID: column.id, afterPaneID: column.panes[paneIndex - 1].id)
            }
            return nil
        }
    }

    private func focusedHorizontalResizeTarget(for delta: CGFloat) -> PaneResizeTarget? {
        guard delta != 0 else {
            return nil
        }

        let preferredEdge: PaneHorizontalEdge = delta < 0 ? .left : .right
        guard let target = focusedHorizontalResizeTarget(preferredEdge: preferredEdge) else {
            return nil
        }

        return .horizontalEdge(target)
    }

    private func focusedHorizontalResizeTarget(preferredEdge: PaneHorizontalEdge) -> PaneHorizontalResizeTarget? {
        guard let focusedColumnIndex else {
            return nil
        }

        guard columns.count > 1 else {
            return nil
        }

        let focusedColumn = columns[focusedColumnIndex]
        switch preferredEdge {
        case .left:
            if focusedColumnIndex > 0 {
                return PaneHorizontalResizeTarget(
                    columnID: focusedColumn.id,
                    edge: .left,
                    divider: .column(afterColumnID: columns[focusedColumnIndex - 1].id)
                )
            }

            guard focusedColumnIndex + 1 < columns.count else {
                return nil
            }

            return PaneHorizontalResizeTarget(
                columnID: focusedColumn.id,
                edge: .right,
                divider: .column(afterColumnID: focusedColumn.id)
            )
        case .right:
            if focusedColumnIndex + 1 < columns.count {
                return PaneHorizontalResizeTarget(
                    columnID: focusedColumn.id,
                    edge: .right,
                    divider: .column(afterColumnID: focusedColumn.id)
                )
            }

            guard focusedColumnIndex > 0 else {
                return nil
            }

            return PaneHorizontalResizeTarget(
                columnID: focusedColumn.id,
                edge: .left,
                divider: .column(afterColumnID: columns[focusedColumnIndex - 1].id)
            )
        }
    }

    @discardableResult
    private mutating func resizeFocusedInteriorColumn(
        delta: CGFloat,
        availableSize: CGSize,
        leadingVisibleInset: CGFloat,
        minimumSizeByPaneID: [PaneID: PaneMinimumSize]
    ) -> Bool {
        guard delta != 0, let focusedColumnIndex else {
            return false
        }

        let divider: PaneDivider = delta < 0
            ? .column(afterColumnID: columns[focusedColumnIndex - 1].id)
            : .column(afterColumnID: columns[focusedColumnIndex].id)

        return resizeColumnWidth(
            at: focusedColumnIndex,
            widthDelta: delta,
            divider: divider,
            availableSize: availableSize,
            leadingVisibleInset: leadingVisibleInset,
            minimumSizeByPaneID: minimumSizeByPaneID
        )
    }

    @discardableResult
    private mutating func resizeHorizontalEdge(
        _ target: PaneHorizontalResizeTarget,
        delta: CGFloat,
        availableSize: CGSize,
        leadingVisibleInset: CGFloat,
        minimumSizeByPaneID: [PaneID: PaneMinimumSize]
    ) -> Bool {
        guard let columnIndex = columns.firstIndex(where: { $0.id == target.columnID }) else {
            return false
        }

        switch target.edge {
        case .left:
            guard columnIndex > 0 else {
                return false
            }
        case .right:
            guard columnIndex + 1 < columns.count else {
                return false
            }
        }

        let widthDelta = target.edge == .right ? delta : -delta
        return resizeColumnWidth(
            at: columnIndex,
            widthDelta: widthDelta,
            divider: target.divider,
            availableSize: availableSize,
            leadingVisibleInset: leadingVisibleInset,
            minimumSizeByPaneID: minimumSizeByPaneID
        )
    }

    @discardableResult
    private mutating func resizeColumnWidth(
        at columnIndex: Int,
        widthDelta: CGFloat,
        divider: PaneDivider,
        availableSize: CGSize,
        leadingVisibleInset: CGFloat,
        minimumSizeByPaneID: [PaneID: PaneMinimumSize]
    ) -> Bool {
        let minimumWidth = minimumColumnWidth(
            for: columns[columnIndex],
            minimumSizeByPaneID: minimumSizeByPaneID
        )
        let maximumWidth = maximumColumnWidth(
            for: availableSize.width,
            leadingVisibleInset: leadingVisibleInset
        )
        let currentTotalColumnWidth = totalColumnWidth
        let minimumTotalWidth = minimumTotalColumnWidth(
            for: availableSize.width,
            leadingVisibleInset: leadingVisibleInset
        )
        let otherColumnWidths = currentTotalColumnWidth - columns[columnIndex].width
        let stripFloorMinimumWidth: CGFloat
        if currentTotalColumnWidth <= minimumTotalWidth + 0.001 {
            stripFloorMinimumWidth = columns[columnIndex].width
        } else {
            stripFloorMinimumWidth = max(1, minimumTotalWidth - otherColumnWidths)
        }
        let effectiveMinimumWidth = max(minimumWidth, stripFloorMinimumWidth)
        let proposedWidth = columns[columnIndex].width + widthDelta
        let resolvedWidth = min(maximumWidth, max(effectiveMinimumWidth, proposedWidth))

        guard abs(resolvedWidth - columns[columnIndex].width) > 0.001 else {
            return false
        }

        columns[columnIndex].width = resolvedWidth
        lastInteractedDivider = divider
        return true
    }

    private func adjustedResizeDelta(
        _ delta: CGFloat,
        for divider: PaneDivider
    ) -> CGFloat {
        switch divider {
        case .column(let afterColumnID):
            guard let focusedColumnIndex,
                  let dividerColumnIndex = columns.firstIndex(where: { $0.id == afterColumnID }) else {
                return delta
            }

            return focusedColumnIndex == dividerColumnIndex + 1 ? -delta : delta
        case .pane(let columnID, let afterPaneID):
            guard let focusedColumnIndex,
                  columns.indices.contains(focusedColumnIndex),
                  columns[focusedColumnIndex].id == columnID,
                  let dividerPaneIndex = columns[focusedColumnIndex].panes.firstIndex(where: { $0.id == afterPaneID }) else {
                return delta
            }

            return columns[focusedColumnIndex].focusedPaneIndex == dividerPaneIndex + 1 ? -delta : delta
        }
    }

    private func isFocusedPaneAbove(divider: PaneDivider) -> Bool {
        guard case .pane(let columnID, let afterPaneID) = divider,
              let focusedColumnIndex,
              columns.indices.contains(focusedColumnIndex),
              columns[focusedColumnIndex].id == columnID,
              let dividerPaneIndex = columns[focusedColumnIndex].panes.firstIndex(where: { $0.id == afterPaneID }) else {
            return false
        }

        return columns[focusedColumnIndex].focusedPaneIndex <= dividerPaneIndex
    }

    private func minimumColumnWidth(
        for column: PaneColumnState,
        minimumSizeByPaneID: [PaneID: PaneMinimumSize]
    ) -> CGFloat {
        column.panes
            .map { (minimumSizeByPaneID[$0.id] ?? .fallback).width }
            .max()
            ?? PaneMinimumSize.fallback.width
    }

    private func maximumColumnWidth(
        for availableWidth: CGFloat,
        leadingVisibleInset: CGFloat
    ) -> CGFloat {
        max(
            1,
            layoutSizing.readableWidth(
                for: availableWidth,
                leadingVisibleInset: leadingVisibleInset
            )
        )
    }

    private var totalColumnWidth: CGFloat {
        columns.reduce(0) { $0 + $1.width }
    }

    private func minimumTotalColumnWidth(
        for availableWidth: CGFloat,
        leadingVisibleInset: CGFloat
    ) -> CGFloat {
        let totalSpacing = layoutSizing.interPaneSpacing * CGFloat(max(0, columns.count - 1))
        let visibleWidth = layoutSizing.readableWidth(
            for: availableWidth,
            leadingVisibleInset: leadingVisibleInset
        )
        return max(1, visibleWidth - totalSpacing)
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
