import Darwin
import Foundation

struct ClaudeHookSessionRecord: Codable, Equatable {
    let sessionID: String
    var windowIDRawValue: String?
    var worklaneIDRawValue: String
    var paneIDRawValue: String
    var cwd: String?
    var transcriptPath: String?
    var pid: Int32?
    var lastHumanMessage: String?
    var lastInteractionKindRawValue: String?
    var lastStructuredInteractionText: String?
    var lastStructuredInteractionKindRawValue: String?
    var lastStructuredInteractionConfidenceRawValue: String?
    var lastNotificationText: String?
    var tasksByID: [String: Bool] = [:]
    var updatedAt: TimeInterval

    var windowID: WindowID? {
        windowIDRawValue.map(WindowID.init)
    }

    var worklaneID: WorklaneID {
        WorklaneID(worklaneIDRawValue)
    }

    var paneID: PaneID {
        PaneID(paneIDRawValue)
    }

    var lastInteractionKind: PaneAgentInteractionKind? {
        get { lastInteractionKindRawValue.flatMap(PaneAgentInteractionKind.init(rawValue:)) }
        set { lastInteractionKindRawValue = newValue?.rawValue }
    }

    var structuredInteractionText: String? {
        get { lastStructuredInteractionText ?? lastHumanMessage }
        set {
            lastStructuredInteractionText = newValue
            lastHumanMessage = newValue
        }
    }

    var structuredInteractionKind: PaneAgentInteractionKind? {
        get {
            lastStructuredInteractionKindRawValue
                .flatMap(PaneAgentInteractionKind.init(rawValue:))
                ?? lastInteractionKind
        }
        set {
            lastStructuredInteractionKindRawValue = newValue?.rawValue
            lastInteractionKind = newValue
        }
    }

    var structuredInteractionConfidence: AgentSignalConfidence? {
        get { lastStructuredInteractionConfidenceRawValue.flatMap(AgentSignalConfidence.init(rawValue:)) }
        set { lastStructuredInteractionConfidenceRawValue = newValue?.rawValue }
    }
}

private struct ClaudeHookSessionStoreFile: Codable {
    var version: Int = 1
    var sessions: [String: ClaudeHookSessionRecord] = [:]
}

final class ClaudeHookSessionStore {
    private let stateURL: URL
    private let lockURL: URL
    private let fileManager: FileManager
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    init(
        stateURL: URL,
        fileManager: FileManager = .default
    ) {
        self.stateURL = stateURL
        self.lockURL = stateURL.appendingPathExtension("lock")
        self.fileManager = fileManager
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    convenience init(
        processInfo: ProcessInfo = .processInfo,
        fileManager: FileManager = .default
    ) {
        let env = processInfo.environment
        if let overridePath = env["ZENTTY_CLAUDE_HOOK_STATE_PATH"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !overridePath.isEmpty {
            self.init(stateURL: URL(fileURLWithPath: NSString(string: overridePath).expandingTildeInPath), fileManager: fileManager)
            return
        }

        let stateURL: URL
        if let appSupportDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            stateURL = appSupportDirectory
                .appendingPathComponent("Zentty", isDirectory: true)
                .appendingPathComponent("claude-hook-sessions.json", isDirectory: false)
        } else {
            stateURL = fileManager.temporaryDirectory.appendingPathComponent("zentty-claude-hook-sessions.json")
        }
        self.init(stateURL: stateURL, fileManager: fileManager)
    }

    func lookup(sessionID: String) throws -> ClaudeHookSessionRecord? {
        try withLockedState { state in
            state.sessions[normalized(sessionID)]
        }
    }

    func upsert(
        sessionID: String,
        windowID: WindowID? = nil,
        worklaneID: WorklaneID,
        paneID: PaneID,
        cwd: String?,
        transcriptPath: String? = nil,
        pid: Int32?,
        lastHumanMessage: String? = nil,
        lastInteractionKind: PaneAgentInteractionKind? = nil
    ) throws {
        let normalizedSessionID = normalized(sessionID)
        guard !normalizedSessionID.isEmpty else {
            return
        }

        try withLockedState { state in
            let now = Date().timeIntervalSince1970
            var record = state.sessions[normalizedSessionID] ?? ClaudeHookSessionRecord(
                sessionID: normalizedSessionID,
                windowIDRawValue: windowID?.rawValue,
                worklaneIDRawValue: worklaneID.rawValue,
                paneIDRawValue: paneID.rawValue,
                cwd: nil,
                transcriptPath: nil,
                pid: nil,
                lastHumanMessage: nil,
                lastInteractionKindRawValue: nil,
                lastStructuredInteractionText: nil,
                lastStructuredInteractionKindRawValue: nil,
                lastStructuredInteractionConfidenceRawValue: nil,
                lastNotificationText: nil,
                tasksByID: [:],
                updatedAt: now
            )
            record.windowIDRawValue = windowID?.rawValue
            record.worklaneIDRawValue = worklaneID.rawValue
            record.paneIDRawValue = paneID.rawValue
            if let cwd = normalizedOptional(cwd) {
                record.cwd = cwd
            }
            if let transcriptPath = normalizedOptional(transcriptPath) {
                record.transcriptPath = transcriptPath
            }
            if let pid {
                record.pid = pid
            }
            if let lastHumanMessage = normalizedOptional(lastHumanMessage) {
                record.structuredInteractionText = lastHumanMessage
            }
            if let lastInteractionKind {
                record.structuredInteractionKind = lastInteractionKind
            }
            record.updatedAt = now
            state.sessions[normalizedSessionID] = record
        }
    }

    func rememberStructuredInteraction(
        sessionID: String,
        windowID: WindowID? = nil,
        worklaneID: WorklaneID,
        paneID: PaneID,
        cwd: String?,
        pid: Int32?,
        text: String,
        kind: PaneAgentInteractionKind,
        confidence: AgentSignalConfidence
    ) throws {
        let normalizedSessionID = normalized(sessionID)
        guard !normalizedSessionID.isEmpty else {
            return
        }

        try withLockedState { state in
            let now = Date().timeIntervalSince1970
            var record = state.sessions[normalizedSessionID] ?? ClaudeHookSessionRecord(
                sessionID: normalizedSessionID,
                windowIDRawValue: windowID?.rawValue,
                worklaneIDRawValue: worklaneID.rawValue,
                paneIDRawValue: paneID.rawValue,
                cwd: nil,
                transcriptPath: nil,
                pid: nil,
                lastHumanMessage: nil,
                lastInteractionKindRawValue: nil,
                lastStructuredInteractionText: nil,
                lastStructuredInteractionKindRawValue: nil,
                lastStructuredInteractionConfidenceRawValue: nil,
                lastNotificationText: nil,
                tasksByID: [:],
                updatedAt: now
            )
            record.windowIDRawValue = windowID?.rawValue
            record.worklaneIDRawValue = worklaneID.rawValue
            record.paneIDRawValue = paneID.rawValue
            if let cwd = normalizedOptional(cwd) {
                record.cwd = cwd
            }
            if let pid {
                record.pid = pid
            }
            record.structuredInteractionText = normalizedOptional(text)
            record.structuredInteractionKind = kind
            record.structuredInteractionConfidence = confidence
            record.lastNotificationText = nil
            record.updatedAt = now
            state.sessions[normalizedSessionID] = record
        }
    }

    func recordNotificationText(sessionID: String, text: String) throws {
        let normalizedSessionID = normalized(sessionID)
        guard !normalizedSessionID.isEmpty else {
            return
        }

        try withLockedState { state in
            guard var record = state.sessions[normalizedSessionID] else {
                return
            }
            record.lastNotificationText = normalizedOptional(text)
            record.updatedAt = Date().timeIntervalSince1970
            state.sessions[normalizedSessionID] = record
        }
    }

    func clearInteractionContext(sessionID: String) throws {
        let normalizedSessionID = normalized(sessionID)
        guard !normalizedSessionID.isEmpty else {
            return
        }

        try withLockedState { state in
            guard var record = state.sessions[normalizedSessionID] else {
                return
            }
            record.structuredInteractionText = nil
            record.structuredInteractionKind = nil
            record.structuredInteractionConfidence = nil
            record.lastNotificationText = nil
            record.updatedAt = Date().timeIntervalSince1970
            state.sessions[normalizedSessionID] = record
        }
    }

    func clearLastHumanMessage(sessionID: String) throws {
        try clearInteractionContext(sessionID: sessionID)
    }

    func updateTask(
        sessionID: String,
        taskID: String,
        isCompleted: Bool
    ) throws -> PaneAgentTaskProgress? {
        let normalizedSessionID = normalized(sessionID)
        let normalizedTaskID = normalized(taskID)
        guard !normalizedSessionID.isEmpty, !normalizedTaskID.isEmpty else {
            return nil
        }

        return try withLockedState { state in
            guard var record = state.sessions[normalizedSessionID] else {
                return nil
            }
            record.tasksByID[normalizedTaskID] = isCompleted
            record.updatedAt = Date().timeIntervalSince1970
            state.sessions[normalizedSessionID] = record
            return progress(from: record.tasksByID)
        }
    }

    func taskProgress(sessionID: String?) throws -> PaneAgentTaskProgress? {
        guard let normalizedSessionID = normalizedOptional(sessionID) else {
            return nil
        }

        return try withLockedState { state in
            guard let record = state.sessions[normalizedSessionID] else {
                return nil
            }
            return progress(from: record.tasksByID)
        }
    }

    @discardableResult
    func consume(
        sessionID: String?,
        fallbackWindowID: WindowID? = nil,
        fallbackWorklaneID: WorklaneID?,
        fallbackPaneID: PaneID?
    ) throws -> ClaudeHookSessionRecord? {
        try withLockedState { state -> ClaudeHookSessionRecord? in
            if let sessionID = normalizedOptional(sessionID),
               let record = state.sessions.removeValue(forKey: sessionID) {
                return record
            }

            guard let fallbackWorklaneID, let fallbackPaneID else {
                return nil
            }

            let matchingKeys = state.sessions
                .filter { _, record in
                    if let fallbackWindowID, record.windowID != fallbackWindowID {
                        return false
                    }
                    return record.worklaneIDRawValue == fallbackWorklaneID.rawValue
                        && record.paneIDRawValue == fallbackPaneID.rawValue
                }
                .map(\.key)

            guard matchingKeys.count == 1, let key = matchingKeys.first else {
                return nil
            }

            return state.sessions.removeValue(forKey: key)
        }
    }

    private func withLockedState<T>(_ body: (inout ClaudeHookSessionStoreFile) throws -> T) throws -> T {
        try fileManager.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fileManager.fileExists(atPath: lockURL.path) {
            fileManager.createFile(atPath: lockURL.path, contents: Data())
        }

        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, mode_t(S_IRUSR | S_IWUSR))
        guard descriptor >= 0 else {
            throw AgentStatusPayloadError.invalidHookPayload
        }
        defer { close(descriptor) }

        guard flock(descriptor, LOCK_EX) == 0 else {
            throw AgentStatusPayloadError.invalidHookPayload
        }
        defer { flock(descriptor, LOCK_UN) }

        var state = loadState()
        let result = try body(&state)
        try saveState(state)
        return result
    }

    private func loadState() -> ClaudeHookSessionStoreFile {
        guard let data = try? Data(contentsOf: stateURL) else {
            return ClaudeHookSessionStoreFile()
        }
        return (try? decoder.decode(ClaudeHookSessionStoreFile.self, from: data)) ?? ClaudeHookSessionStoreFile()
    }

    private func saveState(_ state: ClaudeHookSessionStoreFile) throws {
        let data = try encoder.encode(state)
        try data.write(to: stateURL, options: .atomic)
    }

    private func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizedOptional(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    private func progress(from tasksByID: [String: Bool]) -> PaneAgentTaskProgress? {
        guard !tasksByID.isEmpty else {
            return nil
        }

        let doneCount = tasksByID.values.filter { $0 }.count
        return PaneAgentTaskProgress(doneCount: doneCount, totalCount: tasksByID.count)
    }
}
