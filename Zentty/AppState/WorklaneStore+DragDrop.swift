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

    func reorderPane(
        paneID: PaneID,
        toColumnID: PaneColumnID,
        atPaneIndex paneIndex: Int,
        singleColumnWidth: CGFloat? = nil
    ) {
        guard var worklane = activeWorklane else {
            return
        }

        let resolvedSingleColumnWidth = singleColumnWidth ?? layoutContext.singlePaneWidth
        let previousColumnCount = worklane.paneStripState.columns.count
        guard worklane.paneStripState.movePane(
            id: paneID,
            toColumnID: toColumnID,
            atPaneIndex: paneIndex
        ) else {
            return
        }

        applyColumnWidthNormalization(
            &worklane,
            previousColumnCount: previousColumnCount,
            singleColumnWidth: resolvedSingleColumnWidth
        )

        activeWorklane = worklane
        refreshLastFocusedLocalWorkingDirectory()
        notify(.paneStructure(activeWorklaneID))
    }

    func movePane(
        paneID: PaneID,
        toColumnID: PaneColumnID,
        toPaneIndex: Int,
        singleColumnWidth: CGFloat? = nil
    ) {
        reorderPane(
            paneID: paneID,
            toColumnID: toColumnID,
            atPaneIndex: toPaneIndex,
            singleColumnWidth: singleColumnWidth
        )
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
                return
            }

        case .horizontal:
            guard let targetColumn = worklane.paneStripState.columns.first(where: { column in
                column.panes.contains(where: { $0.id == ontoTargetPaneID })
            }) else {
                return
            }

            guard targetColumn.panes.count == 1 else {
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
        transferPaneToWorklane(
            paneID: paneID,
            targetWorklaneID: targetWorklaneID,
            atPaneIndex: nil,
            singleColumnWidth: singleColumnWidth
        )
    }

    func transferPaneToWorklane(
        paneID: PaneID,
        targetWorklaneID: WorklaneID,
        atPaneIndex flatPaneIndex: Int?,
        singleColumnWidth: CGFloat
    ) {
        guard let sourceIndex = worklanes.firstIndex(where: { $0.id == activeWorklaneID }),
              let targetIndex = worklanes.firstIndex(where: { $0.id == targetWorklaneID }),
              sourceIndex != targetIndex else {
            if targetWorklaneID == activeWorklaneID {
                transferPaneWithinActiveWorklane(
                    paneID: paneID,
                    atPaneIndex: flatPaneIndex,
                    singleColumnWidth: singleColumnWidth
                )
            }
            return
        }

        var sourceWorklane = worklanes[sourceIndex]
        let previousSourceColumnCount = sourceWorklane.paneStripState.columns.count

        guard let removal = sourceWorklane.paneStripState.removePane(
            id: paneID,
            singleColumnWidth: singleColumnWidth
        ) else {
            return
        }

        applyColumnWidthNormalization(
            &sourceWorklane,
            previousColumnCount: previousSourceColumnCount,
            singleColumnWidth: singleColumnWidth
        )

        let auxiliaryState = sourceWorklane.auxiliaryStateByPaneID.removeValue(forKey: paneID)
        worklanes[sourceIndex] = sourceWorklane

        var targetWorklane = worklanes[targetIndex]
        let targetColumnCount = targetWorklane.paneStripState.columns.count
        let insertWidth = targetColumnCount == 0
            ? max(1, singleColumnWidth)
            : max(1, removal.pane.width)

        if targetColumnCount == 1, let firstPaneWidth = layoutContext.firstPaneWidthAfterSingleSplit {
            targetWorklane.paneStripState.resizeFirstColumn(to: firstPaneWidth)
        }

        if let flatPaneIndex, let action = flatInsertionAction(
            for: flatPaneIndex,
            in: targetWorklane.paneStripState
        ) {
            switch action {
            case .asColumn(let index):
                targetWorklane.paneStripState.insertPaneAsColumn(
                    removal.pane,
                    atColumnIndex: index,
                    width: insertWidth
                )
            case .intoColumn(let columnID, let targetPaneID, let localIndex):
                targetWorklane.paneStripState.insertPaneIntoColumn(
                    removal.pane,
                    columnID: columnID,
                    targetPaneID: targetPaneID,
                    atPaneIndex: localIndex,
                    availableHeight: 1200
                )
            }
        } else {
            targetWorklane.paneStripState.insertPaneAsColumn(
                removal.pane,
                atColumnIndex: targetWorklane.paneStripState.columns.count,
                width: insertWidth
            )
        }

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

    // MARK: - Cross-Worklane: New Worklane

    func transferPaneToNewWorklane(
        paneID: PaneID,
        singleColumnWidth: CGFloat
    ) {
        transferPaneToNewWorklane(
            paneID: paneID,
            atIndex: insertionIndexForNewWorklane(anchorWorklaneID: activeWorklaneID),
            singleColumnWidth: singleColumnWidth
        )
    }

    func transferPaneToNewWorklane(
        paneID: PaneID,
        atIndex insertionIndex: Int,
        singleColumnWidth: CGFloat
    ) {
        guard let source = activeWorklane else { return }

        // Moving a worklane's only pane to a new-worklane slot is just moving
        // the worklane itself — reorder it to the slot, preserving its
        // identity (title, state), instead of creating a fresh lane and
        // leaving an empty source behind. Option+drag (duplicate) is
        // unaffected.
        if source.paneStripState.panes.count == 1 {
            guard source.paneStripState.panes.first?.id == paneID,
                  let fromIndex = worklanes.firstIndex(where: { $0.id == source.id })
            else { return }
            let clamped = max(0, min(insertionIndex, worklanes.count))
            moveWorklane(id: source.id, toIndex: clamped > fromIndex ? clamped - 1 : clamped)
            return
        }

        let newWorklaneID = runtimeIdentity.makeWorklaneID()
        let newWorklane = WorklaneState(
            id: newWorklaneID,
            title: nil,
            paneStripState: PaneStripState(columns: [], focusedColumnID: nil),
            nextPaneNumber: 1
        )
        let clampedIndex = max(0, min(insertionIndex, worklanes.count))
        worklanes.insert(newWorklane, at: clampedIndex)

        // transferPaneToWorklane handles notifications. It fires .worklaneListChanged
        // when the source empties (covering both the removal and the addition). When
        // the source still has panes, it fires .paneStructure + .activeWorklaneChanged,
        // so we need to also emit .worklaneListChanged for the new worklane addition.
        let sourceWorklaneID = activeWorklaneID
        transferPaneToWorklane(
            paneID: paneID,
            targetWorklaneID: newWorklaneID,
            singleColumnWidth: singleColumnWidth
        )

        // If source wasn't removed, transferPaneToWorklane didn't fire .worklaneListChanged
        if worklanes.contains(where: { $0.id == sourceWorklaneID }) {
            notify(.worklaneListChanged)
        }
    }

    // MARK: - Cross-Window Transfer

    func canSplitOutPaneToNewWindow(paneID: PaneID) -> Bool {
        guard let sourceWorklane = worklanes.first(where: { worklane in
            worklane.paneStripState.panes.contains { $0.id == paneID }
        }) else {
            return false
        }

        return !(worklanes.count == 1 && sourceWorklane.paneStripState.panes.count == 1)
    }

    @discardableResult
    func splitOutPaneToNewWindow(
        paneID: PaneID,
        destinationWindowID: WindowID
    ) -> PaneSplitOutResult? {
        guard let sourceIndex = worklanes.firstIndex(where: { worklane in
            worklane.paneStripState.panes.contains { $0.id == paneID }
        }) else {
            return nil
        }

        var sourceWorklane = worklanes[sourceIndex]
        guard !(worklanes.count == 1 && sourceWorklane.paneStripState.panes.count == 1) else {
            return nil
        }

        if sourceWorklane.paneStripState.panes.count == 1 {
            var movedWorklane = worklanes.remove(at: sourceIndex)
            if let movedColumnIndex = movedWorklane.paneStripState.columns.firstIndex(where: { column in
                column.panes.contains { $0.id == paneID }
            }),
               let movedPaneIndex = movedWorklane.paneStripState.columns[movedColumnIndex].panes.firstIndex(where: { $0.id == paneID }) {
                retargetPaneForSplitOut(
                    &movedWorklane.paneStripState.columns[movedColumnIndex].panes[movedPaneIndex],
                    destinationWindowID: destinationWindowID,
                    destinationWorklaneID: movedWorklane.id
                )
            }

            if activeWorklaneID == movedWorklane.id {
                let fallbackIndex = min(sourceIndex, worklanes.count - 1)
                if worklanes.indices.contains(fallbackIndex) {
                    activeWorklaneID = worklanes[fallbackIndex].id
                }
            }
            refreshLastFocusedLocalWorkingDirectory()
            notify(.worklaneListChanged)

            return PaneSplitOutResult(
                destinationWorkspaceState: WindowWorkspaceState(
                    worklanes: [movedWorklane],
                    activeWorklaneID: movedWorklane.id
                ),
                movedPaneID: paneID,
                sourceWindowShouldClose: worklanes.isEmpty
            )
        }

        let previousSourceColumnCount = sourceWorklane.paneStripState.columns.count
        guard var removal = sourceWorklane.paneStripState.removePane(
            id: paneID,
            singleColumnWidth: layoutContext.singlePaneWidth
        ) else {
            return nil
        }
        let auxiliaryState = sourceWorklane.auxiliaryStateByPaneID.removeValue(forKey: paneID)

        applyColumnWidthNormalization(
            &sourceWorklane,
            previousColumnCount: previousSourceColumnCount,
            singleColumnWidth: layoutContext.singlePaneWidth
        )

        worklanes[sourceIndex] = sourceWorklane

        removal.pane.width = layoutContext.singlePaneWidth
        let destinationWorklaneID = runtimeIdentity.makeWorklaneID()
        retargetPaneForSplitOut(
            &removal.pane,
            destinationWindowID: destinationWindowID,
            destinationWorklaneID: destinationWorklaneID
        )
        let destinationWorklane = WorklaneState(
            id: destinationWorklaneID,
            title: sourceWorklane.title,
            paneStripState: PaneStripState(
                panes: [removal.pane],
                focusedPaneID: removal.pane.id,
                layoutSizing: layoutContext.sizing
            ),
            nextPaneNumber: sourceWorklane.nextPaneNumber,
            auxiliaryStateByPaneID: auxiliaryState.map { [paneID: $0] } ?? [:],
            color: sourceWorklane.color
        )

        refreshLastFocusedLocalWorkingDirectory()
        notify(.paneStructure(sourceWorklane.id))

        return PaneSplitOutResult(
            destinationWorkspaceState: WindowWorkspaceState(
                worklanes: [destinationWorklane],
                activeWorklaneID: destinationWorklaneID
            ),
            movedPaneID: paneID,
            sourceWindowShouldClose: false
        )
    }

    private func retargetPaneForSplitOut(
        _ pane: inout PaneState,
        destinationWindowID: WindowID,
        destinationWorklaneID: WorklaneID
    ) {
        var request = pane.sessionRequest
        let initialWorkingDirectory = request.environmentVariables["ZENTTY_INITIAL_WORKING_DIRECTORY"]
            ?? request.workingDirectory

        request.inheritFromPaneID = nil
        request.configInheritanceSourcePaneID = nil
        request.surfaceContext = .window
        request.environmentVariables = sessionEnvironment(
            windowID: destinationWindowID,
            worklaneID: destinationWorklaneID,
            paneID: pane.id,
            initialWorkingDirectory: initialWorkingDirectory
        )
        pane.sessionRequest = request
    }

    // MARK: - Cross-Window Move (into existing worklane)

    struct ExtractedPanePayload {
        var pane: PaneState
        let auxiliary: PaneAuxiliaryState?
        let sourceWorklaneRemoved: Bool
        let sourceWindowShouldClose: Bool
    }

    /// Removes a pane from its current worklane in preparation for cross-window
    /// transfer into a different `WorklaneStore`. Mirrors the removal half of
    /// `transferPaneToWorklane(...)` plus the source-worklane-empty bookkeeping
    /// from `splitOutPaneToNewWindow(...)`.
    func extractPaneForCrossWindowTransfer(
        paneID: PaneID,
        singleColumnWidth: CGFloat
    ) -> ExtractedPanePayload? {
        guard let sourceIndex = worklanes.firstIndex(where: { worklane in
            worklane.paneStripState.panes.contains { $0.id == paneID }
        }) else {
            return nil
        }

        var sourceWorklane = worklanes[sourceIndex]
        let previousSourceColumnCount = sourceWorklane.paneStripState.columns.count

        guard let removal = sourceWorklane.paneStripState.removePane(
            id: paneID,
            singleColumnWidth: singleColumnWidth
        ) else {
            return nil
        }

        applyColumnWidthNormalization(
            &sourceWorklane,
            previousColumnCount: previousSourceColumnCount,
            singleColumnWidth: singleColumnWidth
        )

        let auxiliaryState = sourceWorklane.auxiliaryStateByPaneID.removeValue(forKey: paneID)
        worklanes[sourceIndex] = sourceWorklane

        let sourceWorklaneID = sourceWorklane.id
        let sourceIsEmpty = sourceWorklane.paneStripState.columns.isEmpty
        var sourceWorklaneRemoved = false

        if sourceIsEmpty {
            worklanes.remove(at: sourceIndex)
            sourceWorklaneRemoved = true
            if activeWorklaneID == sourceWorklaneID, let first = worklanes.first {
                activeWorklaneID = first.id
            }
        }

        let sourceWindowShouldClose = worklanes.allSatisfy { $0.paneStripState.panes.isEmpty }

        refreshLastFocusedLocalWorkingDirectory()

        if sourceWorklaneRemoved {
            notify(.worklaneListChanged)
        } else {
            notify(.paneStructure(sourceWorklaneID))
        }

        return ExtractedPanePayload(
            pane: removal.pane,
            auxiliary: auxiliaryState,
            sourceWorklaneRemoved: sourceWorklaneRemoved,
            sourceWindowShouldClose: sourceWindowShouldClose
        )
    }

    /// Inserts a pane previously produced by `extractPaneForCrossWindowTransfer`
    /// into the named target worklane (assumed to live in this store's window).
    /// Appends as a new rightmost column sized to this store's `singleColumnWidth`,
    /// since the source's column width is relative to a different layout context.
    /// Returns `true` on success; `false` if the target worklane no longer exists.
    @discardableResult
    func insertExtractedPane(
        _ payload: ExtractedPanePayload,
        intoWorklane targetWorklaneID: WorklaneID,
        singleColumnWidth: CGFloat
    ) -> Bool {
        guard let targetIndex = worklanes.firstIndex(where: { $0.id == targetWorklaneID }) else {
            return false
        }

        var targetWorklane = worklanes[targetIndex]
        let targetColumnCount = targetWorklane.paneStripState.columns.count
        var pane = payload.pane
        let insertWidth = max(1, singleColumnWidth)

        retargetPaneForSplitOut(
            &pane,
            destinationWindowID: windowID,
            destinationWorklaneID: targetWorklaneID
        )

        if targetColumnCount == 1, let firstPaneWidth = layoutContext.firstPaneWidthAfterSingleSplit {
            targetWorklane.paneStripState.resizeFirstColumn(to: firstPaneWidth)
        }

        targetWorklane.paneStripState.insertPaneAsColumn(
            pane,
            atColumnIndex: targetWorklane.paneStripState.columns.count,
            width: insertWidth
        )

        if let auxiliaryState = payload.auxiliary {
            targetWorklane.auxiliaryStateByPaneID[pane.id] = auxiliaryState
        }

        worklanes[targetIndex] = targetWorklane
        activeWorklaneID = targetWorklaneID
        refreshLastFocusedLocalWorkingDirectory()

        notify(.paneStructure(targetWorklaneID))
        notify(.activeWorklaneChanged)
        return true
    }

    // MARK: - Duplicate Pane

    func duplicatePaneToWorklane(
        paneID: PaneID,
        targetWorklaneID: WorklaneID,
        singleColumnWidth: CGFloat
    ) {
        duplicatePaneToWorklane(
            paneID: paneID,
            targetWorklaneID: targetWorklaneID,
            atPaneIndex: nil,
            singleColumnWidth: singleColumnWidth
        )
    }

    func duplicatePaneToWorklane(
        paneID: PaneID,
        targetWorklaneID: WorklaneID,
        atPaneIndex flatPaneIndex: Int?,
        singleColumnWidth: CGFloat
    ) {
        guard let sourceWorklane = worklanes.first(where: { $0.paneStripState.columns.contains(where: { $0.panes.contains(where: { $0.id == paneID }) }) }),
              let targetIndex = worklanes.firstIndex(where: { $0.id == targetWorklaneID }) else {
            return
        }

        // Read CWD and process info from source pane's auxiliary state
        let auxiliaryState = sourceWorklane.auxiliaryStateByPaneID[paneID]
        let workingDirectory = auxiliaryState?.raw.shellContext?.path
        let command = duplicateCommand(auxiliaryState: auxiliaryState)
        let sourceColumnWidth = sourceWorklane.paneStripState.columns
            .first(where: { $0.panes.contains(where: { $0.id == paneID }) })?
            .width ?? layoutContext.singlePaneWidth

        var targetWorklane = worklanes[targetIndex]

        let existingCount = targetWorklane.paneStripState.columns.count
        let newPane = makePaneWithDirectory(
            in: &targetWorklane,
            existingPaneCount: existingCount,
            workingDirectory: workingDirectory,
            sourceShellContext: auxiliaryState?.raw.shellContext,
            command: command
        )

        let targetColumnCount = targetWorklane.paneStripState.columns.count
        let insertWidth = sourceColumnWidth > 0
            ? sourceColumnWidth
            : layoutContext.singlePaneWidth

        if targetColumnCount == 1, let firstPaneWidth = layoutContext.firstPaneWidthAfterSingleSplit {
            targetWorklane.paneStripState.resizeFirstColumn(to: firstPaneWidth)
        }

        if let flatPaneIndex, let action = flatInsertionAction(
            for: flatPaneIndex,
            in: targetWorklane.paneStripState
        ) {
            switch action {
            case .asColumn(let index):
                targetWorklane.paneStripState.insertPaneAsColumn(
                    newPane,
                    atColumnIndex: index,
                    width: insertWidth
                )
            case .intoColumn(let columnID, let targetPaneID, let localIndex):
                guard targetWorklane.paneStripState.insertPaneIntoColumn(
                    newPane,
                    columnID: columnID,
                    targetPaneID: targetPaneID,
                    atPaneIndex: localIndex,
                    availableHeight: 1200
                ) else {
                    return
                }
            }
        } else {
            targetWorklane.paneStripState.insertPaneAsColumn(
                newPane,
                atColumnIndex: targetWorklane.paneStripState.columns.count,
                width: insertWidth
            )
        }

        worklanes[targetIndex] = targetWorklane
        activeWorklaneID = targetWorklaneID
        refreshLastFocusedLocalWorkingDirectory()
        notify(.activeWorklaneChanged)
    }

    func duplicatePaneToNewWorklane(
        paneID: PaneID,
        singleColumnWidth: CGFloat
    ) {
        duplicatePaneToNewWorklane(
            paneID: paneID,
            atIndex: insertionIndexForNewWorklane(anchorWorklaneID: activeWorklaneID),
            singleColumnWidth: singleColumnWidth
        )
    }

    func duplicatePaneToNewWorklane(
        paneID: PaneID,
        atIndex insertionIndex: Int,
        singleColumnWidth: CGFloat
    ) {
        let newWorklaneID = runtimeIdentity.makeWorklaneID()
        let newWorklane = WorklaneState(
            id: newWorklaneID,
            title: nil,
            paneStripState: PaneStripState(columns: [], focusedColumnID: nil),
            nextPaneNumber: 1
        )
        let clampedIndex = max(0, min(insertionIndex, worklanes.count))
        worklanes.insert(newWorklane, at: clampedIndex)

        // duplicatePaneToWorklane fires .activeWorklaneChanged but not .worklaneListChanged
        duplicatePaneToWorklane(
            paneID: paneID,
            targetWorklaneID: newWorklaneID,
            singleColumnWidth: singleColumnWidth
        )
        notify(.worklaneListChanged)
    }

    // MARK: - Same-Worklane Duplicate

    func duplicatePaneAsColumn(
        paneID: PaneID,
        toColumnIndex: Int,
        singleColumnWidth: CGFloat
    ) {
        guard var worklane = activeWorklane,
              let source = duplicateSourceInfo(for: paneID, in: worklane) else {
            return
        }

        let previousColumnCount = worklane.paneStripState.columns.count
        let newPane = makePaneWithDirectory(
            in: &worklane,
            existingPaneCount: previousColumnCount,
            workingDirectory: source.workingDirectory,
            sourceShellContext: source.shellContext,
            command: source.command
        )

        worklane.paneStripState.insertPaneAsColumn(
            newPane,
            atColumnIndex: toColumnIndex,
            width: source.sourceColumnWidth
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

    func duplicatePaneInColumn(
        paneID: PaneID,
        toColumnID: PaneColumnID,
        atPaneIndex paneIndex: Int,
        availableHeight: CGFloat,
        singleColumnWidth: CGFloat
    ) {
        guard var worklane = activeWorklane,
              let source = duplicateSourceInfo(for: paneID, in: worklane) else {
            return
        }

        let previousColumnCount = worklane.paneStripState.columns.count

        guard let targetPaneID = worklane.paneStripState.columns
            .first(where: { $0.id == toColumnID })?
            .panes.first?.id else {
            return
        }

        let newPane = makePaneWithDirectory(
            in: &worklane,
            existingPaneCount: previousColumnCount,
            workingDirectory: source.workingDirectory,
            sourceShellContext: source.shellContext,
            command: source.command
        )

        guard worklane.paneStripState.insertPaneIntoColumn(
            newPane,
            columnID: toColumnID,
            targetPaneID: targetPaneID,
            atPaneIndex: paneIndex,
            availableHeight: availableHeight
        ) else {
            return
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

    func duplicatePaneSplitDrop(
        paneID: PaneID,
        ontoTargetPaneID: PaneID,
        axis: PaneSplitPreview.Axis,
        leading: Bool,
        availableHeight: CGFloat,
        singleColumnWidth: CGFloat
    ) {
        guard var worklane = activeWorklane,
              let source = duplicateSourceInfo(for: paneID, in: worklane) else {
            return
        }

        let previousColumnCount = worklane.paneStripState.columns.count

        switch axis {
        case .vertical:
            guard let targetColumnID = worklane.paneStripState.columns.first(where: { column in
                column.panes.contains(where: { $0.id == ontoTargetPaneID })
            })?.id else {
                return
            }

            let targetPaneIndex = worklane.paneStripState.columns
                .first(where: { $0.id == targetColumnID })?
                .panes.firstIndex(where: { $0.id == ontoTargetPaneID }) ?? 0
            let insertionIndex = leading ? targetPaneIndex : targetPaneIndex + 1

            let newPane = makePaneWithDirectory(
                in: &worklane,
                existingPaneCount: previousColumnCount,
                workingDirectory: source.workingDirectory,
                sourceShellContext: source.shellContext,
                command: source.command
            )

            guard worklane.paneStripState.insertPaneIntoColumn(
                newPane,
                columnID: targetColumnID,
                targetPaneID: ontoTargetPaneID,
                atPaneIndex: insertionIndex,
                availableHeight: availableHeight
            ) else {
                return
            }

        case .horizontal:
            guard worklane.paneStripState.columns.contains(where: { column in
                column.panes.contains(where: { $0.id == ontoTargetPaneID })
            }) else {
                return
            }

            let newPane = makePaneWithDirectory(
                in: &worklane,
                existingPaneCount: previousColumnCount,
                workingDirectory: source.workingDirectory,
                sourceShellContext: source.shellContext,
                command: source.command
            )

            worklane.paneStripState.insertPaneAdjacentToColumn(
                newPane,
                containingPaneID: ontoTargetPaneID,
                leading: leading,
                width: source.sourceColumnWidth
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

    // MARK: - Same-Worklane Flat Boundary Drop

    private func transferPaneWithinActiveWorklane(
        paneID: PaneID,
        atPaneIndex flatPaneIndex: Int?,
        singleColumnWidth: CGFloat
    ) {
        guard var worklane = activeWorklane,
              let flatPaneIndex else {
            return
        }

        let panes = worklane.paneStripState.panes
        guard let sourceFlatIndex = panes.firstIndex(where: { $0.id == paneID }),
              flatPaneIndex >= 0,
              flatPaneIndex <= panes.count else {
            return
        }

        guard flatPaneIndex != sourceFlatIndex,
              flatPaneIndex != sourceFlatIndex + 1 else {
            return
        }

        let reducedFlatIndex = flatPaneIndex > sourceFlatIndex
            ? flatPaneIndex - 1
            : flatPaneIndex
        var reducedStrip = worklane.paneStripState
        guard reducedStrip.removePane(id: paneID, singleColumnWidth: nil) != nil,
              let action = flatInsertionAction(for: reducedFlatIndex, in: reducedStrip) else {
            return
        }

        let previousColumnCount = worklane.paneStripState.columns.count
        switch action {
        case .asColumn(let index):
            guard let removal = worklane.paneStripState.removePane(id: paneID, singleColumnWidth: nil) else {
                return
            }
            worklane.paneStripState.insertPaneAsColumn(
                removal.pane,
                atColumnIndex: index,
                width: removal.pane.width
            )
        case .intoColumn(let columnID, _, let localIndex):
            guard worklane.paneStripState.movePane(
                id: paneID,
                toColumnID: columnID,
                atPaneIndex: localIndex
            ) else {
                return
            }
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

    // MARK: - Private — Duplicate Source Info

    private struct DuplicateSourceInfo {
        let workingDirectory: String?
        let shellContext: PaneShellContext?
        let command: String?
        let sourceColumnWidth: CGFloat
    }

    private func duplicateSourceInfo(for paneID: PaneID, in worklane: WorklaneState) -> DuplicateSourceInfo? {
        let auxiliaryState = worklane.auxiliaryStateByPaneID[paneID]
        let workingDirectory = auxiliaryState?.raw.shellContext?.path
        let shellContext = auxiliaryState?.raw.shellContext
        let command = duplicateCommand(auxiliaryState: auxiliaryState)
        let sourceColumnWidth = worklane.paneStripState.columns
            .first(where: { $0.panes.contains(where: { $0.id == paneID }) })?
            .width ?? 0
        return DuplicateSourceInfo(
            workingDirectory: workingDirectory,
            shellContext: shellContext,
            command: command,
            sourceColumnWidth: sourceColumnWidth
        )
    }

    private func duplicateCommand(auxiliaryState: PaneAuxiliaryState?) -> String? {
        let shellContext = auxiliaryState?.raw.shellContext
        let metadata = auxiliaryState?.raw.metadata

        // SSH: reconstruct connection command
        if shellContext?.scope == .remote,
           let user = shellContext?.user,
           let host = shellContext?.host {
            return "ssh \(user)@\(host)"
        }

        // Recognized agent — check hook-based agentStatus first, then metadata recognition
        // (which checks both terminal title and processName for broader matching)
        let recognizedTool = auxiliaryState?.raw.agentStatus?.tool
            ?? AgentToolRecognizer.recognize(metadata: metadata)
        if let tool = recognizedTool {
            switch tool {
            case .zentty: return nil
            case .amp: return "amp"
            case .claudeCode: return "claude"
            case .codex: return "codex"
            case .copilot: return "gh copilot"
            case .cursor: return "cursor"
            case .droid: return "droid"
            case .gemini: return "gemini"
            case .kimi: return "kimi"
            case .openCode: return "opencode"
            case .pi: return "pi"
            case .grok: return "grok"
            case .agy: return "agy"
            case .hermes: return "hermes"
            case .custom(let name): return name
            }
        }

        // Known CLI tools — launch bare
        if let name = metadata?.processName,
           ["vim", "nvim", "htop", "top", "btop", "lazygit", "lazydocker"].contains(name) {
            return name
        }

        if let titleCommand = WorklaneContextFormatter.displayMeaningfulTerminalIdentity(for: metadata) {
            return titleCommand
        }

        // Default: shell with inherited CWD, no command override
        return nil
    }

    // MARK: - Private - Flat Index to Column Mapping

    /// Maps a flat pane insertion index (0...paneCount) to where the pane should be placed.
    ///
    /// Returns the appropriate action: `.asColumn(index)` for a new column at that position,
    /// or `.intoColumn(columnID, targetPaneID, localIndex)` for same-column insertion.
    /// Returns nil if the flat pane index is out of range.
    private enum FlatInsertionAction {
        case asColumn(index: Int)
        case intoColumn(columnID: PaneColumnID, targetPaneID: PaneID, localIndex: Int)
    }

    private func flatInsertionAction(
        for flatPaneIndex: Int,
        in strip: PaneStripState
    ) -> FlatInsertionAction? {
        let paneCount = strip.panes.count
        guard flatPaneIndex >= 0, flatPaneIndex <= paneCount else { return nil }

        if flatPaneIndex == 0 { return .asColumn(index: 0) }
        if flatPaneIndex == paneCount { return .asColumn(index: strip.columns.count) }

        // Find the two panes between which we insert
        let panes = strip.panes
        let beforePane = panes[flatPaneIndex - 1]
        let afterPane = panes[flatPaneIndex]

        // Find their column indices
        guard let beforeColIdx = strip.columns.firstIndex(where: { $0.panes.contains(where: { $0.id == beforePane.id }) }),
              let afterColIdx = strip.columns.firstIndex(where: { $0.panes.contains(where: { $0.id == afterPane.id }) }) else {
            return nil
        }

        if beforeColIdx == afterColIdx {
            // Same column: insert between the two panes within that column.
            let column = strip.columns[beforeColIdx]
            guard let beforeLocal = column.panes.firstIndex(where: { $0.id == beforePane.id }) else {
                return nil
            }
            let localInsertionIndex = beforeLocal + 1
            return .intoColumn(columnID: column.id, targetPaneID: afterPane.id, localIndex: localInsertionIndex)
        } else {
            // Different columns: insert as a new column between them.
            return .asColumn(index: afterColIdx)
        }
    }

    func applyColumnWidthNormalization(
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
            return
        }

        guard previousColumnCount > currentColumnCount, currentColumnCount > 1 else {
            return
        }

        let targetTotalColumnWidth = max(
            1,
            layoutContext.sizing.readableWidth(
                for: layoutContext.viewportWidth,
                leadingVisibleInset: layoutContext.leadingVisibleInset
            ) - (layoutContext.sizing.interPaneSpacing * CGFloat(currentColumnCount - 1))
        )
        let currentTotalColumnWidth = worklane.paneStripState.columns.reduce(0) { $0 + $1.width }
        guard currentTotalColumnWidth > 0,
              currentTotalColumnWidth < targetTotalColumnWidth - 0.001 else {
            return
        }

        _ = worklane.paneStripState.scalePaneWidths(by: targetTotalColumnWidth / currentTotalColumnWidth)
    }
}
