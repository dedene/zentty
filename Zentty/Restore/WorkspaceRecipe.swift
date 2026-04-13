import CoreGraphics
import Foundation

struct WindowWorkspaceState: Equatable, Sendable {
    var worklanes: [WorklaneState]
    var activeWorklaneID: WorklaneID?
}

struct WorkspaceRecipe: Codable, Equatable, Sendable {
    var windows: [Window]
    var activeWindowID: String?

    init(
        windows: [Window],
        activeWindowID: String? = nil
    ) {
        self.windows = windows
        self.activeWindowID = activeWindowID
    }

    struct Window: Codable, Equatable, Sendable {
        var id: String
        var worklanes: [Worklane]
        var activeWorklaneID: String?
    }

    struct Worklane: Codable, Equatable, Sendable {
        var id: String
        var title: String
        var nextPaneNumber: Int
        var focusedColumnID: String?
        var columns: [Column]
    }

    struct Column: Codable, Equatable, Sendable {
        var id: String
        var width: Double
        var focusedPaneID: String?
        var lastFocusedPaneID: String?
        var paneHeights: [Double]
        var panes: [Pane]
    }

    struct Pane: Codable, Equatable, Sendable {
        var id: String
        var titleSeed: String?
        var workingDirectory: String?
    }
}

enum WorkspaceRecipeExporter {
    static func makeWindow(
        windowID: WindowID,
        worklanes: [WorklaneState],
        activeWorklaneID: WorklaneID?
    ) -> WorkspaceRecipe.Window {
        WorkspaceRecipe.Window(
            id: windowID.rawValue,
            worklanes: worklanes.map(makeWorklane),
            activeWorklaneID: activeWorklaneID?.rawValue
        )
    }

    private static func makeWorklane(_ worklane: WorklaneState) -> WorkspaceRecipe.Worklane {
        WorkspaceRecipe.Worklane(
            id: worklane.id.rawValue,
            title: worklane.title,
            nextPaneNumber: worklane.nextPaneNumber,
            focusedColumnID: worklane.paneStripState.focusedColumnID?.rawValue,
            columns: worklane.paneStripState.columns.map { makeColumn($0, worklane: worklane) }
        )
    }

    private static func makeColumn(
        _ column: PaneColumnState,
        worklane: WorklaneState
    ) -> WorkspaceRecipe.Column {
        WorkspaceRecipe.Column(
            id: column.id.rawValue,
            width: Double(column.width),
            focusedPaneID: column.focusedPaneID?.rawValue,
            lastFocusedPaneID: column.lastFocusedPaneID?.rawValue,
            paneHeights: column.paneHeights.map(Double.init),
            panes: column.panes.map { makePane($0, worklane: worklane) }
        )
    }

    private static func makePane(
        _ pane: PaneState,
        worklane: WorklaneState
    ) -> WorkspaceRecipe.Pane {
        let auxiliary = worklane.auxiliaryStateByPaneID[pane.id]
        let terminalLocation = PaneTerminalLocationResolver.snapshot(
            metadata: auxiliary?.metadata,
            shellContext: auxiliary?.shellContext,
            requestWorkingDirectory: pane.sessionRequest.inheritFromPaneID == nil
                ? trimmedWorkingDirectory(pane.sessionRequest.workingDirectory)
                : nil
        )
        let workingDirectory: String? = if terminalLocation.scope == .remote {
            nil
        } else {
            terminalLocation.workingDirectory
                ?? trimmedWorkingDirectory(auxiliary?.presentation.cwd)
                ?? trimmedWorkingDirectory(pane.sessionRequest.workingDirectory)
        }
        let titleSeed = trimmedTitle(auxiliary?.presentation.rememberedTitle) ?? trimmedTitle(pane.title)

        return WorkspaceRecipe.Pane(
            id: pane.id.rawValue,
            titleSeed: titleSeed,
            workingDirectory: workingDirectory
        )
    }

    private static func trimmedTitle(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }

        return value
    }

    private static func trimmedWorkingDirectory(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }

        return value
    }
}

enum WorkspaceRecipeImporter {
    static func makeWorklanes(
        from window: WorkspaceRecipe.Window,
        windowID: WindowID,
        layoutContext: PaneLayoutContext,
        processEnvironment: [String: String]
    ) -> WindowWorkspaceState {
        let worklanes = window.worklanes.map {
            makeWorklane(
                $0,
                window: window,
                windowID: windowID,
                layoutContext: layoutContext,
                processEnvironment: processEnvironment
            )
        }
        let requestedActiveID = window.activeWorklaneID.map(WorklaneID.init)
        let activeWorklaneID = requestedActiveID.flatMap { candidate in
            worklanes.contains(where: { $0.id == candidate }) ? candidate : nil
        } ?? worklanes.first?.id

        return WindowWorkspaceState(
            worklanes: worklanes,
            activeWorklaneID: activeWorklaneID
        )
    }

    private static func makeWorklane(
        _ recipe: WorkspaceRecipe.Worklane,
        window: WorkspaceRecipe.Window,
        windowID: WindowID,
        layoutContext: PaneLayoutContext,
        processEnvironment: [String: String]
    ) -> WorklaneState {
        let worklaneID = WorklaneID(recipe.id)
        var auxiliaryStateByPaneID: [PaneID: PaneAuxiliaryState] = [:]
        let columns = recipe.columns.map { column in
            makeColumn(
                column,
                window: window,
                worklane: recipe,
                windowID: windowID,
                worklaneID: worklaneID,
                auxiliaryStateByPaneID: &auxiliaryStateByPaneID,
                processEnvironment: processEnvironment
            )
        }

        return WorklaneState(
            id: worklaneID,
            title: recipe.title,
            paneStripState: PaneStripState(
                columns: columns,
                focusedColumnID: recipe.focusedColumnID.map(PaneColumnID.init),
                layoutSizing: layoutContext.sizing
            ),
            nextPaneNumber: max(recipe.nextPaneNumber, 1),
            auxiliaryStateByPaneID: auxiliaryStateByPaneID
        )
    }

    private static func makeColumn(
        _ recipe: WorkspaceRecipe.Column,
        window: WorkspaceRecipe.Window,
        worklane: WorkspaceRecipe.Worklane,
        windowID: WindowID,
        worklaneID: WorklaneID,
        auxiliaryStateByPaneID: inout [PaneID: PaneAuxiliaryState],
        processEnvironment: [String: String]
    ) -> PaneColumnState {
        let panes = recipe.panes.enumerated().map { index, pane in
            makePane(
                pane,
                paneIndex: index,
                paneCountInColumn: recipe.panes.count,
                window: window,
                worklane: worklane,
                windowID: windowID,
                worklaneID: worklaneID,
                columnWidth: CGFloat(recipe.width),
                auxiliaryStateByPaneID: &auxiliaryStateByPaneID,
                processEnvironment: processEnvironment
            )
        }

        return PaneColumnState(
            id: PaneColumnID(recipe.id),
            panes: panes,
            width: CGFloat(recipe.width),
            paneHeights: recipe.paneHeights.map { CGFloat($0) },
            focusedPaneID: recipe.focusedPaneID.map(PaneID.init),
            lastFocusedPaneID: recipe.lastFocusedPaneID.map(PaneID.init)
        )
    }

    private static func makePane(
        _ recipe: WorkspaceRecipe.Pane,
        paneIndex: Int,
        paneCountInColumn: Int,
        window: WorkspaceRecipe.Window,
        worklane: WorkspaceRecipe.Worklane,
        windowID: WindowID,
        worklaneID: WorklaneID,
        columnWidth: CGFloat,
        auxiliaryStateByPaneID: inout [PaneID: PaneAuxiliaryState],
        processEnvironment: [String: String]
    ) -> PaneState {
        let paneID = PaneID(recipe.id)
        let homeDirectory = defaultWorkingDirectory(processEnvironment: processEnvironment)
        let requestedDirectory = trimmed(recipe.workingDirectory)
        let resolvedDirectory = resolvedWorkingDirectory(
            requestedDirectory,
            fallbackDirectory: homeDirectory
        )
        let title = trimmed(recipe.titleSeed) ?? "shell"
        let missingWorkingDirectory = requestedDirectory != nil && requestedDirectory != resolvedDirectory
        let shellContext = PaneShellContext(
            scope: .local,
            path: resolvedDirectory,
            home: processEnvironment["HOME"],
            user: processEnvironment["USER"],
            host: nil
        )
        let raw = PaneRawState(shellContext: shellContext)
        var presentation = PanePresentationNormalizer.normalize(
            paneTitle: title,
            raw: raw,
            previous: nil,
            sessionRequestWorkingDirectory: resolvedDirectory
        )
        presentation.rememberedTitle = trimmed(recipe.titleSeed) ?? presentation.rememberedTitle
        if missingWorkingDirectory {
            presentation.statusText = "Original path unavailable"
        }

        auxiliaryStateByPaneID[paneID] = PaneAuxiliaryState(
            raw: raw,
            presentation: presentation
        )

        return PaneState(
            id: paneID,
            title: title,
            sessionRequest: TerminalSessionRequest(
                workingDirectory: resolvedDirectory,
                surfaceContext: inferredSurfaceContext(
                    paneCountInColumn: paneCountInColumn,
                    totalColumns: worklane.columns.count,
                    totalWorklanes: window.worklanes.count,
                    paneIndex: paneIndex
                ),
                environmentVariables: WorklaneSessionEnvironment.make(
                    windowID: windowID,
                    worklaneID: worklaneID,
                    paneID: paneID,
                    initialWorkingDirectory: resolvedDirectory,
                    processEnvironment: processEnvironment
                )
            ),
            width: columnWidth
        )
    }

    private static func inferredSurfaceContext(
        paneCountInColumn: Int?,
        totalColumns: Int,
        totalWorklanes: Int,
        paneIndex: Int
    ) -> TerminalSurfaceContext {
        if totalColumns == 1, paneCountInColumn == 1, totalWorklanes == 1, paneIndex == 0 {
            return .window
        }

        if totalColumns == 1, paneCountInColumn == 1, paneIndex == 0 {
            return .tab
        }

        return .split
    }

    private static func resolvedWorkingDirectory(
        _ requestedDirectory: String?,
        fallbackDirectory: String
    ) -> String {
        guard let requestedDirectory else {
            return fallbackDirectory
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: requestedDirectory,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            return fallbackDirectory
        }

        return requestedDirectory
    }

    private static func defaultWorkingDirectory(
        processEnvironment: [String: String]
    ) -> String {
        trimmed(processEnvironment["HOME"]) ?? NSHomeDirectory()
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }

        return value
    }
}

enum WorkspaceRecipeMeaningfulness {
    static func isMeaningful(
        _ recipe: WorkspaceRecipe,
        defaultWorkingDirectory: String
    ) -> Bool {
        guard recipe.windows.count == 1, let window = recipe.windows.first else {
            return !recipe.windows.isEmpty
        }

        guard window.worklanes.count == 1, let worklane = window.worklanes.first else {
            return true
        }

        guard worklane.columns.count == 1, let column = worklane.columns.first else {
            return true
        }

        guard column.panes.count == 1, let pane = column.panes.first else {
            return true
        }

        if worklane.title != "MAIN" {
            return true
        }

        if worklane.nextPaneNumber > 2 {
            return true
        }

        if window.activeWorklaneID != worklane.id {
            return true
        }

        if worklane.focusedColumnID != column.id {
            return true
        }

        if column.focusedPaneID != pane.id || column.lastFocusedPaneID != pane.id {
            return true
        }

        if normalizedPath(pane.workingDirectory) != normalizedPath(defaultWorkingDirectory) {
            return true
        }

        if let titleSeed = pane.titleSeed, titleSeed != "shell" {
            return true
        }

        return false
    }

    private static func normalizedPath(_ path: String?) -> String? {
        guard let path = path?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else {
            return nil
        }

        return URL(fileURLWithPath: path).standardizedFileURL.path
    }
}
