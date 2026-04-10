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

            guard targetColumn.panes.count == 1 else {
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

    // MARK: - Cross-Worklane: New Worklane

    func transferPaneToNewWorklane(
        paneID: PaneID,
        singleColumnWidth: CGFloat
    ) {
        // Prevent transferring the last pane — would leave an empty worklane.
        // Option+drag (duplicate) is unaffected.
        guard let source = activeWorklane,
              source.paneStripState.panes.count > 1 else {
            return
        }

        let n = nextWorklaneNumber()
        let newWorklaneID = runtimeIdentity.makeWorklaneID()
        let newWorklane = WorklaneState(
            id: newWorklaneID,
            title: "WS \(n)",
            paneStripState: PaneStripState(columns: [], focusedColumnID: nil),
            nextPaneNumber: 1
        )
        worklanes.append(newWorklane)

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

    // MARK: - Duplicate Pane

    func duplicatePaneToWorklane(
        paneID: PaneID,
        targetWorklaneID: WorklaneID,
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
            newPane,
            atColumnIndex: targetWorklane.paneStripState.columns.count,
            width: insertWidth
        )

        worklanes[targetIndex] = targetWorklane
        activeWorklaneID = targetWorklaneID
        refreshLastFocusedLocalWorkingDirectory()
        notify(.activeWorklaneChanged)
    }

    func duplicatePaneToNewWorklane(
        paneID: PaneID,
        singleColumnWidth: CGFloat
    ) {
        let n = nextWorklaneNumber()
        let newWorklaneID = runtimeIdentity.makeWorklaneID()
        let newWorklane = WorklaneState(
            id: newWorklaneID,
            title: "WS \(n)",
            paneStripState: PaneStripState(columns: [], focusedColumnID: nil),
            nextPaneNumber: 1
        )
        worklanes.append(newWorklane)

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

        worklane.paneStripState.insertPaneIntoColumn(
            newPane,
            columnID: toColumnID,
            targetPaneID: targetPaneID,
            atPaneIndex: paneIndex,
            availableHeight: availableHeight
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
        let newPane = makePaneWithDirectory(
            in: &worklane,
            existingPaneCount: previousColumnCount,
            workingDirectory: source.workingDirectory,
            sourceShellContext: source.shellContext,
            command: source.command
        )

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

            worklane.paneStripState.insertPaneIntoColumn(
                newPane,
                columnID: targetColumnID,
                targetPaneID: ontoTargetPaneID,
                atPaneIndex: insertionIndex,
                availableHeight: availableHeight
            )

        case .horizontal:
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
            case .claudeCode: return "claude"
            case .codex: return "codex"
            case .copilot: return "gh copilot"
            case .openCode: return "opencode"
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

    // MARK: - Private — Column Width

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
