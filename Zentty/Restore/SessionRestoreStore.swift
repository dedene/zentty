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
        guard let agentStatus = auxiliary.agentStatus else {
            return nil
        }
        guard let sessionID = trimmed(agentStatus.sessionID) else {
            return nil
        }
        guard let trackedPID = agentStatus.trackedPID, isProcessAlive(trackedPID) else {
            return nil
        }

        let workingDirectory = trimmed(agentStatus.workingDirectory)
            ?? trimmed(auxiliary.presentation.cwd)
            ?? trimmed(pane.sessionRequest.workingDirectory)

        return PaneRestoreDraft(
            paneID: paneID.rawValue,
            kind: .agentResume,
            toolName: agentStatus.tool.displayName,
            sessionID: sessionID,
            workingDirectory: workingDirectory,
            trackedPID: trackedPID
        )
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
        case .gemini:
            return "gemini --resume"
        case .cursor:
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

    private static func logRejectedSessionID(for draft: PaneRestoreDraft) {
        let preview = String(draft.sessionID.prefix(32))
        sessionRestoreLogger.error(
            "Skipping restore draft for tool \(draft.toolName, privacy: .public) because the session identifier was invalid: \(preview, privacy: .public)"
        )
    }
}
