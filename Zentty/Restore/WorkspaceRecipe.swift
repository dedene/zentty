import CoreGraphics
import Foundation

struct WindowWorkspaceState: Equatable, Sendable {
    var worklanes: [WorklaneState]
    var activeWorklaneID: WorklaneID?
}

struct WorkspaceRecipe: Codable, Equatable, Sendable {
    /// Schema version 2 marks recipes whose worklane titles are stored
    /// verbatim. Unversioned (nil) recipes predate optional titles and carry
    /// auto-generated "MAIN"/"WS N" junk that gets sanitized once at import.
    /// Synthesized Decodable ignores the property default for optionals, so
    /// legacy JSON without the key decodes as nil.
    static let currentSchemaVersion = 2

    var schemaVersion: Int?
    var windows: [Window]
    var activeWindowID: String?

    init(
        schemaVersion: Int? = WorkspaceRecipe.currentSchemaVersion,
        windows: [Window],
        activeWindowID: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.windows = windows
        self.activeWindowID = activeWindowID
    }

    struct Window: Codable, Equatable, Sendable {
        var id: String
        var frame: WindowFrame? = nil
        var worklanes: [Worklane]
        var activeWorklaneID: String?
    }

    struct WindowFrame: Codable, Equatable, Sendable {
        var x: Double
        var y: Double
        var width: Double
        var height: Double
        var screenX: Double?
        var screenY: Double?
        var screenWidth: Double?
        var screenHeight: Double?

        init(
            x: Double,
            y: Double,
            width: Double,
            height: Double,
            screenX: Double? = nil,
            screenY: Double? = nil,
            screenWidth: Double? = nil,
            screenHeight: Double? = nil
        ) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
            self.screenX = screenX
            self.screenY = screenY
            self.screenWidth = screenWidth
            self.screenHeight = screenHeight
        }

        init(rect: CGRect) {
            self.init(
                x: Double(rect.origin.x),
                y: Double(rect.origin.y),
                width: Double(rect.size.width),
                height: Double(rect.size.height)
            )
        }

        var rect: CGRect {
            CGRect(x: x, y: y, width: width, height: height)
        }
    }

    struct Worklane: Codable, Equatable, Sendable {
        var id: String
        var title: String?
        var nextPaneNumber: Int
        var focusedColumnID: String?
        var columns: [Column]
        var color: String?
        var bookmarkOriginID: String?
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
        var lastActivityTitle: String? = nil
        var lastRunCommand: String? = nil
    }
}

enum WorkspaceRecipeExporter {
    static func makeWindow(
        windowID: WindowID,
        frame: CGRect? = nil,
        worklanes: [WorklaneState],
        activeWorklaneID: WorklaneID?
    ) -> WorkspaceRecipe.Window {
        WorkspaceRecipe.Window(
            id: windowID.rawValue,
            frame: frame.map(WorkspaceRecipe.WindowFrame.init(rect:)),
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
            columns: worklane.paneStripState.columns.map { makeColumn($0, worklane: worklane) },
            color: worklane.color?.rawValue,
            bookmarkOriginID: worklane.bookmarkOriginID?.uuidString
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
        let titleSeed = exportedTitleSeed(
            pane: pane,
            auxiliary: auxiliary
        )
        let lastActivityTitle = exportedLastActivityTitle(
            pane: pane,
            auxiliary: auxiliary,
            titleSeed: titleSeed
        )
        let lastRunCommand =
            terminalLocation.scope == .remote || workingDirectory == nil
            ? nil
            : trimmedCommand(auxiliary?.raw.lastRunCommand)

        return WorkspaceRecipe.Pane(
            id: pane.id.rawValue,
            titleSeed: titleSeed,
            workingDirectory: workingDirectory,
            lastActivityTitle: lastActivityTitle,
            lastRunCommand: lastRunCommand
        )
    }

    private static func exportedTitleSeed(
        pane: PaneState,
        auxiliary: PaneAuxiliaryState?
    ) -> String? {
        let recognizedTool = auxiliary?.presentation.recognizedTool ?? auxiliary?.agentStatus?.tool
        let isRemoteShell = auxiliary?.shellContext?.scope == .remote

        for candidate in [
            trimmedTitle(auxiliary?.presentation.rememberedTitle),
            trimmedTitle(pane.title),
        ] {
            guard let candidate else {
                continue
            }

            if shouldPersistTitleSeed(
                candidate,
                recognizedTool: recognizedTool,
                isRemoteShell: isRemoteShell
            ),
               !isLocalLiveProcessTitle(candidate, auxiliary: auxiliary) {
                return candidate
            }
        }

        return nil
    }

    private static func exportedLastActivityTitle(
        pane: PaneState,
        auxiliary: PaneAuxiliaryState?,
        titleSeed: String?
    ) -> String? {
        guard titleSeed == nil else {
            return nil
        }
        guard auxiliary?.presentation.recognizedTool == nil,
              auxiliary?.agentStatus?.tool == nil,
              auxiliary?.shellContext?.scope != .remote else {
            return nil
        }
        if let restoredTitle = trimmedTitle(auxiliary?.presentation.lastActivityTitle),
           shouldPersistLastActivityTitle(restoredTitle) {
            return restoredTitle
        }
        guard let metadata = auxiliary?.metadata else {
            return nil
        }

        let liveIdentities = Set(
            [
                WorklaneContextFormatter.normalizeDisplayIdentity(metadata.title),
                WorklaneContextFormatter.normalizeDisplayIdentity(metadata.processName),
            ].compactMap { $0 }
        )
        guard !liveIdentities.isEmpty else {
            return nil
        }

        for candidate in [
            trimmedTitle(auxiliary?.presentation.rememberedTitle),
            trimmedTitle(pane.title),
        ] {
            guard let candidate else {
                continue
            }
            guard liveIdentities.contains(candidate) else {
                continue
            }
            guard shouldPersistLastActivityTitle(candidate) else {
                continue
            }
            return candidate
        }

        return nil
    }

    private static func isLocalLiveProcessTitle(
        _ candidate: String,
        auxiliary: PaneAuxiliaryState?
    ) -> Bool {
        guard auxiliary?.presentation.recognizedTool == nil,
              auxiliary?.agentStatus?.tool == nil,
              auxiliary?.shellContext?.scope != .remote,
              let metadata = auxiliary?.metadata else {
            return false
        }

        let liveIdentities = [
            WorklaneContextFormatter.normalizeDisplayIdentity(metadata.title),
            WorklaneContextFormatter.normalizeDisplayIdentity(metadata.processName),
        ].compactMap { $0 }

        return liveIdentities.contains(candidate)
    }

    private static func shouldPersistTitleSeed(
        _ candidate: String,
        recognizedTool: AgentTool?,
        isRemoteShell: Bool
    ) -> Bool {
        if let recognizedTool {
            return !TerminalMetadataChangeClassifier.isVolatileAgentStatusTitle(
                candidate,
                recognizedTool: recognizedTool
            )
        }

        if isRemoteShell {
            return true
        }

        return !looksLikeTransientSSHCommandTitle(candidate)
            && !isGenericLocalShellTitle(candidate)
    }

    private static func looksLikeTransientSSHCommandTitle(_ value: String) -> Bool {
        WorklaneContextFormatter.looksLikeSSHCommandTitle(value)
    }

    private static func shouldPersistLastActivityTitle(_ candidate: String) -> Bool {
        !looksLikeTransientSSHCommandTitle(candidate)
            && !isGenericLocalShellTitle(candidate)
    }

    private static func isGenericLocalShellTitle(_ value: String) -> Bool {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.range(of: #"^pane \d+$"#, options: .regularExpression) != nil {
            return true
        }

        return [
            "shell",
            "shell pane",
            "terminal",
            "pane",
            "zsh",
            "bash",
            "sh",
            "fish",
        ].contains(normalized)
    }

    private static func trimmedTitle(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }

        return value
    }

    private static func trimmedCommand(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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
        recipeSchemaVersion: Int? = nil,
        restoreDraftWindow: SessionRestoreDraftWindow? = nil,
        windowID: WindowID,
        layoutContext: PaneLayoutContext,
        processEnvironment: [String: String],
        agentTeamsEnabled: Bool = false
    ) -> WindowWorkspaceState {
        let worklanes = window.worklanes.map {
            makeWorklane(
                $0,
                window: window,
                recipeSchemaVersion: recipeSchemaVersion,
                restoreDraftWindow: restoreDraftWindow,
                windowID: windowID,
                layoutContext: layoutContext,
                processEnvironment: processEnvironment,
                agentTeamsEnabled: agentTeamsEnabled
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
        recipeSchemaVersion: Int?,
        restoreDraftWindow: SessionRestoreDraftWindow?,
        windowID: WindowID,
        layoutContext: PaneLayoutContext,
        processEnvironment: [String: String],
        agentTeamsEnabled: Bool
    ) -> WorklaneState {
        let worklaneID = WorklaneID(recipe.id)
        var auxiliaryStateByPaneID: [PaneID: PaneAuxiliaryState] = [:]
        let columns = recipe.columns.map { column in
            makeColumn(
                column,
                window: window,
                worklane: recipe,
                restoreDraftWindow: restoreDraftWindow,
                windowID: windowID,
                worklaneID: worklaneID,
                auxiliaryStateByPaneID: &auxiliaryStateByPaneID,
                processEnvironment: processEnvironment,
                agentTeamsEnabled: agentTeamsEnabled
            )
        }

        // Versioned recipes store titles verbatim; unversioned ones predate
        // optional titles and need the legacy "MAIN"/"WS N" junk stripped.
        let title = recipeSchemaVersion == nil
            ? WorklaneState.meaningfulTitle(from: recipe.title)
            : recipe.title

        return WorklaneState(
            id: worklaneID,
            title: title,
            paneStripState: PaneStripState(
                columns: columns,
                focusedColumnID: recipe.focusedColumnID.map(PaneColumnID.init),
                layoutSizing: layoutContext.sizing
            ),
            nextPaneNumber: max(recipe.nextPaneNumber, 1),
            auxiliaryStateByPaneID: auxiliaryStateByPaneID,
            color: recipe.color.flatMap(WorklaneColor.init(rawValue:)),
            bookmarkOriginID: recipe.bookmarkOriginID.flatMap(UUID.init(uuidString:))
        )
    }

    private static func makeColumn(
        _ recipe: WorkspaceRecipe.Column,
        window: WorkspaceRecipe.Window,
        worklane: WorkspaceRecipe.Worklane,
        restoreDraftWindow: SessionRestoreDraftWindow?,
        windowID: WindowID,
        worklaneID: WorklaneID,
        auxiliaryStateByPaneID: inout [PaneID: PaneAuxiliaryState],
        processEnvironment: [String: String],
        agentTeamsEnabled: Bool
    ) -> PaneColumnState {
        let panes = recipe.panes.enumerated().map { index, pane in
            makePane(
                pane,
                paneIndex: index,
                paneCountInColumn: recipe.panes.count,
                window: window,
                worklane: worklane,
                restoreDraftWindow: restoreDraftWindow,
                windowID: windowID,
                worklaneID: worklaneID,
                columnWidth: CGFloat(recipe.width),
                auxiliaryStateByPaneID: &auxiliaryStateByPaneID,
                processEnvironment: processEnvironment,
                agentTeamsEnabled: agentTeamsEnabled
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
        restoreDraftWindow: SessionRestoreDraftWindow?,
        windowID: WindowID,
        worklaneID: WorklaneID,
        columnWidth: CGFloat,
        auxiliaryStateByPaneID: inout [PaneID: PaneAuxiliaryState],
        processEnvironment: [String: String],
        agentTeamsEnabled: Bool
    ) -> PaneState {
        let paneID = PaneID(recipe.id)
        let restoreDraft = restoreDraftWindow.flatMap { $0.draft(forPaneID: paneID) }
        let resumeCommand = restoreDraft.flatMap(AgentResumeCommandBuilder.command(for:))
        let legacyLastActivityTitle = legacyLastActivityTitle(from: recipe)
        let titleSeed = legacyLastActivityTitle == nil ? recipe.titleSeed : nil
        let lastActivityTitle = recipe.lastActivityTitle ?? legacyLastActivityTitle

        let inputs = PaneRestorationBuilder.PaneInputs(
            id: paneID,
            titleSeed: titleSeed,
            lastActivityTitle: lastActivityTitle,
            requestedWorkingDirectory: recipe.workingDirectory,
            command: resumeCommand,
            prefillText: nil,
            environmentOverrides: [:],
            agentTeamsEnabled: agentTeamsEnabled,
            surfaceContext: PaneRestorationBuilder.inferredSurfaceContext(
                paneCountInColumn: paneCountInColumn,
                totalColumns: worklane.columns.count,
                totalWorklanes: window.worklanes.count,
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
        var auxiliary = result.auxiliary
        let canRestoreRerunnableCommand =
            trimmedCommand(recipe.workingDirectory) != nil
            && !result.didFallBackForWorkingDirectory
        let lastRunCommand = canRestoreRerunnableCommand
            ? trimmedCommand(recipe.lastRunCommand)
            : nil
        let restoredRerunnableCommand = canRestoreRerunnableCommand
            ? lastRunCommand
                ?? legacyRerunnableCommand(from: recipe.lastActivityTitle ?? legacyLastActivityTitle)
            : nil
        auxiliary.raw.lastRunCommand = lastRunCommand
        auxiliary.raw.restoredRerunnableCommand = restoredRerunnableCommand
        if let restoreDraft, resumeCommand != nil {
            auxiliary.raw.restoredAgentRestoreDraft = restoreDraft
            auxiliary.raw.restoredAgentAutoResumePending = true
        }
        auxiliaryStateByPaneID[paneID] = auxiliary
        return result.pane
    }

    private static func legacyLastActivityTitle(from recipe: WorkspaceRecipe.Pane) -> String? {
        guard recipe.lastActivityTitle == nil,
              let titleSeed = trimmedTitle(recipe.titleSeed),
              looksLikeLegacyLocalProcessTitle(titleSeed) else {
            return nil
        }

        return titleSeed
    }

    private static func legacyRerunnableCommand(from value: String?) -> String? {
        guard let command = trimmedCommand(value) else {
            return nil
        }

        guard !looksLikeTransientSSHCommandTitle(command),
              !isGenericLocalShellTitle(command),
              !looksLikeAgentStatusTitle(command),
              !looksLikeUIPhrase(command)
        else {
            return nil
        }

        return command
    }

    private static func looksLikeAgentStatusTitle(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.unicodeScalars.first else {
            return true
        }
        if !CharacterSet.alphanumerics.contains(first),
           ![".", "/", "~", "$", "_"].contains(String(first)) {
            return true
        }

        let normalized = trimmed.lowercased()
        if normalized.contains("(branch)") {
            return true
        }

        let statusFragments = [
            "waiting for your input",
            "waiting for your decision",
            "needs your input",
            "needs your attention",
            "needs your approval",
            "press esc",
            "esc to",
            "tokens",
        ]
        return statusFragments.contains { normalized.contains($0) }
    }

    private static func looksLikeTransientSSHCommandTitle(_ value: String) -> Bool {
        WorklaneContextFormatter.looksLikeSSHCommandTitle(value)
    }

    private static func isGenericLocalShellTitle(_ value: String) -> Bool {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.range(of: #"^pane \d+$"#, options: .regularExpression) != nil {
            return true
        }

        return [
            "shell",
            "shell pane",
            "terminal",
            "pane",
            "zsh",
            "bash",
            "sh",
            "fish",
        ].contains(normalized)
    }

    private static func looksLikeUIPhrase(_ value: String) -> Bool {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.contains("...") || normalized.contains("\u{2026}") {
            return true
        }
        if normalized.range(of: #"\bago\b"#, options: .regularExpression) != nil {
            return true
        }
        return false
    }

    private static func looksLikeLegacyLocalProcessTitle(_ title: String) -> Bool {
        if WorklaneContextFormatter.looksLikeSSHCommandTitle(title) {
            return false
        }

        let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let firstWord = normalized.split(separator: " ").first.map(String.init),
              firstWord == firstWord.lowercased(),
              firstWord.rangeOfCharacter(from: .letters) != nil else {
            return false
        }

        return normalized.contains(" ")
    }

    private static func trimmedTitle(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }

        return value
    }

    private static func trimmedCommand(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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

        // Versioned recipes store titles verbatim, so any non-empty title is
        // meaningful. Legacy recipes need the "MAIN"/"WS N" junk filtered or
        // an old default workspace would never be considered disposable.
        let meaningfulTitle = recipe.schemaVersion == nil
            ? WorklaneState.meaningfulTitle(from: worklane.title)
            : WorklaneContextFormatter.trimmed(worklane.title)
        if meaningfulTitle != nil {
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

        if let lastActivityTitle = pane.lastActivityTitle, lastActivityTitle != "shell" {
            return true
        }

        if let lastRunCommand = normalizedMeaningfulText(pane.lastRunCommand), lastRunCommand != "shell" {
            return true
        }

        return false
    }

    private static func normalizedMeaningfulText(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func normalizedPath(_ path: String?) -> String? {
        guard let path = path?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else {
            return nil
        }

        return URL(fileURLWithPath: path).standardizedFileURL.path
    }
}
