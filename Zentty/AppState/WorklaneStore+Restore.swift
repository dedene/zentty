import CoreGraphics
import Foundation

extension WorklaneStore {
    struct RestoreClosedPaneResult: Equatable {
        let restoredPaneID: PaneID
        let restoredWorklaneID: WorklaneID
        let toastMessage: String
    }

    func captureClosedPane(paneID: PaneID, in worklane: WorklaneState) {
        guard let columnIndex = worklane.paneStripState.columns.firstIndex(where: { column in
            column.panes.contains(where: { $0.id == paneID })
        }) else {
            return
        }
        let column = worklane.paneStripState.columns[columnIndex]
        guard let paneIndex = column.panes.firstIndex(where: { $0.id == paneID }) else {
            return
        }
        let pane = column.panes[paneIndex]

        let auxiliary = worklane.auxiliaryStateByPaneID[paneID]

        // Don't capture SSH/remote panes — the cwd, agent session, and CLI
        // all live on the remote host, so a local prefill can't resume them.
        // Matches `SessionRestoreDraftExporter.makePaneDraft`.
        if auxiliary?.shellContext?.scope == .remote {
            return
        }

        let agentSnapshot: ClosedPaneAgentSnapshot? = auxiliary?.agentStatus.map { status in
            ClosedPaneAgentSnapshot(
                tool: status.tool,
                toolDisplayName: status.tool.displayName,
                sessionID: status.sessionID,
                workingDirectory: status.workingDirectory ?? auxiliary?.presentation.cwd
            )
        }

        // Prefer the live cwd (presentation.cwd, updated via OSC 7) over the
        // launch-time workingDirectory in the session request — otherwise we'd
        // restore at the directory the pane started in, not where the user
        // navigated to.
        let workingDirectory = trimmedNonEmpty(auxiliary?.presentation.cwd)
            ?? trimmedNonEmpty(auxiliary?.shellContext?.path)
            ?? trimmedNonEmpty(pane.sessionRequest.workingDirectory)

        let scrollbackText = scrollbackProvider?(paneID)

        let originalHeightInColumn: CGFloat? = column.panes.count > 1
            && column.paneHeights.indices.contains(paneIndex)
            ? column.paneHeights[paneIndex]
            : nil

        let entry = ClosedPaneEntry(
            closedAt: currentDateProvider(),
            originalPaneID: paneID,
            originalWorklaneID: worklane.id,
            originalColumnID: column.id,
            originalColumnIndex: columnIndex,
            originalPaneIndex: paneIndex,
            originalColumnWidth: column.width,
            originalHeightInColumn: originalHeightInColumn,
            title: pane.title,
            workingDirectory: workingDirectory,
            originalNativeCommand: pane.sessionRequest.nativeCommand,
            originalCommand: pane.sessionRequest.command,
            agentSnapshot: agentSnapshot,
            scrollbackText: scrollbackText
        )

        closedPaneStack.push(entry, now: currentDateProvider())
    }

    @discardableResult
    func restoreClosedPane() -> RestoreClosedPaneResult? {
        let now = currentDateProvider()
        guard let entry = closedPaneStack.popLatest(now: now) else {
            return nil
        }

        let cwdResolution = ClosedPaneCWDResolver.resolve(original: entry.workingDirectory)
        let outcome = ClosedPaneRestoreCommandResolver.resolve(entry: entry)

        let scrollbackURL: URL? = {
            guard let text = entry.scrollbackText,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            return ClosedPaneScrollbackArchive.write(scrollback: text, entryID: entry.id)
        }()

        let runCommand: String?
        let toastBody: String
        switch outcome {
        case .agentResume(let command, let tool, _):
            runCommand = command
            toastBody = "Restored \"\(entry.title)\" — \(tool.displayName) resuming at \(cwdResolution.path)"
        case .replayCommand(let command):
            runCommand = command
            toastBody = "Restored \"\(entry.title)\" at \(cwdResolution.path)"
        case .plainShell:
            runCommand = nil
            toastBody = "Restored \"\(entry.title)\" at \(cwdResolution.path)"
        }

        // Both the previous-output hint and the resume/replay command are
        // typed into the live shell via prefillText. That way the shell's
        // own PATH resolves the binary (avoiding the launch-environment PATH
        // pitfall where /opt/homebrew/bin etc. are missing), and the user
        // ends up with a normal shell after the agent exits — not a closed
        // pane.
        let prefillText = makeRestorePrefill(
            scrollbackURL: scrollbackURL,
            command: runCommand
        )

        let toastMessage: String = {
            if cwdResolution.originalMissing {
                return toastBody + " — original directory missing"
            }
            return toastBody
        }()

        let newPaneID = runtimeIdentity.makePaneID()
        let sessionRequest = TerminalSessionRequest(
            workingDirectory: cwdResolution.path,
            command: nil,
            nativeCommand: nil,
            waitAfterNativeCommand: false,
            isLaunchDeferred: false,
            prefillText: prefillText,
            inheritFromPaneID: nil,
            configInheritanceSourcePaneID: nil,
            surfaceContext: .split,
            environmentVariables: sessionEnvironment(
                windowID: windowID,
                worklaneID: entry.originalWorklaneID,
                paneID: newPaneID,
                initialWorkingDirectory: cwdResolution.path
            )
        )

        let restoredPane = PaneState(
            id: newPaneID,
            title: entry.title,
            sessionRequest: sessionRequest,
            width: entry.originalColumnWidth
        )

        guard let target = resolveRestoreTarget(for: entry) else {
            return nil
        }

        if activeWorklaneID != target.worklaneID {
            selectWorklane(id: target.worklaneID)
        }

        guard let worklaneIndex = worklanes.firstIndex(where: { $0.id == target.worklaneID }) else {
            return nil
        }

        var worklane = worklanes[worklaneIndex]
        let initialAuxiliary = makeRestoredPaneAuxiliary(
            for: restoredPane,
            workingDirectory: cwdResolution.path
        )
        worklane.auxiliaryStateByPaneID[newPaneID] = initialAuxiliary

        insertRestoredPane(
            restoredPane,
            into: &worklane,
            target: target,
            originalHeightInColumn: entry.originalHeightInColumn
        )
        worklanes[worklaneIndex] = worklane
        recomputePresentation(for: newPaneID, in: &worklanes[worklaneIndex])
        refreshLastFocusedLocalWorkingDirectory()
        notify(.paneStructure(target.worklaneID))

        return RestoreClosedPaneResult(
            restoredPaneID: newPaneID,
            restoredWorklaneID: target.worklaneID,
            toastMessage: toastMessage
        )
    }

    private struct RestoreTarget {
        let worklaneID: WorklaneID
        let columnID: PaneColumnID?
        let columnIndex: Int
        let paneIndex: Int
    }

    private func resolveRestoreTarget(for entry: ClosedPaneEntry) -> RestoreTarget? {
        if let worklaneIndex = worklanes.firstIndex(where: { $0.id == entry.originalWorklaneID }) {
            let worklane = worklanes[worklaneIndex]
            if let columnIndex = worklane.paneStripState.columns.firstIndex(where: { $0.id == entry.originalColumnID }) {
                let columnID = worklane.paneStripState.columns[columnIndex].id
                let paneCount = worklane.paneStripState.columns[columnIndex].panes.count
                let paneIndex = max(0, min(entry.originalPaneIndex, paneCount))
                return RestoreTarget(
                    worklaneID: worklane.id,
                    columnID: columnID,
                    columnIndex: columnIndex,
                    paneIndex: paneIndex
                )
            }

            return RestoreTarget(
                worklaneID: worklane.id,
                columnID: nil,
                columnIndex: max(0, min(entry.originalColumnIndex, worklane.paneStripState.columns.count)),
                paneIndex: 0
            )
        }

        guard let activeIndex = worklanes.firstIndex(where: { $0.id == activeWorklaneID }) else {
            return nil
        }

        let worklane = worklanes[activeIndex]
        return RestoreTarget(
            worklaneID: worklane.id,
            columnID: worklane.paneStripState.focusedColumnID,
            columnIndex: max(0, worklane.paneStripState.columns.count),
            paneIndex: 0
        )
    }

    private func insertRestoredPane(
        _ pane: PaneState,
        into worklane: inout WorklaneState,
        target: RestoreTarget,
        originalHeightInColumn: CGFloat?
    ) {
        if let columnID = target.columnID,
           let columnIndex = worklane.paneStripState.columns.firstIndex(where: { $0.id == columnID }),
           let anchorPane = worklane.paneStripState.columns[columnIndex].panes.first
        {
            let inserted = worklane.paneStripState.insertPaneIntoColumn(
                pane,
                columnID: worklane.paneStripState.columns[columnIndex].id,
                targetPaneID: anchorPane.id,
                atPaneIndex: target.paneIndex,
                availableHeight: paneViewportHeightSnapshot
            )
            if inserted {
                applyOriginalHeight(
                    paneID: pane.id,
                    columnIndex: columnIndex,
                    originalHeight: originalHeightInColumn,
                    in: &worklane.paneStripState
                )
                return
            }
        }

        // Falling through to a brand-new column: honor the captured column
        // width so a re-introduced column lands at its original size.
        let columnIndex = max(0, min(target.columnIndex, worklane.paneStripState.columns.count))
        let width = restoredColumnWidth(
            preferred: pane.width,
            existingColumnCount: worklane.paneStripState.columns.count
        )
        var paneWithWidth = pane
        paneWithWidth.width = width
        worklane.paneStripState.insertPaneAsColumn(
            paneWithWidth,
            atColumnIndex: columnIndex,
            width: width
        )
    }

    /// `insertPaneIntoColumn` calls `equalizePaneHeights()` which resets every
    /// pane's weight to 1. We override the inserted pane's weight to its
    /// captured value so its proportional height comes back. Sibling weights
    /// stay at 1, so the inserted pane gets an outsized share if its original
    /// weight was larger than 1 (and a smaller share if it was smaller).
    private func applyOriginalHeight(
        paneID: PaneID,
        columnIndex: Int,
        originalHeight: CGFloat?,
        in paneStripState: inout PaneStripState
    ) {
        guard let originalHeight,
              originalHeight > 0,
              paneStripState.columns.indices.contains(columnIndex) else {
            return
        }
        let column = paneStripState.columns[columnIndex]
        guard let paneSlot = column.panes.firstIndex(where: { $0.id == paneID }),
              column.paneHeights.indices.contains(paneSlot) else {
            return
        }
        paneStripState.columns[columnIndex].paneHeights[paneSlot] = originalHeight
    }

    /// Clamps the captured column width to a sensible range so a stale entry
    /// (worklane resized smaller, viewport changed, …) can't produce a
    /// negative or absurdly wide column on restore.
    private func restoredColumnWidth(preferred: CGFloat, existingColumnCount: Int) -> CGFloat {
        let fallback = layoutContext.newPaneWidth(existingPaneCount: existingColumnCount)
        guard preferred.isFinite, preferred > 0 else {
            return fallback
        }
        let minimum = max(1, layoutContext.singlePaneWidth * 0.25)
        let available = max(minimum, layoutContext.availableWidth)
        return min(max(preferred, minimum), available)
    }

    private func makeRestoredPaneAuxiliary(
        for pane: PaneState,
        workingDirectory: String
    ) -> PaneAuxiliaryState {
        let initialShellContext = PaneShellContext(
            scope: .local,
            path: workingDirectory,
            home: processEnvironmentSnapshot["HOME"],
            user: processEnvironmentSnapshot["USER"],
            host: nil
        )
        let initialRaw = PaneRawState(shellContext: initialShellContext)
        let initialPresentation = PanePresentationNormalizer.normalize(
            paneTitle: pane.title,
            raw: initialRaw,
            previous: nil,
            sessionRequestWorkingDirectory: workingDirectory
        )
        return PaneAuxiliaryState(
            raw: initialRaw,
            presentation: initialPresentation
        )
    }

    /// Builds the text typed into the restored pane's shell once it's ready.
    /// Each line ends in `\n` so the shell auto-executes it. Lines:
    ///   1. (optional) `printf` of `Previous output: file://…` so the user can
    ///       click the link in the terminal to open the captured scrollback.
    ///   2. (optional) the resume / replay command.
    /// Returns nil when there's nothing to type — the user just gets a fresh
    /// shell at the resolved CWD.
    private func makeRestorePrefill(scrollbackURL: URL?, command: String?) -> String? {
        var lines: [String] = []
        if let url = scrollbackURL {
            // Single-quote the URL; UUID-based filenames cannot contain `'`,
            // so this is safe without further escaping.
            lines.append("printf '\\nPrevious output: \(url.absoluteString)\\n\\n'")
        }
        if let trimmed = command?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty {
            lines.append(trimmed)
        }
        guard !lines.isEmpty else { return nil }
        // Each line ends with a newline so the shell submits it.
        return lines.map { "\($0)\n" }.joined()
    }

    private func trimmedNonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
