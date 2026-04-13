import AppKit
import QuartzCore

extension PaneStripView {
    func insertionTransition(
        from previousPresentation: StripPresentation?,
        previousOffset: CGFloat,
        to nextPresentation: StripPresentation
    ) -> PaneInsertionTransition? {
        guard let previousPresentation else {
            return nil
        }

        let previousPaneIDs = Set(previousPresentation.panes.map(\.paneID))
        let nextPaneIDs = Set(nextPresentation.panes.map(\.paneID))
        let insertedPaneIDs = nextPaneIDs.subtracting(previousPaneIDs)
        let removedPaneIDs = previousPaneIDs.subtracting(nextPaneIDs)

        guard insertedPaneIDs.count == 1, removedPaneIDs.isEmpty else {
            return nil
        }

        guard
            let insertedPaneID = insertedPaneIDs.first,
            let insertedPane = nextPresentation.panes.first(where: { $0.paneID == insertedPaneID }),
            let insertedColumnIndex = nextPresentation.columns.firstIndex(where: {
                $0.panes.contains(where: { $0.paneID == insertedPaneID })
            })
        else {
            return nil
        }

        let nextColumn = nextPresentation.columns[insertedColumnIndex]
        guard let previousColumnsByID = uniqueColumnsByID(previousPresentation.columns) else {
            return nil
        }

        if let previousColumn = previousColumnsByID[nextColumn.columnID] {
            let spacing = nextColumn.panes.count > 1
                ? nextColumn.panes[0].frame.minY - nextColumn.panes[1].frame.maxY
                : 16
            guard let insertedIndex = nextColumn.panes.firstIndex(where: { $0.paneID == insertedPaneID }) else {
                return nil
            }

            if insertedIndex > 0 {
                let anchorPane = nextColumn.panes[insertedIndex - 1]
                let previousAnchorPane = previousColumn.panes.first(where: { $0.paneID == anchorPane.paneID })
                let initialHeight = min(insertedPane.frame.height, 96)
                let sourceBottom = previousAnchorPane?.frame.minY ?? anchorPane.frame.minY
                let initialFrame = CGRect(
                    x: insertedPane.frame.minX,
                    y: sourceBottom - spacing - initialHeight,
                    width: insertedPane.frame.width,
                    height: initialHeight
                )
                return PaneInsertionTransition(
                    paneID: insertedPaneID,
                    side: .bottom,
                    initialFrame: initialFrame.offsetBy(dx: -previousOffset, dy: 0),
                    columnID: nextColumn.columnID,
                    sourcePaneID: anchorPane.paneID
                )
            }

            if insertedIndex < nextColumn.panes.count - 1 {
                let anchorPane = nextColumn.panes[insertedIndex + 1]
                let previousAnchorPane = previousColumn.panes.first(where: { $0.paneID == anchorPane.paneID })
                return PaneInsertionTransition(
                    paneID: insertedPaneID,
                    side: .top,
                    initialFrame: CGRect(
                        x: insertedPane.frame.minX,
                        y: (previousAnchorPane?.frame.maxY ?? anchorPane.frame.maxY) + spacing,
                        width: insertedPane.frame.width,
                        height: insertedPane.frame.height
                    ).offsetBy(dx: -previousOffset, dy: 0),
                    columnID: nextColumn.columnID,
                    sourcePaneID: anchorPane.paneID
                )
            }

            return nil
        }

        let spacing = nextPresentation.columns.count > 1
            ? nextPresentation.columns[1].frame.minX - nextPresentation.columns[0].frame.maxX
            : 16

        if insertedColumnIndex > 0 {
            let anchorColumn = nextPresentation.columns[insertedColumnIndex - 1]
            let previousAnchorMaxX = previousPresentation.columns
                .first(where: { $0.columnID == anchorColumn.columnID })?.frame.maxX
                ?? anchorColumn.frame.maxX
            return PaneInsertionTransition(
                paneID: insertedPaneID,
                side: .right,
                initialFrame: CGRect(
                    x: previousAnchorMaxX + spacing,
                    y: insertedPane.frame.minY,
                    width: insertedPane.frame.width,
                    height: insertedPane.frame.height
                ).offsetBy(dx: -previousOffset, dy: 0)
            )
        }

        if insertedColumnIndex < nextPresentation.columns.count - 1 {
            let anchorColumn = nextPresentation.columns[insertedColumnIndex + 1]
            return PaneInsertionTransition(
                paneID: insertedPaneID,
                side: .left,
                initialFrame: CGRect(
                    x: anchorColumn.frame.minX - spacing - insertedPane.frame.width,
                    y: insertedPane.frame.minY,
                    width: insertedPane.frame.width,
                    height: insertedPane.frame.height
                ).offsetBy(dx: -previousOffset, dy: 0)
            )
        }

        return nil
    }

    func removalTransition(
        from previousPresentation: StripPresentation?,
        to nextPresentation: StripPresentation
    ) -> PaneRemovalTransition? {
        guard let previousPresentation else {
            return nil
        }

        let previousPaneIDs = Set(previousPresentation.panes.map(\.paneID))
        let nextPaneIDs = Set(nextPresentation.panes.map(\.paneID))
        let removedPaneIDs = previousPaneIDs.subtracting(nextPaneIDs)
        let insertedPaneIDs = nextPaneIDs.subtracting(previousPaneIDs)

        guard !removedPaneIDs.isEmpty, insertedPaneIDs.isEmpty else {
            return nil
        }

        for previousColumn in previousPresentation.columns {
            guard previousColumn.panes.count > 1 else {
                continue
            }
            guard let nextColumn = nextPresentation.columns.first(where: {
                $0.columnID == previousColumn.columnID
            }) else {
                continue
            }
            let columnRemovedIDs = removedPaneIDs.intersection(
                Set(previousColumn.panes.map(\.paneID))
            )
            guard columnRemovedIDs.count == 1 else {
                continue
            }

            let survivingPaneIDs = Set(nextColumn.panes.map(\.paneID))
            guard !survivingPaneIDs.isEmpty else {
                continue
            }

            return PaneRemovalTransition(
                columnID: previousColumn.columnID,
                survivingPaneIDs: survivingPaneIDs
            )
        }

        return nil
    }

    private func uniqueColumnsByID(
        _ columns: [ColumnPresentation]
    ) -> [PaneColumnID: ColumnPresentation]? {
        var columnsByID: [PaneColumnID: ColumnPresentation] = [:]
        columnsByID.reserveCapacity(columns.count)

        for column in columns {
            guard columnsByID.updateValue(column, forKey: column.columnID) == nil else {
                return nil
            }
        }

        return columnsByID
    }
}
