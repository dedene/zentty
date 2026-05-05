import CoreGraphics
import Foundation

enum PaneRestorationBuilder {
    struct PaneInputs: Equatable, Sendable {
        var id: PaneID
        var titleSeed: String?
        var requestedWorkingDirectory: String?
        var command: String?
        var prefillText: String?
        var environmentOverrides: [String: String]
        var agentTeamsEnabled: Bool = false
        var surfaceContext: TerminalSurfaceContext
        var columnWidth: CGFloat
        var statusTextWhenWorkingDirectoryMissing: String?
    }

    struct Result: Equatable, Sendable {
        var pane: PaneState
        var auxiliary: PaneAuxiliaryState
        var didFallBackForWorkingDirectory: Bool
    }

    static func makePane(
        _ inputs: PaneInputs,
        windowID: WindowID,
        worklaneID: WorklaneID,
        processEnvironment: [String: String]
    ) -> Result {
        let homeDirectory = defaultWorkingDirectory(processEnvironment: processEnvironment)
        let requestedDirectory = trimmed(inputs.requestedWorkingDirectory)
        let resolvedDirectory = resolvedWorkingDirectory(
            requestedDirectory,
            fallbackDirectory: homeDirectory
        )
        let didFallBack = requestedDirectory != nil && requestedDirectory != resolvedDirectory
        let title = trimmed(inputs.titleSeed) ?? "shell"

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
        presentation.rememberedTitle = trimmed(inputs.titleSeed) ?? presentation.rememberedTitle
        if didFallBack, let statusText = inputs.statusTextWhenWorkingDirectoryMissing {
            presentation.statusText = statusText
        }
        let auxiliary = PaneAuxiliaryState(raw: raw, presentation: presentation)

        var environment = WorklaneSessionEnvironment.make(
            windowID: windowID,
            worklaneID: worklaneID,
            paneID: inputs.id,
            initialWorkingDirectory: resolvedDirectory,
            processEnvironment: processEnvironment,
            agentTeamsEnabled: inputs.agentTeamsEnabled
        )
        for (key, value) in WorklaneSessionEnvironment.templateSafeOverrides(from: inputs.environmentOverrides) {
            environment[key] = value
        }

        let pane = PaneState(
            id: inputs.id,
            title: title,
            sessionRequest: TerminalSessionRequest(
                workingDirectory: resolvedDirectory,
                command: trimmed(inputs.command),
                prefillText: trimmed(inputs.prefillText),
                surfaceContext: inputs.surfaceContext,
                environmentVariables: environment
            ),
            width: inputs.columnWidth
        )

        return Result(
            pane: pane,
            auxiliary: auxiliary,
            didFallBackForWorkingDirectory: didFallBack
        )
    }

    static func defaultWorkingDirectory(processEnvironment: [String: String]) -> String {
        trimmed(processEnvironment["HOME"]) ?? NSHomeDirectory()
    }

    static func resolvedWorkingDirectory(
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

    static func inferredSurfaceContext(
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

    private static func trimmed(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}
