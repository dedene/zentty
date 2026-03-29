import CoreGraphics

extension WorklaneStore {

    // MARK: - Same-Worklane Reorder

    func reorderPane(paneID: PaneID, toColumnIndex: Int, singleColumnWidth: CGFloat) {
        guard var worklane = activeWorklane else {
            return
        }

        let previousColumnCount = worklane.paneStripState.columns.count

        guard let removal = worklane.paneStripState.removePane(id: paneID, singleColumnWidth: nil) else {
            return
        }

        let adjustedIndex: Int
        if toColumnIndex > removal.columnIndex {
            adjustedIndex = toColumnIndex - 1
        } else {
            adjustedIndex = toColumnIndex
        }

        worklane.paneStripState.insertPaneAsColumn(
            removal.pane,
            atColumnIndex: adjustedIndex,
            width: removal.pane.width
        )

        applyColumnWidthNormalization(
            &worklane,
            previousColumnCount: previousColumnCount,
            singleColumnWidth: singleColumnWidth
        )

        activeWorklane = worklane
        refreshLastFocusedLocalWorkingDirectory()
        notify(.paneStructure(activeWorklaneID))
    }

    // MARK: - Same-Worklane Split Drop

    func splitDropPane(
        paneID: PaneID,
        ontoTargetPaneID: PaneID,
        axis: PaneSplitPreview.Axis,
        leading: Bool,
        availableHeight: CGFloat,
        singleColumnWidth: CGFloat
    ) {
        guard var worklane = activeWorklane else {
            return
        }

        let previousColumnCount = worklane.paneStripState.columns.count

        guard let removal = worklane.paneStripState.removePane(id: paneID, singleColumnWidth: nil) else {
            return
        }

        switch axis {
        case .vertical:
            guard let targetColumnID = worklane.paneStripState.columns.first(where: { column in
                column.panes.contains(where: { $0.id == ontoTargetPaneID })
            })?.id else {
                worklane.paneStripState.insertPaneAsColumn(
                    removal.pane,
                    atColumnIndex: removal.columnIndex,
                    width: removal.pane.width
                )
                activeWorklane = worklane
                refreshLastFocusedLocalWorkingDirectory()
                notify(.paneStructure(activeWorklaneID))
                return
            }

            let targetPaneIndex = worklane.paneStripState.columns
                .first(where: { $0.id == targetColumnID })?
                .panes.firstIndex(where: { $0.id == ontoTargetPaneID }) ?? 0
            let insertionIndex = leading ? targetPaneIndex : targetPaneIndex + 1

            if !worklane.paneStripState.insertPaneIntoColumn(
                removal.pane,
                columnID: targetColumnID,
                targetPaneID: ontoTargetPaneID,
                atPaneIndex: insertionIndex,
                availableHeight: availableHeight
            ) {
                worklane.paneStripState.insertPaneAsColumn(
                    removal.pane,
                    atColumnIndex: removal.columnIndex,
                    width: removal.pane.width
                )
                activeWorklane = worklane
                refreshLastFocusedLocalWorkingDirectory()
                notify(.paneStructure(activeWorklaneID))
                return
            }

        case .horizontal:
            guard let targetColumn = worklane.paneStripState.columns.first(where: { column in
                column.panes.contains(where: { $0.id == ontoTargetPaneID })
            }) else {
                worklane.paneStripState.insertPaneAsColumn(
                    removal.pane,
                    atColumnIndex: removal.columnIndex,
                    width: removal.pane.width
                )
                activeWorklane = worklane
                refreshLastFocusedLocalWorkingDirectory()
                notify(.paneStructure(activeWorklaneID))
                return
            }

            let splitWidth = max(1, targetColumn.width / 2)

            if let targetIndex = worklane.paneStripState.columns.firstIndex(where: { $0.id == targetColumn.id }) {
                worklane.paneStripState.columns[targetIndex].width = splitWidth
            }

            worklane.paneStripState.insertPaneAdjacentToColumn(
                removal.pane,
                containingPaneID: ontoTargetPaneID,
                leading: leading,
                width: splitWidth
            )
        }

        applyColumnWidthNormalization(
            &worklane,
            previousColumnCount: previousColumnCount,
            singleColumnWidth: singleColumnWidth
        )

        activeWorklane = worklane
        refreshLastFocusedLocalWorkingDirectory()
        notify(.paneStructure(activeWorklaneID))
    }

    // MARK: - Cross-Worklane Transfer

    func transferPaneToWorklane(
        paneID: PaneID,
        targetWorklaneID: WorklaneID,
        singleColumnWidth: CGFloat
    ) {
        guard let sourceIndex = worklanes.firstIndex(where: { $0.id == activeWorklaneID }),
              let targetIndex = worklanes.firstIndex(where: { $0.id == targetWorklaneID }),
              sourceIndex != targetIndex else {
            return
        }

        var sourceWorklane = worklanes[sourceIndex]

        guard let removal = sourceWorklane.paneStripState.removePane(
            id: paneID,
            singleColumnWidth: singleColumnWidth
        ) else {
            return
        }

        let auxiliaryState = sourceWorklane.auxiliaryStateByPaneID.removeValue(forKey: paneID)
        worklanes[sourceIndex] = sourceWorklane

        var targetWorklane = worklanes[targetIndex]
        let targetColumnCount = targetWorklane.paneStripState.columns.count
        let insertWidth: CGFloat
        if targetColumnCount == 0 {
            insertWidth = layoutContext.singlePaneWidth
        } else {
            insertWidth = layoutContext.newPaneWidth(existingPaneCount: targetColumnCount)
        }

        if targetColumnCount == 1, let firstPaneWidth = layoutContext.firstPaneWidthAfterSingleSplit {
            targetWorklane.paneStripState.resizeFirstColumn(to: firstPaneWidth)
        }

        targetWorklane.paneStripState.insertPaneAsColumn(
            removal.pane,
            atColumnIndex: targetWorklane.paneStripState.columns.count,
            width: insertWidth
        )

        if let auxiliaryState {
            targetWorklane.auxiliaryStateByPaneID[paneID] = auxiliaryState
        }

        worklanes[targetIndex] = targetWorklane

        let sourceWorklaneID = sourceWorklane.id
        let sourceIsEmpty = sourceWorklane.paneStripState.columns.isEmpty

        if sourceIsEmpty, worklanes.count > 1 {
            worklanes.remove(at: worklanes.firstIndex(where: { $0.id == sourceWorklaneID })!)
        }

        activeWorklaneID = targetWorklaneID
        refreshLastFocusedLocalWorkingDirectory()

        if sourceIsEmpty {
            notify(.worklaneListChanged)
        } else {
            notify(.paneStructure(sourceWorklaneID))
            notify(.activeWorklaneChanged)
        }
    }

    // MARK: - Private

    private func applyColumnWidthNormalization(
        _ worklane: inout WorklaneState,
        previousColumnCount: Int,
        singleColumnWidth: CGFloat
    ) {
        let currentColumnCount = worklane.paneStripState.columns.count

        if previousColumnCount == 1, currentColumnCount == 2,
           let firstPaneWidth = layoutContext.firstPaneWidthAfterSingleSplit {
            worklane.paneStripState.resizeFirstColumn(to: firstPaneWidth)
        }

        if previousColumnCount == 2, currentColumnCount == 1 {
            worklane.paneStripState.columns[0].width = max(1, singleColumnWidth)
        }
    }
}
