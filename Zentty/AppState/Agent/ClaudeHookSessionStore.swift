import Darwin
import Foundation

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
        workspaceID: WorkspaceID,
        paneID: PaneID,
        cwd: String?,
        pid: Int32?,
        lastHumanMessage: String? = nil
    ) throws {
        let normalizedSessionID = normalized(sessionID)
        guard !normalizedSessionID.isEmpty else {
            return
        }

        try withLockedState { state in
            let now = Date().timeIntervalSince1970
            var record = state.sessions[normalizedSessionID] ?? ClaudeHookSessionRecord(
                sessionID: normalizedSessionID,
                workspaceIDRawValue: workspaceID.rawValue,
                paneIDRawValue: paneID.rawValue,
                cwd: nil,
                pid: nil,
                lastHumanMessage: nil,
                updatedAt: now
            )
            record.workspaceIDRawValue = workspaceID.rawValue
            record.paneIDRawValue = paneID.rawValue
            if let cwd = normalizedOptional(cwd) {
                record.cwd = cwd
            }
            if let pid {
                record.pid = pid
            }
            if let lastHumanMessage = normalizedOptional(lastHumanMessage) {
                record.lastHumanMessage = lastHumanMessage
            }
            record.updatedAt = now
            state.sessions[normalizedSessionID] = record
        }
    }

    func clearLastHumanMessage(sessionID: String) throws {
        let normalizedSessionID = normalized(sessionID)
        guard !normalizedSessionID.isEmpty else {
            return
        }

        try withLockedState { state in
            guard var record = state.sessions[normalizedSessionID] else {
                return
            }
            record.lastHumanMessage = nil
            record.updatedAt = Date().timeIntervalSince1970
            state.sessions[normalizedSessionID] = record
        }
    }

    @discardableResult
    func consume(
        sessionID: String?,
        fallbackWorkspaceID: WorkspaceID?,
        fallbackPaneID: PaneID?
    ) throws -> ClaudeHookSessionRecord? {
        try withLockedState { state in
            if let sessionID = normalizedOptional(sessionID),
               let record = state.sessions.removeValue(forKey: sessionID) {
                return record
            }

            guard let fallbackWorkspaceID, let fallbackPaneID else {
                return nil
            }

            guard let key = state.sessions.first(where: { _, record in
                record.workspaceIDRawValue == fallbackWorkspaceID.rawValue
                    && record.paneIDRawValue == fallbackPaneID.rawValue
            })?.key else {
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
}
