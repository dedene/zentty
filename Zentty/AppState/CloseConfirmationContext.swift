import Foundation

/// What is running in a pane, resolved for a close-confirmation prompt.
enum CloseConfirmationActivity: Equatable, Sendable {
    /// A recognized agent tool such as Claude Code or Codex.
    case tool(String)
    /// The last shell command the user ran, e.g. `pnpm dev`.
    case command(String)
    /// The foreground process name when no command is known, e.g. `node`.
    case process(String)

    /// Plain text without decoration, for lists.
    var plainText: String {
        switch self {
        case .tool(let name), .command(let name), .process(let name):
            return name
        }
    }

    /// Text for use inside a sentence: commands are quoted, names are not.
    var sentenceText: String {
        switch self {
        case .tool(let name), .process(let name):
            return name
        case .command(let command):
            return "“\(command)”"
        }
    }
}

/// Everything the close-pane confirmation needs to say *which* pane is about
/// to close and what will be lost. Built from state the sidebar already shows.
struct PaneCloseConfirmationContext: Equatable, Sendable {
    static let maximumActivityLength = 48

    let reason: WorklaneStore.PaneCloseReason
    let paneName: String
    let worklaneName: String?
    /// Branch and home-relative working directory, e.g. `main · ~/Development/zentty`.
    let locationLine: String?
    let activity: CloseConfirmationActivity?

    var runningActivity: String? {
        activity?.plainText
    }

    static func make(paneID: PaneID, in worklane: WorklaneState) -> PaneCloseConfirmationContext? {
        guard let pane = worklane.paneStripState.panes.first(where: { $0.id == paneID }) else {
            return nil
        }
        let auxiliaryState = worklane.auxiliaryStateByPaneID[paneID] ?? PaneAuxiliaryState()
        guard let reason = WorklaneStore.quitConfirmationReason(for: auxiliaryState) else {
            return nil
        }

        return PaneCloseConfirmationContext(
            reason: reason,
            paneName: paneName(pane: pane, auxiliaryState: auxiliaryState),
            worklaneName: worklane.title,
            locationLine: locationLine(for: auxiliaryState),
            activity: reason == .runningProcess ? activity(for: auxiliaryState) : nil
        )
    }

    // MARK: - Derivation

    /// Prefers stable, user-meaningful names over volatile terminal titles:
    /// custom title, SSH target, agent tool, remembered title, foreground
    /// process, working directory, then the pane's default title.
    static func paneName(pane: PaneState, auxiliaryState: PaneAuxiliaryState) -> String {
        let presentation = auxiliaryState.presentation
        let metadata = auxiliaryState.metadata
        let candidates: [String?] = [
            PaneDisplayIdentityResolver.trimmedCustomTitle(for: pane),
            WorklaneContextFormatter.trimmed(presentation.sshConnectionLabel),
            currentTool(for: auxiliaryState)?.displayName,
            WorklaneContextFormatter.trimmed(presentation.rememberedTitle),
            WorklaneContextFormatter.displayMeaningfulTerminalIdentity(for: metadata),
            directoryName(workingDirectory(for: auxiliaryState)),
            WorklaneContextFormatter.normalizeSidebarFallbackTitle(pane.title),
        ]
        return candidates.compactMap { $0 }.first ?? "Shell"
    }

    /// Full home-relative path rather than the sidebar's compacted form, so
    /// two panes in sibling directories stay distinguishable. Remote shells
    /// report their host and remote path instead of a local directory.
    static func locationLine(for auxiliaryState: PaneAuxiliaryState) -> String? {
        let presentation = auxiliaryState.presentation
        if presentation.isRemoteShell {
            return WorklaneContextFormatter.trimmed(presentation.remoteLocationLabel)
                ?? WorklaneContextFormatter.trimmed(presentation.remoteHostLabel)
        }

        let branch = WorklaneContextFormatter.displayBranch(
            presentation.branch ?? auxiliaryState.metadata?.gitBranch
        )
        let directory = workingDirectory(for: auxiliaryState).map {
            WorklaneContextFormatter.homeRelativePath($0) ?? $0
        }
        let parts = [branch, directory].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The agent tool that is actually current. While a command runs, only a
    /// tool launched by that command counts; the metadata-derived tool can be
    /// stale after an agent exits and something else starts.
    static func currentTool(for auxiliaryState: PaneAuxiliaryState) -> AgentTool? {
        if auxiliaryState.shellActivityState == .commandRunning,
           let command = WorklaneContextFormatter.trimmed(auxiliaryState.raw.lastRunCommand) {
            return AgentTool.resolveKnown(named: executableName(of: command))
        }
        return auxiliaryState.presentation.recognizedTool
            ?? AgentToolRecognizer.recognize(metadata: auxiliaryState.metadata)
    }

    /// The shell reports the command it is running in the same event that
    /// marks the pane busy, so that command is the most accurate source. A
    /// recognized tool from metadata can be stale after the agent exits.
    static func activity(for auxiliaryState: PaneAuxiliaryState) -> CloseConfirmationActivity? {
        let metadata = auxiliaryState.metadata

        if let command = WorklaneContextFormatter.trimmed(auxiliaryState.raw.lastRunCommand) {
            if let tool = AgentTool.resolveKnown(named: executableName(of: command)) {
                return .tool(tool.displayName)
            }
            return .command(truncated(command))
        }

        if let tool = auxiliaryState.presentation.recognizedTool
            ?? AgentToolRecognizer.recognize(metadata: metadata) {
            return .tool(tool.displayName)
        }

        if let process = WorklaneContextFormatter.trimmed(metadata?.processName),
           !WorklaneContextFormatter.isGenericShellIdentity(process) {
            return .process(process)
        }

        return nil
    }

    /// First token that is not a `VAR=value` prefix, reduced to its basename,
    /// so `FOO=1 /opt/homebrew/bin/claude --resume` resolves as `claude`.
    private static func executableName(of command: String) -> String? {
        let token = command
            .split(whereSeparator: \.isWhitespace)
            .first { !$0.contains("=") }
            .map(String.init)
        guard let token else { return nil }
        return URL(fileURLWithPath: token).lastPathComponent
    }

    private static func workingDirectory(for auxiliaryState: PaneAuxiliaryState) -> String? {
        auxiliaryState.presentation.cwd
            ?? WorklaneContextFormatter.resolvedWorkingDirectory(
                for: auxiliaryState.metadata,
                shellContext: auxiliaryState.raw.shellContext
            )
    }

    private static func directoryName(_ workingDirectory: String?) -> String? {
        guard let workingDirectory = WorklaneContextFormatter.trimmed(workingDirectory) else {
            return nil
        }
        if WorklaneContextFormatter.homeRelativePath(workingDirectory) == "~" {
            return "~"
        }
        let name = URL(fileURLWithPath: workingDirectory).lastPathComponent
        return name.isEmpty || name == "/" ? nil : name
    }

    private static func truncated(_ value: String) -> String {
        let singleLine = value.split(whereSeparator: \.isNewline).first.map(String.init) ?? value
        guard singleLine.count > maximumActivityLength else {
            return singleLine
        }
        return String(singleLine.prefix(maximumActivityLength - 1))
            .trimmingCharacters(in: .whitespaces) + "…"
    }
}

/// Aggregate of every pane in a worklane that needs confirmation before close.
struct WorklaneCloseConfirmationContext: Equatable, Sendable {
    let reason: WorklaneStore.PaneCloseReason
    let worklaneName: String?
    let paneCount: Int
    let runningPaneCount: Int
    let historyPaneCount: Int
    /// Activities of running panes that could be named, in pane order.
    let runningActivities: [String]

    static func make(worklane: WorklaneState) -> WorklaneCloseConfirmationContext? {
        var runningPaneCount = 0
        var historyPaneCount = 0
        var runningActivities: [String] = []

        for pane in worklane.paneStripState.panes {
            guard let auxiliaryState = worklane.auxiliaryStateByPaneID[pane.id],
                  let reason = WorklaneStore.quitConfirmationReason(for: auxiliaryState)
            else {
                continue
            }

            switch reason {
            case .runningProcess:
                runningPaneCount += 1
                if let activity = PaneCloseConfirmationContext.activity(for: auxiliaryState) {
                    runningActivities.append(activity.plainText)
                }
            case .sessionHistory:
                historyPaneCount += 1
            }
        }

        guard runningPaneCount > 0 || historyPaneCount > 0 else {
            return nil
        }

        return WorklaneCloseConfirmationContext(
            reason: runningPaneCount > 0 ? .runningProcess : .sessionHistory,
            worklaneName: worklane.title,
            paneCount: worklane.paneStripState.panes.count,
            runningPaneCount: runningPaneCount,
            historyPaneCount: historyPaneCount,
            runningActivities: runningActivities
        )
    }
}

extension WorklaneStore {
    func paneCloseConfirmationContext(_ paneID: PaneID) -> PaneCloseConfirmationContext? {
        for worklane in worklanes {
            guard worklane.paneStripState.panes.contains(where: { $0.id == paneID }) else {
                continue
            }
            return PaneCloseConfirmationContext.make(paneID: paneID, in: worklane)
        }
        return nil
    }

    func worklaneCloseConfirmationContext(_ worklaneID: WorklaneID) -> WorklaneCloseConfirmationContext? {
        guard let worklane = worklanes.first(where: { $0.id == worklaneID }) else {
            return nil
        }
        return WorklaneCloseConfirmationContext.make(worklane: worklane)
    }
}
