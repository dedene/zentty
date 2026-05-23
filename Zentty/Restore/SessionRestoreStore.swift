import Darwin
import Foundation
import OSLog

private let sessionRestoreLogger = Logger(subsystem: "be.zenjoy.zentty", category: "SessionRestore")

final class SessionRestoreStore {
    struct LaunchDecision: Equatable, Sendable {
        enum Reason: String, Codable, Equatable, Sendable {
            case normalRestore
            case crashRecovery
        }

        var reason: Reason
        var envelope: SessionRestoreEnvelope
    }

    private struct LifecycleState: Codable, Equatable, Sendable {
        var cleanExit: Bool
        var updatedAt: Date
    }

    let snapshotURL: URL
    let lifecycleURL: URL
    private let fileManager: FileManager
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(
        snapshotURL: URL,
        lifecycleURL: URL,
        fileManager: FileManager = .default
    ) {
        self.snapshotURL = snapshotURL
        self.lifecycleURL = lifecycleURL
        self.fileManager = fileManager
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    convenience init(configDirectoryURL: URL) {
        self.init(
            snapshotURL: configDirectoryURL.appendingPathComponent("restore-snapshot.json"),
            lifecycleURL: configDirectoryURL.appendingPathComponent("restore-lifecycle.json")
        )
    }

    func prepareForLaunch(restorePreferenceEnabled: Bool) throws -> LaunchDecision? {
        guard let envelope = try loadSnapshot() else {
            return nil
        }

        let previousLifecycle = try loadLifecycleState()
        if previousLifecycle?.cleanExit == false {
            return LaunchDecision(reason: .crashRecovery, envelope: envelope)
        }

        guard restorePreferenceEnabled else {
            return nil
        }

        return LaunchDecision(reason: .normalRestore, envelope: envelope)
    }

    func markLaunchStarted() throws {
        try persist(
            LifecycleState(cleanExit: false, updatedAt: Date()),
            to: lifecycleURL
        )
    }

    func markCleanExit() throws {
        try persist(
            LifecycleState(cleanExit: true, updatedAt: Date()),
            to: lifecycleURL
        )
    }

    func saveSnapshot(_ envelope: SessionRestoreEnvelope) throws {
        let envelopeToPersist: SessionRestoreEnvelope
        if envelope.reason == .cleanExit {
            envelopeToPersist = envelope.mergingMissingRestoreDrafts(from: try loadSnapshot())
        } else {
            envelopeToPersist = envelope
        }

        try persist(envelopeToPersist, to: snapshotURL)
    }

    func consumeSnapshot() throws {
        try deleteSnapshot()
    }

    func deleteSnapshot() throws {
        guard fileManager.fileExists(atPath: snapshotURL.path) else {
            return
        }

        try fileManager.removeItem(at: snapshotURL)
    }

    private func loadSnapshot() throws -> SessionRestoreEnvelope? {
        try load(SessionRestoreEnvelope.self, from: snapshotURL)
    }

    private func loadLifecycleState() throws -> LifecycleState? {
        try load(LifecycleState.self, from: lifecycleURL)
    }

    private func load<T: Decodable>(
        _ type: T.Type,
        from url: URL
    ) throws -> T? {
        guard fileManager.fileExists(atPath: url.path) else {
            return nil
        }

        let data = try Data(contentsOf: url)
        return try decoder.decode(type, from: data)
    }

    private func persist<T: Encodable>(
        _ value: T,
        to url: URL
    ) throws {
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try encoder.encode(value)
        try data.write(to: url, options: .atomic)
    }
}

struct SessionRestoreEnvelope: Codable, Equatable, Sendable {
    enum SaveReason: String, Codable, Equatable, Sendable {
        case liveSnapshot
        case cleanExit
    }

    var schemaVersion: Int
    var savedAt: Date
    var reason: SaveReason
    var workspace: WorkspaceRecipe
    var restoreDraftWindows: [SessionRestoreDraftWindow]

    init(
        schemaVersion: Int = 1,
        savedAt: Date = Date(),
        reason: SaveReason = .liveSnapshot,
        workspace: WorkspaceRecipe,
        restoreDraftWindows: [SessionRestoreDraftWindow] = []
    ) {
        self.schemaVersion = schemaVersion
        self.savedAt = savedAt
        self.reason = reason
        self.workspace = workspace
        self.restoreDraftWindows = restoreDraftWindows
    }

    func restoreDraftWindow(forWindowID windowID: String) -> SessionRestoreDraftWindow? {
        restoreDraftWindows.first { $0.windowID == windowID }
    }

    func mergingMissingRestoreDrafts(from previous: SessionRestoreEnvelope?) -> SessionRestoreEnvelope {
        guard let previous else {
            return self
        }

        let validPaneIDsByWindowID = workspace.paneIDsByWindowID()
        guard !validPaneIDsByWindowID.isEmpty else {
            return self
        }

        var mergedRestoreDraftWindows = restoreDraftWindows
        var existingPaneIDsByWindowID: [String: Set<String>] = Dictionary(
            uniqueKeysWithValues: mergedRestoreDraftWindows.map { window in
                (window.windowID, Set(window.paneDrafts.map(\.paneID)))
            }
        )

        for previousWindow in previous.restoreDraftWindows {
            guard let validPaneIDs = validPaneIDsByWindowID[previousWindow.windowID] else {
                continue
            }

            let missingPaneDrafts = previousWindow.paneDrafts.filter { draft in
                validPaneIDs.contains(draft.paneID)
                    && !(existingPaneIDsByWindowID[previousWindow.windowID]?.contains(draft.paneID) ?? false)
            }
            guard !missingPaneDrafts.isEmpty else {
                continue
            }

            if let windowIndex = mergedRestoreDraftWindows.firstIndex(where: { $0.windowID == previousWindow.windowID }) {
                mergedRestoreDraftWindows[windowIndex].paneDrafts.append(contentsOf: missingPaneDrafts)
            } else {
                mergedRestoreDraftWindows.append(
                    SessionRestoreDraftWindow(
                        windowID: previousWindow.windowID,
                        paneDrafts: missingPaneDrafts
                    )
                )
            }

            existingPaneIDsByWindowID[previousWindow.windowID, default: []].formUnion(
                missingPaneDrafts.map(\.paneID)
            )
        }

        var merged = self
        merged.restoreDraftWindows = mergedRestoreDraftWindows
        return merged
    }
}

private extension WorkspaceRecipe {
    func paneIDsByWindowID() -> [String: Set<String>] {
        Dictionary(
            uniqueKeysWithValues: windows.map { window in
                let paneIDs = Set(
                    window.worklanes.flatMap { worklane in
                        worklane.columns.flatMap { column in
                            column.panes.map(\.id)
                        }
                    }
                )
                return (window.id, paneIDs)
            }
        )
    }
}

struct SessionRestoreDraftWindow: Codable, Equatable, Sendable {
    var windowID: String
    var paneDrafts: [PaneRestoreDraft]

    func draft(forPaneID paneID: PaneID) -> PaneRestoreDraft? {
        paneDrafts.first { $0.paneID == paneID.rawValue }
    }
}

struct PaneRestoreDraft: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Equatable, Sendable {
        case agentResume
    }

    var paneID: String
    var kind: Kind
    var toolName: String
    var sessionID: String
    var workingDirectory: String?
    var trackedPID: Int32
    var agentLaunchSnapshot: AgentLaunchSnapshot? = nil
}

enum SessionRestoreDraftExporter {
    static func makeWindowDrafts(
        windowID: WindowID,
        worklanes: [WorklaneState],
        isProcessAlive: (Int32) -> Bool = defaultIsProcessAlive
    ) -> SessionRestoreDraftWindow? {
        let paneDrafts = worklanes.flatMap { worklane in
            worklane.paneStripState.panes.compactMap { pane in
                makePaneDraft(
                    paneID: pane.id,
                    pane: pane,
                    worklane: worklane,
                    isProcessAlive: isProcessAlive
                )
            }
        }

        guard !paneDrafts.isEmpty else {
            return nil
        }

        return SessionRestoreDraftWindow(
            windowID: windowID.rawValue,
            paneDrafts: paneDrafts
        )
    }

    private static func makePaneDraft(
        paneID: PaneID,
        pane: PaneState,
        worklane: WorklaneState,
        isProcessAlive: (Int32) -> Bool
    ) -> PaneRestoreDraft? {
        guard let auxiliary = worklane.auxiliaryStateByPaneID[paneID] else {
            return nil
        }
        guard auxiliary.shellContext?.scope != .remote else {
            return nil
        }
        if let liveDraft = makeLivePaneDraft(
            paneID: paneID,
            pane: pane,
            auxiliary: auxiliary,
            isProcessAlive: isProcessAlive
        ) {
            return liveDraft
        }

        guard var restoredDraft = auxiliary.raw.restoredAgentRestoreDraft,
              restoredDraft.paneID == paneID.rawValue,
              AgentResumeCommandBuilder.command(for: restoredDraft) != nil else {
            return nil
        }

        restoredDraft.workingDirectory = workingDirectory(
            agentStatus: auxiliary.agentStatus,
            auxiliary: auxiliary,
            pane: pane,
            restoredDraft: restoredDraft
        )
        return restoredDraft
    }

    private static func makeLivePaneDraft(
        paneID: PaneID,
        pane: PaneState,
        auxiliary: PaneAuxiliaryState,
        isProcessAlive: (Int32) -> Bool
    ) -> PaneRestoreDraft? {
        let resolvedWorkingDirectory = workingDirectory(
            agentStatus: auxiliary.agentStatus,
            auxiliary: auxiliary,
            pane: pane,
            restoredDraft: nil
        )

        if let agentStatus = auxiliary.agentStatus,
           let trackedPID = agentStatus.trackedPID,
           isProcessAlive(trackedPID) {
            return makeRestorableDraft(
                paneID: paneID.rawValue,
                tool: agentStatus.tool,
                sessionID: agentStatus.sessionID,
                workingDirectory: resolvedWorkingDirectory,
                trackedPID: trackedPID,
                agentLaunchSnapshot: agentStatus.agentLaunchSnapshot
            )
        }

        guard let session = restorableHiddenSession(
            in: auxiliary.agentReducerState,
            workingDirectory: resolvedWorkingDirectory,
            isProcessAlive: isProcessAlive
        ) else {
            return nil
        }

        guard let trackedPID = session.trackedPID else {
            return nil
        }

        return makeRestorableDraft(
            paneID: paneID.rawValue,
            tool: session.tool,
            sessionID: session.sessionID,
            workingDirectory: resolvedWorkingDirectory,
            trackedPID: trackedPID,
            agentLaunchSnapshot: session.agentLaunchSnapshot
        )
    }

    private static func restorableHiddenSession(
        in reducerState: PaneAgentReducerState,
        workingDirectory: String?,
        isProcessAlive: (Int32) -> Bool
    ) -> PaneAgentSessionState? {
        reducerState.sessionsByID.values
            .filter { session in
                guard let trackedPID = session.trackedPID,
                      isProcessAlive(trackedPID) else {
                    return false
                }

                switch session.state {
                case .starting, .running, .needsInput, .idle:
                    return makeRestorableDraft(
                        paneID: "",
                        tool: session.tool,
                        sessionID: session.sessionID,
                        workingDirectory: workingDirectory,
                        trackedPID: trackedPID
                    ) != nil
                case .unresolvedStop:
                    return false
                }
            }
            .sorted { lhs, rhs in
                let lhsRank = restoreRank(for: lhs)
                let rhsRank = restoreRank(for: rhs)
                if lhsRank != rhsRank {
                    return lhsRank < rhsRank
                }
                return lhs.updatedAt > rhs.updatedAt
            }
            .first
    }

    private enum RestoreIdentityRequirement {
        case sessionID
        case workingDirectory
        case unsupported
    }

    private static func makeRestorableDraft(
        paneID: String,
        tool: AgentTool,
        sessionID rawSessionID: String?,
        workingDirectory rawWorkingDirectory: String?,
        trackedPID: Int32,
        agentLaunchSnapshot: AgentLaunchSnapshot? = nil
    ) -> PaneRestoreDraft? {
        let workingDirectory = trimmed(rawWorkingDirectory)
        let sessionID: String

        switch restoreIdentityRequirement(for: tool) {
        case .sessionID:
            guard let requiredSessionID = trimmed(rawSessionID) else {
                return nil
            }
            sessionID = requiredSessionID
        case .workingDirectory:
            guard workingDirectory != nil else {
                return nil
            }
            sessionID = normalizedOptionalSessionID(rawSessionID, for: tool)
        case .unsupported:
            return nil
        }

        let draft = PaneRestoreDraft(
            paneID: paneID,
            kind: .agentResume,
            toolName: tool.displayName,
            sessionID: sessionID,
            workingDirectory: workingDirectory,
            trackedPID: trackedPID,
            agentLaunchSnapshot: agentLaunchSnapshot
        )

        guard AgentResumeCommandBuilder.command(for: draft) != nil else {
            return nil
        }

        return draft
    }

    private static func restoreIdentityRequirement(for tool: AgentTool) -> RestoreIdentityRequirement {
        switch tool {
        case .amp, .claudeCode, .codex, .copilot, .cursor, .droid, .kimi, .openCode:
            return .sessionID
        case .gemini, .pi, .grok, .agy:
            return .workingDirectory
        case .zentty, .custom:
            return .unsupported
        }
    }

    private static func normalizedOptionalSessionID(_ rawSessionID: String?, for tool: AgentTool) -> String {
        guard let sessionID = trimmed(rawSessionID) else {
            return ""
        }

        let fallbackSessionID = "pane-\(tool.displayName.lowercased())"
        return sessionID == fallbackSessionID ? "" : sessionID
    }

    private static func restoreRank(for session: PaneAgentSessionState) -> Int {
        switch session.state {
        case .needsInput:
            return 0
        case .running:
            return 1
        case .starting:
            return 2
        case .idle:
            return 3
        case .unresolvedStop:
            return 4
        }
    }

    private static func workingDirectory(
        agentStatus: PaneAgentStatus?,
        auxiliary: PaneAuxiliaryState,
        pane: PaneState,
        restoredDraft: PaneRestoreDraft?
    ) -> String? {
        trimmed(agentStatus?.workingDirectory)
            ?? trimmed(auxiliary.presentation.cwd)
            ?? trimmed(pane.sessionRequest.workingDirectory)
            ?? trimmed(restoredDraft?.workingDirectory)
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }

        return value
    }

    private static func defaultIsProcessAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else {
            return false
        }

        if kill(pid, 0) == 0 {
            return true
        }

        return errno == EPERM
    }
}

enum AgentResumeCommandBuilder {
    static func command(for draft: PaneRestoreDraft) -> String? {
        guard draft.kind == .agentResume else {
            return nil
        }

        switch AgentTool.resolve(named: draft.toolName) {
        case .amp:
            guard let sessionID = validatedAmpThreadID(from: draft.sessionID) else {
                logRejectedSessionID(for: draft)
                return nil
            }
            guard let resumeArguments = AmpResumeArgumentSanitizer.sanitizedAmpResumeArguments(
                from: draft.agentLaunchSnapshot?.arguments ?? []
            ) else {
                return nil
            }
            let commandArguments = ["amp", "threads", "continue"] + resumeArguments + [sessionID]
            return commandArguments.map(shellQuotedArgument(_:)).joined(separator: " ")
        case .claudeCode:
            guard let sessionID = validatedClaudeSessionID(from: draft.sessionID) else {
                logRejectedSessionID(for: draft)
                return nil
            }
            return "claude --resume \(sessionID)"
        case .codex:
            guard let sessionID = validatedCodexSessionID(from: draft.sessionID) else {
                logRejectedSessionID(for: draft)
                return nil
            }
            return "codex resume \(sessionID)"
        case .openCode:
            guard let sessionID = validatedOpenCodeSessionID(from: draft.sessionID) else {
                logRejectedSessionID(for: draft)
                return nil
            }
            return "opencode --session \(sessionID)"
        case .copilot:
            guard let sessionID = validatedCopilotSessionID(from: draft.sessionID) else {
                logRejectedSessionID(for: draft)
                return nil
            }
            return "copilot --resume=\(sessionID)"
        case .cursor:
            guard let sessionID = validatedCursorSessionID(from: draft.sessionID) else {
                logRejectedSessionID(for: draft)
                return nil
            }
            return "cursor-agent --resume=\(sessionID)"
        case .gemini:
            guard hasWorkingDirectory(draft) else {
                logRejectedWorkingDirectory(for: draft)
                return nil
            }
            return "gemini --resume"
        case .kimi:
            guard let sessionID = validatedKimiSessionID(from: draft.sessionID) else {
                logRejectedSessionID(for: draft)
                return nil
            }
            return "kimi -r \(sessionID)"
        case .droid:
            guard let sessionID = validatedDroidSessionID(from: draft.sessionID) else {
                logRejectedSessionID(for: draft)
                return nil
            }
            return "droid exec -s \(sessionID)"
        case .pi:
            // Pi resumes per-project via `-c` (continue last session). Since pi stores
            // sessions under ~/.pi/agent/sessions/<project>/, we don't need to pass a
            // specific session ID — pi looks up the latest one for this cwd.
            guard hasWorkingDirectory(draft) else {
                logRejectedWorkingDirectory(for: draft)
                return nil
            }
            return "pi -c"
        case .grok:
            if let sessionID = validatedGrokSessionID(from: draft.sessionID) {
                return "grok --resume \(sessionID)"
            }
            // Fall back to directory-based resume (Grok can resume the last session
            // for the current working directory).
            guard hasWorkingDirectory(draft) else {
                logRejectedWorkingDirectory(for: draft)
                return nil
            }
            return "grok --resume"
        case .agy:
            // A placeholder id means we never received a real
            // `conversation_id` from the agy hook stream; fall back to
            // `--continue` so the user resumes their most recent session
            // rather than seeing `agy --conversation <fake-uuid>` fail.
            if draft.sessionID.isEmpty || draft.sessionID.hasPrefix("zentty-placeholder-") {
                return "agy --continue"
            }
            if let sessionID = validatedAgySessionID(from: draft.sessionID) {
                return "agy --conversation \(sessionID)"
            }
            return nil
        default:
            return nil
        }
    }

    private static func validatedClaudeSessionID(from sessionID: String) -> String? {
        guard let uuid = UUID(uuidString: sessionID) else {
            return nil
        }
        return uuid.uuidString.lowercased()
    }

    private static func validatedCodexSessionID(from sessionID: String) -> String? {
        if let uuid = UUID(uuidString: sessionID) {
            return uuid.uuidString.lowercased()
        }

        let pattern = "^[A-Za-z0-9][A-Za-z0-9_-]*$"
        guard sessionID.range(of: pattern, options: .regularExpression) != nil else {
            return nil
        }

        return sessionID
    }

    private static func validatedOpenCodeSessionID(from sessionID: String) -> String? {
        let pattern = #"^ses_[A-Za-z0-9]+$"#
        guard sessionID.range(of: pattern, options: .regularExpression) != nil else {
            return nil
        }

        return sessionID
    }

    private static func validatedCopilotSessionID(from sessionID: String) -> String? {
        guard let uuid = UUID(uuidString: sessionID) else {
            return nil
        }
        return uuid.uuidString.lowercased()
    }

    private static func validatedCursorSessionID(from sessionID: String) -> String? {
        guard let uuid = UUID(uuidString: sessionID) else {
            return nil
        }
        return uuid.uuidString.lowercased()
    }

    private static func validatedGrokSessionID(from sessionID: String) -> String? {
        // Grok Build sessions are typically UUIDs. We also accept reasonable
        // alphanumeric session identifiers (Grok may use short IDs in some modes).
        if let uuid = UUID(uuidString: sessionID) {
            return uuid.uuidString.lowercased()
        }

        let pattern = "^[A-Za-z0-9][A-Za-z0-9_-]{3,}$"
        guard sessionID.range(of: pattern, options: .regularExpression) != nil else {
            return nil
        }
        return sessionID
    }

    private static func validatedKimiSessionID(from sessionID: String) -> String? {
        guard let uuid = UUID(uuidString: sessionID) else {
            return nil
        }
        return uuid.uuidString.lowercased()
    }

    private static func validatedDroidSessionID(from sessionID: String) -> String? {
        // Droid session IDs are opaque strings; validate only that they are
        // non-empty and contain no shell metacharacters or whitespace so the
        // restore command remains a single safe argument.
        let pattern = "^[A-Za-z0-9_.:-]+$"
        guard sessionID.range(of: pattern, options: .regularExpression) != nil else {
            return nil
        }
        return sessionID
    }

    private static func validatedAmpThreadID(from sessionID: String) -> String? {
        let pattern = #"^T-[A-Za-z0-9_-]+$"#
        guard sessionID.range(of: pattern, options: .regularExpression) != nil else {
            return nil
        }
        return sessionID
    }

    private static func validatedAgySessionID(from sessionID: String) -> String? {
        // Antigravity session IDs are typical alphanumeric identifiers.
        // The `zentty-placeholder-` prefix is what the launch bootstrap
        // injects before the first real `conversation_id` arrives; it
        // must never reach `agy --conversation`.
        if sessionID.hasPrefix("zentty-placeholder-") {
            return nil
        }
        let pattern = "^[A-Za-z0-9_-]+$"
        guard sessionID.range(of: pattern, options: .regularExpression) != nil else {
            return nil
        }
        return sessionID
    }

    private static func shellQuotedArgument(_ argument: String) -> String {
        if argument.range(of: #"^[A-Za-z0-9_./:=+-]+$"#, options: .regularExpression) != nil {
            return argument
        }
        return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func hasWorkingDirectory(_ draft: PaneRestoreDraft) -> Bool {
        guard let workingDirectory = draft.workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return false
        }

        return !workingDirectory.isEmpty
    }

    private static func logRejectedSessionID(for draft: PaneRestoreDraft) {
        let preview = String(draft.sessionID.prefix(32))
        sessionRestoreLogger.error(
            "Skipping restore draft for tool \(draft.toolName, privacy: .public) because the session identifier was invalid: \(preview, privacy: .public)"
        )
    }

    private static func logRejectedWorkingDirectory(for draft: PaneRestoreDraft) {
        sessionRestoreLogger.error(
            "Skipping restore draft for tool \(draft.toolName, privacy: .public) because the working directory was unavailable"
        )
    }
}
