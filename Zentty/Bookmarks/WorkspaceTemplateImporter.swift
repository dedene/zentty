import CoreGraphics
import Foundation

enum WorkspaceTemplateImporter {
    struct Fallback: Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            case missingWorkingDirectory(requested: String, fellBackTo: String)
            case missingCommand(command: String)
        }

        let paneID: PaneID
        let kind: Kind
    }

    struct Result: Equatable, Sendable {
        let worklane: WorklaneState
        let fallbacks: [Fallback]
    }

    static func makeWorklane(
        from template: WorkspaceTemplate,
        worklaneID: WorklaneID,
        fallbackWorkingDirectory: String?,
        windowID: WindowID,
        layoutContext: PaneLayoutContext,
        processEnvironment: [String: String],
        runtimeIdentity: WorklaneRuntimeIdentity = .live,
        commandResolver: ((String) -> Bool)? = nil
    ) -> Result {
        var auxiliaryStateByPaneID: [PaneID: PaneAuxiliaryState] = [:]
        var fallbacks: [Fallback] = []
        let totalColumns = template.columns.count
        let totalWorklanes = 1
        var columnIDByTemplateID: [String: PaneColumnID] = [:]
        let columnIDs = template.columns.map { column -> PaneColumnID in
            let id = runtimeIdentity.makeColumnID()
            if columnIDByTemplateID[column.id] == nil {
                columnIDByTemplateID[column.id] = id
            }
            return id
        }
        let paneIDsByColumn = template.columns.map { column -> [PaneID] in
            column.panes.map { _ in runtimeIdentity.makePaneID() }
        }
        let columnWidths = normalizedColumnWidths(
            for: template,
            layoutContext: layoutContext
        )
        let resolveCommand: (String) -> Bool = commandResolver ?? {
            isCommandOnPath($0, processEnvironment: processEnvironment)
        }

        let columns = template.columns.enumerated().map { columnIndex, templateColumn -> PaneColumnState in
            var paneIDByTemplateID: [String: PaneID] = [:]
            for (paneIndex, pane) in templateColumn.panes.enumerated()
                where paneIDByTemplateID[pane.id] == nil {
                paneIDByTemplateID[pane.id] = paneIDsByColumn[columnIndex][paneIndex]
            }
            let paneCount = templateColumn.panes.count
            let panes = templateColumn.panes.enumerated().map { index, templatePane -> PaneState in
                makePane(
                    paneID: paneIDsByColumn[columnIndex][index],
                    templatePane: templatePane,
                    paneIndex: index,
                    paneCountInColumn: paneCount,
                    totalColumns: totalColumns,
                    totalWorklanes: totalWorklanes,
                    columnWidth: columnWidths[columnIndex],
                    fallbackWorkingDirectory: fallbackWorkingDirectory,
                    windowID: windowID,
                    worklaneID: worklaneID,
                    processEnvironment: processEnvironment,
                    commandResolver: resolveCommand,
                    auxiliaryStateByPaneID: &auxiliaryStateByPaneID,
                    fallbacks: &fallbacks
                )
            }

            return PaneColumnState(
                id: columnIDs[columnIndex],
                panes: panes,
                width: columnWidths[columnIndex],
                paneHeights: templateColumn.paneHeights.map { CGFloat($0) },
                focusedPaneID: templateColumn.focusedPaneID.flatMap { paneIDByTemplateID[$0] },
                lastFocusedPaneID: templateColumn.lastFocusedPaneID.flatMap { paneIDByTemplateID[$0] }
            )
        }

        // Templates need no legacy sanitization: app-created templates were
        // captured through the old title filter (already clean), and
        // hand-edited dotfile titles are deliberate — keep them verbatim.
        let worklane = WorklaneState(
            id: worklaneID,
            title: template.title,
            paneStripState: PaneStripState(
                columns: columns,
                focusedColumnID: template.focusedColumnID.flatMap { columnIDByTemplateID[$0] },
                layoutSizing: layoutContext.sizing
            ),
            nextPaneNumber: max(template.nextPaneNumber, 1),
            auxiliaryStateByPaneID: auxiliaryStateByPaneID,
            color: template.color.flatMap(WorklaneColor.init(rawValue:)),
            bookmarkOriginID: template.id
        )

        return Result(worklane: worklane, fallbacks: fallbacks)
    }

    static func normalizedColumnWidths(
        for template: WorkspaceTemplate,
        layoutContext: PaneLayoutContext
    ) -> [CGFloat] {
        guard template.columns.count != 1 else {
            return [layoutContext.singlePaneWidth]
        }
        guard template.columns.count > 1,
              let capturedReadableWidth = template.capturedReadableWidth,
              capturedReadableWidth > 0
        else {
            return template.columns.map { CGFloat($0.width) }
        }

        let scaleFactor = layoutContext.readableWidth / CGFloat(capturedReadableWidth)
        guard abs(scaleFactor - 1) >= 0.001 else {
            return template.columns.map { CGFloat($0.width) }
        }

        return template.columns.map { max(1, CGFloat($0.width) * scaleFactor) }
    }

    private static func makePane(
        paneID: PaneID,
        templatePane: WorkspaceTemplate.Pane,
        paneIndex: Int,
        paneCountInColumn: Int,
        totalColumns: Int,
        totalWorklanes: Int,
        columnWidth: CGFloat,
        fallbackWorkingDirectory: String?,
        windowID: WindowID,
        worklaneID: WorklaneID,
        processEnvironment: [String: String],
        commandResolver: (String) -> Bool,
        auxiliaryStateByPaneID: inout [PaneID: PaneAuxiliaryState],
        fallbacks: inout [Fallback]
    ) -> PaneState {
        let requested = trimmed(templatePane.workingDirectory) ?? trimmed(fallbackWorkingDirectory)

        let savedCommand = trimmed(templatePane.command)
        let commandOnPath = savedCommand.map { commandResolver($0) } ?? false
        let runnableCommand = commandOnPath ? savedCommand : nil
        let prefillCommand = (!commandOnPath ? savedCommand : nil)

        if let savedCommand, !commandOnPath {
            fallbacks.append(Fallback(paneID: paneID, kind: .missingCommand(command: savedCommand)))
        }

        let inputs = PaneRestorationBuilder.PaneInputs(
            id: paneID,
            titleSeed: templatePane.titleSeed,
            lastActivityTitle: nil,
            requestedWorkingDirectory: requested,
            command: runnableCommand,
            prefillText: prefillCommand,
            environmentOverrides: templatePane.environment,
            surfaceContext: PaneRestorationBuilder.inferredSurfaceContext(
                paneCountInColumn: paneCountInColumn,
                totalColumns: totalColumns,
                totalWorklanes: totalWorklanes,
                paneIndex: paneIndex
            ),
            columnWidth: columnWidth,
            statusTextWhenWorkingDirectoryMissing: "Original path unavailable"
        )

        let result = PaneRestorationBuilder.makePane(
            inputs,
            windowID: windowID,
            worklaneID: worklaneID,
            processEnvironment: processEnvironment
        )
        auxiliaryStateByPaneID[paneID] = result.auxiliary

        if result.didFallBackForWorkingDirectory, let requested {
            fallbacks.append(
                Fallback(
                    paneID: paneID,
                    kind: .missingWorkingDirectory(
                        requested: requested,
                        fellBackTo: result.pane.sessionRequest.workingDirectory ?? ""
                    )
                )
            )
        }

        return result.pane
    }

    static func isCommandOnPath(
        _ command: String,
        processEnvironment: [String: String]
    ) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return false
        }
        let firstToken = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map(String.init) ?? trimmed
        if firstToken.contains("/") {
            return FileManager.default.isExecutableFile(atPath: firstToken)
        }

        let pathString = processEnvironment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        for entry in pathString.split(separator: ":", omittingEmptySubsequences: true) {
            let candidate = String(entry) + "/" + firstToken
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return true
            }
        }
        return false
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}
